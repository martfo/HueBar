import AppKit
import SwiftUI

struct ShortcutsSection: View {
    @Environment(HueStore.self) private var store
    @State private var groupKey = ""          // "bridgeID|groupID"
    @State private var actionKey = "next"     // "scene:<id>", "next" or "toggle"
    @State private var recorded: RecordedKeys?

    var body: some View {
        // The controls for adding come first so a growing list never pushes them out of view.
        Section {
            Picker("Room or zone", selection: $groupKey) {
                Text("Choose…").tag("")
                ForEach(store.bridges) { bridge in
                    let prefix = store.bridges.count > 1 ? "\(bridge.config.name) · " : ""
                    if !bridge.rooms.isEmpty {
                        Section(prefix + "Rooms") {
                            ForEach(bridge.rooms) { groupOption($0) }
                        }
                    }
                    if !bridge.zones.isEmpty {
                        Section(prefix + "Zones") {
                            ForEach(bridge.zones) { groupOption($0) }
                        }
                    }
                }
            }
            .onChange(of: groupKey) { _, _ in actionKey = "next" }

            if let group = selectedGroup {
                Picker("Action", selection: $actionKey) {
                    Text("Next scene (cycles through)").tag("next")
                    Text("Turn on/off").tag("toggle")
                    if !group.scenes.isEmpty {
                        Divider()
                        ForEach(group.scenes) { scene in
                            Text("Scene: \(scene.name)").tag("scene:\(scene.id)")
                        }
                    }
                }
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(recorded: $recorded)
                    Button("Add") { add(group) }
                        .disabled(recorded == nil)
                }
            }
        } header: {
            Text("Keyboard shortcuts")
        } footer: {
            Text("Shortcuts work from any app. Use at least one of ⌃ ⌥ ⌘, or a function key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Your shortcuts") {
            if store.shortcuts.isEmpty {
                Text("No shortcuts yet.").foregroundStyle(.secondary)
            }
            ForEach(store.shortcuts.sorted { $0.actionDescription < $1.actionDescription }) { shortcut in
                HStack {
                    Text(shortcut.keys)
                        .font(.body.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    Text(shortcut.actionDescription).lineLimit(1)
                    if store.shortcutConflicts.contains(shortcut.id) {
                        Label("In use by another app", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removeShortcut(shortcut.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Rooms show their own icon; zones share one, so the two read apart at a glance.
    private func groupOption(_ g: GroupItem) -> some View {
        Label(g.name, systemImage: g.kind == .zone ? "square.on.square.dashed" : g.symbol)
            .tag("\(g.bridgeID)|\(g.id)")
    }

    private var selectedGroup: GroupItem? {
        let parts = groupKey.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return nil }
        return store.bridges.first { $0.id == parts[0] }?.groups.first { $0.id == parts[1] }
    }

    private func add(_ group: GroupItem) {
        guard let keys = recorded else { return }
        var shortcut = Shortcut(keyCode: keys.keyCode, modifiers: keys.modifiers, keyLabel: keys.label,
                                action: .nextScene, bridgeID: group.bridgeID, groupID: group.id,
                                sceneID: nil, groupName: group.name, sceneName: nil)
        if actionKey == "toggle" {
            shortcut.action = .toggle
        } else if actionKey.hasPrefix("scene:") {
            let sceneID = String(actionKey.dropFirst("scene:".count))
            shortcut.action = .scene
            shortcut.sceneID = sceneID
            shortcut.sceneName = group.scenes.first { $0.id == sceneID }?.name
        }
        store.addShortcut(shortcut)
        recorded = nil
    }
}

struct RecordedKeys: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
    var display: String { KeyCombo.symbols(modifiers) + label }
}

/// Click, then press the key combination. Escape cancels.
struct ShortcutRecorder: View {
    @Environment(HueStore.self) private var store
    @Binding var recorded: RecordedKeys?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : (recorded?.display ?? "Record shortcut"))
                .font(recorded != nil && !recording ? .body.monospaced() : .body)
                .frame(minWidth: 120)
        }
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        store.suspendShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // Escape
                stop()
                return nil
            }
            guard let label = KeyCombo.label(for: event) else { NSSound.beep(); return nil }
            recorded = RecordedKeys(keyCode: UInt32(event.keyCode),
                                    modifiers: KeyCombo.carbonModifiers(event.modifierFlags),
                                    label: label)
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        store.registerShortcuts()
    }
}
