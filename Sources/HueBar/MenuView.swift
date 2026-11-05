import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(HueStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<String>
    @State private var contentHeight: CGFloat = 120

    init(initiallyExpanded: String? = nil) {
        _expanded = State(initialValue: initiallyExpanded.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.vertical, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 60), 560))
            Divider()
            footer
        }
        .frame(width: 340)
        .task {
            while !Task.isCancelled {
                await store.refreshAll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("HueBar").font(.headline)
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if store.bridges.isEmpty {
            VStack(spacing: 8) {
                Text("No Hue Bridge set up yet.").foregroundStyle(.secondary)
                Button("Open Settings") { openSettings() }
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.bridges) { bridge in
                    if store.bridges.count > 1 {
                        Text(bridge.config.name.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    if let error = bridge.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    } else if !bridge.loaded {
                        Text("Loading…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    ForEach(bridge.rooms) { row($0) }
                    if !bridge.zones.isEmpty {
                        Text("Zones").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 6)
                        ForEach(bridge.zones) { row($0) }
                    }
                }
            }
        }
    }

    private func row(_ group: GroupItem) -> some View {
        GroupRow(group: group, expanded: Binding(
            get: { expanded.contains(group.id) },
            set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }
        ))
    }

    private var footer: some View {
        HStack {
            Button("All Off") { store.allOff() }
                .disabled(!store.anyOn)
            Spacer()
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

struct GroupRow: View {
    @Environment(HueStore.self) private var store
    let group: GroupItem
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Image(systemName: group.symbol)
                    .foregroundStyle(group.isOn ? Color.yellow : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).lineLimit(1)
                    if group.isOn, let scene = group.activeSceneName {
                        Text(scene).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if group.isOn, let b = group.brightness {
                    Text("\(Int(b.rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { group.isOn }, set: { store.setOn(group, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if group.isOn, let b = group.brightness {
                Slider(value: Binding(get: { b }, set: { store.setBrightness(group, $0) }), in: 1...100)
                    .controlSize(.small)
                    .padding(.leading, 40)
            }

            if expanded { details }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.scenes.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(group.scenes) { scene in
                        Button { store.recall(scene, in: group) } label: {
                            HStack(spacing: 3) {
                                if scene.isActive && group.isOn { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                                Text(scene.name).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(store.shortcut(forScene: scene.id).map { "Shortcut: \($0.keys)" } ?? scene.name)
                    }
                }
            }
            ForEach(group.lights) { light in
                LightRow(light: light, bridgeID: group.bridgeID)
            }
        }
        .padding(.leading, 40)
        .padding(.top, 2)
    }
}

struct LightRow: View {
    @Environment(HueStore.self) private var store
    let light: LightItem
    let bridgeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.caption)
                    .foregroundStyle(light.isOn ? Color.yellow : Color.secondary)
                Text(light.name).font(.callout).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { light.isOn }, set: { store.setOn(light, bridgeID: bridgeID, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if light.isOn, let b = light.brightness {
                Slider(value: Binding(get: { b }, set: { store.setBrightness(light, bridgeID: bridgeID, $0) }), in: 1...100)
                    .controlSize(.mini)
                    .padding(.leading, 18)
            }
        }
    }
}
