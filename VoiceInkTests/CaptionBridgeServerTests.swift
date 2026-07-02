//  CaptionBridgeServerTests.swift
//  Integration tests for the loopback caption-bridge WebSocket server: auth accept/reject,
//  session gating, buffering with turnId replacement. Each test pins its own port to avoid
//  bind clashes; the client is a plain URLSessionWebSocketTask.

import Testing
import Foundation
@testable import VoiceInk

struct CaptionBridgeServerTests {

    // MARK: - Helpers

    private func connect(port: UInt16) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        return task
    }

    private func sendJSON(_ payload: [String: Any], over task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }

    private func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: data = Data()
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func hello(_ task: URLSessionWebSocketTask, token: String) async throws -> [String: Any] {
        try await sendJSON(["type": "hello", "token": token, "platform": "meet", "ver": 1], over: task)
        return try await receiveJSON(task)
    }

    /// Wait until the server has buffered `count` events (frames arrive asynchronously).
    private func waitForBuffered(_ server: CaptionBridgeServer, _ count: Int) async throws {
        for _ in 0..<100 {
            if await server.bufferedCount >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)   // 20ms
        }
        Issue.record("Timed out waiting for \(count) buffered event(s)")
    }

    private var token: String { CaptionBridgeServer.pairingToken() }

    // MARK: - Tests

    @Test func helloWithValidTokenGetsAck() async throws {
        let server = CaptionBridgeServer(port: 47891)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }

        let client = connect(port: 47891)
        let ack = try await hello(client, token: token)

        #expect(ack["type"] as? String == "hello_ack")
        #expect(ack["recording"] as? Bool == false)
        client.cancel(with: .normalClosure, reason: nil)
    }

    @Test func helloWithBadTokenIsRejected() async throws {
        let server = CaptionBridgeServer(port: 47892)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }

        let client = connect(port: 47892)
        let reply = try await hello(client, token: "wrong-token")

        #expect(reply["type"] as? String == "error")
        #expect(reply["code"] as? String == "bad_token")
        client.cancel(with: .normalClosure, reason: nil)
    }

    @Test func captionsOutsideSessionAreDropped() async throws {
        let server = CaptionBridgeServer(port: 47893)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }

        let client = connect(port: 47893)
        _ = try await hello(client, token: token)
        try await sendJSON(["type": "caption", "name": "Sarah", "text": "early words",
                            "tsMs": 1.0, "turnId": "t1"], over: client)
        // Give the frame time to arrive, then bracket a session — buffer must be empty.
        try await Task.sleep(nanoseconds: 100_000_000)
        await server.beginSession()
        let events = await server.endSession()

        #expect(events.isEmpty)
        client.cancel(with: .normalClosure, reason: nil)
    }

    @Test func captionsBufferSortAndReplaceByTurnId() async throws {
        let server = CaptionBridgeServer(port: 47894)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }

        let client = connect(port: 47894)
        _ = try await hello(client, token: token)
        await server.beginSession()
        // Session-start broadcast is in flight; captions may race it harmlessly.
        try await sendJSON(["type": "caption", "name": "Sarah", "text": "we could ship",
                            "tsMs": 2000.0, "turnId": "t1"], over: client)
        try await sendJSON(["type": "caption", "name": "Marc", "text": "agreed",
                            "tsMs": 1000.0, "turnId": "t2"], over: client)
        try await waitForBuffered(server, 2)
        // Platform rewrote turn t1 (correction) — replaces, not appends.
        try await sendJSON(["type": "caption", "name": "Sarah", "text": "we could ship Friday",
                            "tsMs": 2500.0, "turnId": "t1"], over: client)
        try await Task.sleep(nanoseconds: 100_000_000)

        let events = await server.endSession()
        #expect(events.count == 2)
        #expect(events.map(\.name) == ["Marc", "Sarah"])              // sorted by tsMs
        #expect(events.last?.text == "we could ship Friday")          // replaced, not duplicated
        #expect(await server.bufferedCount == 0)                      // buffer cleared

        // A second endSession without a session returns nothing.
        #expect(await server.endSession().isEmpty)
        client.cancel(with: .normalClosure, reason: nil)
    }

    @Test func unauthedCaptionsAreIgnored() async throws {
        let server = CaptionBridgeServer(port: 47895)
        try await server.ensureRunning()
        defer { Task { await server.stop() } }

        let client = connect(port: 47895)
        await server.beginSession()
        // No hello — straight to captions.
        try await sendJSON(["type": "caption", "name": "Mallory", "text": "spoofed",
                            "tsMs": 1.0, "turnId": "x"], over: client)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await server.endSession().isEmpty)
        client.cancel(with: .normalClosure, reason: nil)
    }
}
