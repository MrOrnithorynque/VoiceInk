// CaptionBridgeServer — loopback WebSocket listener receiving speaker-attributed caption
// events from the companion browser extension during a Conversation Mode recording
// (docs/plans/meeting-name-feed-spec.md, M1). Token-gated; caption frames are buffered
// IN MEMORY and only while a session is active (privacy: nothing outside recordings, no
// sidecar files, events die with the session). Actor: NWListener/NWConnection callbacks
// hop onto the actor; all state is actor-isolated.
//
// Protocol (JSON text frames):
//   ext → app: {"type":"hello","token":…,"platform":…,"ver":1}
//              {"type":"caption","name":…,"text":…,"tsMs":…,"turnId":…}
//              {"type":"bye"}
//   app → ext: {"type":"hello_ack","recording":Bool} · {"type":"session","state":…}
//              {"type":"error","code":…}

import Foundation
import Network
import os

actor CaptionBridgeServer {

    static let shared = CaptionBridgeServer()

    /// One speaker-attributed caption turn scraped from the meeting page.
    struct CaptionEvent: Codable, Hashable, Sendable {
        /// Participant display name as the meeting UI shows it.
        let name: String
        /// Caption text for the turn (platforms rewrite turns; last update wins).
        let text: String
        /// Browser `Date.now()` (ms since epoch) at the turn's last mutation — same system
        /// wall clock as the app's `Date()`, so no cross-clock handshake is needed.
        let tsMs: Double
        /// Scraper-stable per-turn id; the dedupe/replace key.
        let turnId: String
    }

    enum BridgeError: LocalizedError {
        case portUnavailable
        var errorDescription: String? {
            switch self {
            case .portUnavailable:
                return "No free port for the meeting-names bridge (47810–47819)"
            }
        }
    }

    /// Default port range the extension probes (spec §Component 1).
    static let defaultPort: UInt16 = 47810
    private static let portProbeSpan: UInt16 = 10

    private let configuredPort: UInt16?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var sessionActive = false
    private var buffer: [String: CaptionEvent] = [:]   // keyed by turnId (replace-on-update)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CaptionBridge")

    /// `shared` probes the default port range; tests pin a port to avoid clashes.
    init(port: UInt16? = nil) {
        self.configuredPort = port
    }

    /// Pairing token shown in settings and required in the extension's `hello`. Generated
    /// once, stored in UserDefaults (a local-authorization secret, not a cloud credential —
    /// worst case with a stolen token is fake names in a local transcript).
    static func pairingToken() -> String {
        let key = "CaptionBridgeToken"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: key)
        return token
    }

    var isRunning: Bool { listener != nil }
    /// Buffered event count (test/status hook).
    var bufferedCount: Int { buffer.count }

    // MARK: - Lifecycle

    /// Start listening if not already; probes the port range unless a port was pinned.
    func ensureRunning() throws {
        guard listener == nil else { return }
        let candidates: [UInt16] = configuredPort.map { [$0] }
            ?? Array(Self.defaultPort..<(Self.defaultPort + Self.portProbeSpan))
        for port in candidates {
            if let started = try? startListener(on: port) {
                listener = started
                logger.notice("Caption bridge listening on 127.0.0.1:\(port, privacy: .public)")
                return
            }
        }
        throw BridgeError.portUnavailable
    }

    /// Stop listening and drop all connections + any buffered events.
    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.nw.cancel() }
        connections.removeAll()
        sessionActive = false
        buffer.removeAll()
    }

    /// Bracket a recording: start buffering caption frames and tell the extension to observe.
    func beginSession() {
        sessionActive = true
        buffer.removeAll()
        broadcast(["type": "session", "state": "started"])
        logger.notice("Caption session started (\(self.connections.count, privacy: .public) client(s))")
    }

    /// End the recording bracket: stop buffering and return events sorted by time.
    /// Never blocks on the network — returns whatever has already arrived.
    func endSession() -> [CaptionEvent] {
        guard sessionActive else { return [] }
        sessionActive = false
        broadcast(["type": "session", "state": "stopped"])
        let events = buffer.values.sorted { $0.tsMs < $1.tsMs }
        buffer.removeAll()
        logger.notice("Caption session ended: \(events.count, privacy: .public) event(s)")
        return events
    }

    // MARK: - Listener plumbing

    private func startListener(on port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        // Loopback only: never reachable from the network. NOTE: Network.framework's
        // WebSocket server API does not expose the HTTP upgrade headers, so the Origin
        // allowlist from the spec is deferred (M3 empirical work); the token is the gate.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: port)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { nw.cancel(); return }
            Task { await self.adopt(nw) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                guard let self else { return }
                Task { await self.listenerFailed(error) }
            }
        }
        listener.start(queue: .global(qos: .utility))
        // start() is async; a port collision surfaces via .failed. Poll briefly so callers
        // get a synchronous verdict for the probe loop.
        for _ in 0..<50 {
            switch listener.state {
            case .ready: return listener
            case .failed, .cancelled: throw BridgeError.portUnavailable
            default: usleep(10_000)   // 10ms; setup-time only, never on an audio path
            }
        }
        listener.cancel()
        throw BridgeError.portUnavailable
    }

    private func listenerFailed(_ error: NWError) {
        logger.error("Caption bridge listener failed: \(error.localizedDescription, privacy: .public)")
        listener = nil
    }

    // MARK: - Connections

    /// Per-connection state (auth happens on the first frame).
    private final class Connection {
        let nw: NWConnection
        var authed = false
        init(nw: NWConnection) { self.nw = nw }
    }

    private func adopt(_ nw: NWConnection) {
        let conn = Connection(nw: nw)
        connections[ObjectIdentifier(nw)] = conn
        nw.stateUpdateHandler = { [weak self, weak nw] state in
            guard let self, let nw else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.forget(nw) }
            default: break
            }
        }
        nw.start(queue: .global(qos: .utility))
        receiveLoop(conn)
    }

    private func forget(_ nw: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(nw))
    }

    private func receiveLoop(_ conn: Connection) {
        conn.nw.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            Task {
                if let data, error == nil {
                    await self.handle(frame: data, from: conn)
                    await self.receiveLoop(conn)
                } else {
                    conn.nw.cancel()
                    await self.forget(conn.nw)
                }
            }
        }
    }

    private func handle(frame: Data, from conn: Connection) {
        guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = json["type"] as? String else {
            conn.nw.cancel()
            return
        }
        switch type {
        case "hello":
            guard (json["token"] as? String) == Self.pairingToken() else {
                // Close only after the error frame is on the wire (cancelling immediately
                // races the in-flight send and the client sees a bare disconnect).
                send(["type": "error", "code": "bad_token"], to: conn, thenClose: true)
                return
            }
            conn.authed = true
            send(["type": "hello_ack", "recording": sessionActive], to: conn)
        case "caption":
            guard conn.authed, sessionActive,
                  let name = json["name"] as? String,
                  let text = json["text"] as? String,
                  let tsMs = json["tsMs"] as? Double,
                  let turnId = json["turnId"] as? String else { return }
            buffer[turnId] = CaptionEvent(name: name, text: text, tsMs: tsMs, turnId: turnId)
        case "bye":
            conn.nw.cancel()
        default:
            break   // forward-compatible: ignore unknown frame types
        }
    }

    // MARK: - Sending

    private func broadcast(_ payload: [String: Any]) {
        for conn in connections.values where conn.authed {
            send(payload, to: conn)
        }
    }

    private func send(_ payload: [String: Any], to conn: Connection, thenClose: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            if thenClose { conn.nw.cancel() }
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        let nw = conn.nw
        nw.send(content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in
                    if thenClose { nw.cancel() }
                })
    }
}
