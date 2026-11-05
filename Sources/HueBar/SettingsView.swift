import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(HueStore.self) private var store
    @State private var manualIP = ""
    @State private var discovered: [DiscoveredBridge] = []
    @State private var searching = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Bridges") {
                if store.configs.isEmpty {
                    Text("No bridges yet. Find or add one below.").foregroundStyle(.secondary)
                }
                ForEach(store.configs) { cfg in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cfg.name)
                            Text("\(cfg.ip) · \(cfg.appKey == nil ? "not paired" : "paired")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.pairingBridgeID == cfg.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(cfg.appKey == nil ? "Pair" : "Re-pair") { Task { await store.pair(cfg.id) } }
                                .disabled(store.pairingBridgeID != nil)
                        }
                        Button(role: .destructive) { store.removeBridge(cfg.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove this bridge from HueBar")
                    }
                }
            }

            Section("Add a bridge") {
                HStack {
                    Button("Find bridges on my network") { Task { await discover() } }
                        .disabled(searching)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(newBridges, id: \.self) { found in
                    HStack {
                        Text(found.internalipaddress).monospacedDigit()
                        Text(found.id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") { Task { await store.addBridge(ip: found.internalipaddress) } }
                    }
                }
                HStack {
                    TextField("Bridge IP address", text: $manualIP)
                    Button("Add") { Task { await store.addBridge(ip: manualIP) } }
                        .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ShortcutsSection()

            Section {
                Toggle("Open HueBar at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            store.settingsMessage = "Couldn't change login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            if let message = store.settingsMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 420, idealHeight: 760, maxHeight: .infinity)
    }

    private var newBridges: [DiscoveredBridge] {
        discovered.filter { found in !store.configs.contains { $0.id == found.id.lowercased() } }
    }

    private func discover() async {
        searching = true
        defer { searching = false }
        do {
            discovered = try await HueClient.discover()
            store.settingsMessage = discovered.isEmpty ? "No bridges found. Enter the IP address instead." : nil
        } catch {
            store.settingsMessage = "Discovery failed: \(error.localizedDescription). Enter the IP address instead."
        }
    }
}
