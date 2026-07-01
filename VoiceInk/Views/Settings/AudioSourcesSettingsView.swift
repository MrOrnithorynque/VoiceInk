// AudioSourcesSettingsView — the Phase 5 "Custom sources" composition surface. Lets the user
// build N audio sources (mics by device, specific apps, system output), edit roles, reorder,
// and remove — persisting a [AudioSourceConfig] the engine records verbatim. Enforces the
// invariants the merge/engine rely on: unique non-empty roles, no duplicate physical mic, a
// soft cap of 4, at least one microphone, and one system-output source.

import SwiftUI
import CoreAudio

// MARK: - View model

@MainActor
final class AudioSourcesViewModel: ObservableObject {
    @Published var configs: [AudioSourceConfig]
    let maxSources = 4
    private let deviceManager = AudioDeviceManager.shared

    init() {
        self.configs = AudioSourceConfig.loadConfigs() ?? AudioSourceConfig.mvpDefault
    }

    var devices: [(id: AudioDeviceID, uid: String, name: String)] { deviceManager.availableDevices }
    var canAdd: Bool { configs.count < maxSources }
    var micCount: Int { configs.filter(\.isMicrophone).count }
    var hasSystemGlobal: Bool { configs.contains(where: \.isSystemGlobal) }
    var showsCrossTalkWarning: Bool { micCount >= 2 }
    var nearCap: Bool { configs.count >= maxSources - 1 }

    private var defaultInputUID: String? {
        let id = deviceManager.getCurrentDevice()
        return devices.first { $0.id == id }?.uid
    }

    func effectiveMicUID(_ config: AudioSourceConfig) -> String? {
        if case let .microphone(uid) = config.kind { return uid ?? defaultInputUID }
        return nil
    }

    func deviceName(for config: AudioSourceConfig) -> String {
        switch config.kind {
        case .microphone(let uid):
            guard let uid else { return "Default input" }
            return devices.first { $0.uid == uid }?.name ?? "Unavailable device"
        case .systemGlobal: return "All system output"
        case .app(let bundleID): return bundleID
        }
    }

    /// Whether a mic device (by effective UID, treating nil as the current default) is already used.
    func micDeviceInUse(_ uid: String?, excluding id: UUID? = nil) -> Bool {
        let target = uid ?? defaultInputUID
        return configs.contains { c in
            c.id != id && c.isMicrophone && effectiveMicUID(c) == target
        }
    }

    // MARK: Mutations (each persists)

    func addMic(deviceUID: String?) {
        guard canAdd, !micDeviceInUse(deviceUID) else { return }
        let role = uniqueRole(micCount == 0 ? "Me" : "Mic \(micCount + 1)")
        configs.append(AudioSourceConfig(kind: .microphone(deviceUID: deviceUID), role: role))
        persist()
    }

    func addApp(bundleID: String, appName: String) {
        guard canAdd else { return }
        configs.append(AudioSourceConfig(kind: .app(bundleID: bundleID), role: uniqueRole(appName)))
        persist()
    }

    func addSystem() {
        guard canAdd, !hasSystemGlobal else { return }
        configs.append(AudioSourceConfig(kind: .systemGlobal, role: uniqueRole("Them")))
        persist()
    }

    func remove(_ id: UUID) {
        guard configs.count > 1 else { return }
        if let c = configs.first(where: { $0.id == id }), c.isMicrophone, micCount <= 1 { return }
        configs.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        configs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setRole(_ id: UUID, _ role: String) {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = role.trimmingCharacters(in: .whitespaces)
        configs[idx].role = trimmed.isEmpty ? configs[idx].role : uniqueRole(trimmed, excluding: id)
        persist()
    }

    func setMicDevice(_ id: UUID, uid: String?) {
        guard let idx = configs.firstIndex(where: { $0.id == id }), configs[idx].isMicrophone else { return }
        guard !micDeviceInUse(uid, excluding: id) else { return }
        configs[idx].kind = .microphone(deviceUID: uid)
        persist()
    }

    func resetToDefault() {
        configs = AudioSourceConfig.mvpDefault
        persist()
    }

    func persist() { AudioSourceConfig.saveConfigs(configs) }

    private func uniqueRole(_ base: String, excluding id: UUID? = nil) -> String {
        let existing = Set(configs.filter { $0.id != id }.map { $0.role.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var i = 2
        while existing.contains("\(base) \(i)".lowercased()) { i += 1 }
        return "\(base) \(i)"
    }
}

// MARK: - View

struct AudioSourcesSettingsView: View {
    @StateObject private var viewModel = AudioSourcesViewModel()
    @State private var showAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(viewModel.configs) { config in
                    AudioSourceCard(config: config, viewModel: viewModel)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { viewModel.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .frame(minHeight: 160, maxHeight: 320)
            .scrollContentBackground(.hidden)

            if viewModel.showsCrossTalkWarning {
                Label("Two separate microphones in one room can capture the same speech twice under different labels (cross-talk). One mic + system/app audio gives the cleanest split. Their clocks may also drift slightly on long sessions.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                addSourceMenu
                if viewModel.nearCap {
                    Text("\(viewModel.configs.count)/\(viewModel.maxSources) sources")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset to Mic + System") { viewModel.resetToDefault() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showAppPicker) {
            AppAudioPickerSheet { bundleID, name in
                viewModel.addApp(bundleID: bundleID, appName: name)
            }
        }
    }

    private var addSourceMenu: some View {
        Menu {
            Menu("Microphone") {
                Button("Default input") { viewModel.addMic(deviceUID: nil) }
                Divider()
                ForEach(viewModel.devices, id: \.uid) { device in
                    Button(device.name) { viewModel.addMic(deviceUID: device.uid) }
                        .disabled(viewModel.micDeviceInUse(device.uid))
                }
            }
            if #available(macOS 14.4, *) {
                Button("App audio…") { showAppPicker = true }
                Button("System output (all apps)") { viewModel.addSystem() }
                    .disabled(viewModel.hasSystemGlobal)
            }
        } label: {
            Label("Add source", systemImage: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!viewModel.canAdd)
    }
}

// MARK: - Source card

private struct AudioSourceCard: View {
    let config: AudioSourceConfig
    @ObservedObject var viewModel: AudioSourcesViewModel
    @State private var role: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Label", text: $role)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit { viewModel.setRole(config.id, role) }

                if config.isMicrophone {
                    Menu(viewModel.deviceName(for: config)) {
                        Button("Default input") { viewModel.setMicDevice(config.id, uid: nil) }
                        Divider()
                        ForEach(viewModel.devices, id: \.uid) { device in
                            Button(device.name) { viewModel.setMicDevice(config.id, uid: device.uid) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                    .fixedSize()
                } else {
                    Text(viewModel.deviceName(for: config))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.remove(config.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.configs.count <= 1 || (config.isMicrophone && viewModel.micCount <= 1))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        )
        .onAppear { role = config.role }
    }

    private var icon: String {
        switch config.kind {
        case .microphone: return "mic.fill"
        case .systemGlobal: return "speaker.wave.3.fill"
        case .app: return "app.badge.fill"
        }
    }
}

// MARK: - App picker

@available(macOS 14.4, *)
private struct AppAudioPickerSheet: View {
    let onPick: (_ bundleID: String, _ name: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var processes: [AudioProcessInfo] = []
    @State private var search = ""

    private var filtered: [AudioProcessInfo] {
        guard !search.isEmpty else { return processes }
        return processes.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an app to capture").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List(filtered) { process in
                Button {
                    if let bundleID = process.bundleID {
                        onPick(bundleID, process.name)
                        dismiss()
                    }
                } label: {
                    HStack {
                        if let icon = process.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 20, height: 20)
                        }
                        Text(process.name)
                        Spacer()
                        if process.isPlaying {
                            Text("Playing").font(.caption2).foregroundColor(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(process.bundleID == nil)
            }
            .listStyle(.plain)

            Text("Only apps currently producing audio can be tapped. An app added here is captured whenever it plays.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding()
        }
        .frame(width: 380, height: 440)
        .onAppear { processes = AudioProcessEnumerator.list() }
    }
}
