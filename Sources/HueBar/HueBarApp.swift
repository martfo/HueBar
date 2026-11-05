import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if ["--selftest", "--add-bridge", "--snapshot", "--pair"].contains(where: args.contains) {
            CLI.run(args)
        } else {
            HueBarApp.main()
        }
    }
}

struct HueBarApp: App {
    @State private var store = HueStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(store)
        } label: {
            Image(systemName: store.anyOn ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)

        Window("HueBar Settings", id: "settings") {
            SettingsView().environment(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Headless helpers for setup and checks from the terminal:
///   HueBar --add-bridge <ip> <app-key>   add a bridge with an existing key (pins its certificate)
///   HueBar --selftest                    load every configured bridge and print what the menu would show
enum CLI {
    static func run(_ args: [String]) {
        Task { @MainActor in
            var code: Int32 = 0
            do {
                if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
                    try await snapshot(to: args[i + 1], expandFirst: args.contains("--expand"))
                } else if let i = args.firstIndex(of: "--pair"), args.count > i + 1 {
                    code = try await pair(ip: args[i + 1])
                } else if let i = args.firstIndex(of: "--add-bridge") {
                    guard args.count > i + 2 else { throw HueFailure.bridge("usage: --add-bridge <ip> <app-key>") }
                    try await addBridge(ip: args[i + 1], key: args[i + 2])
                } else {
                    code = await selftest()
                }
            } catch {
                print("error: \(error.localizedDescription)")
                code = 1
            }
            exit(code)
        }
        // Not dispatchMain(): that parks the main thread, and --snapshot needs AppKit on it.
        RunLoop.main.run()
    }

    static func addBridge(ip: String, key: String) async throws {
        var cfg = try await HueClient.probe(ip: ip)
        cfg.appKey = key
        _ = try await HueClient(config: cfg).list("room") as [GroupResource]
        var all = ConfigFile.load().filter { $0.id != cfg.id }
        all.append(cfg)
        ConfigFile.save(all)
        print("added \(cfg.name) (\(cfg.id)) at \(ip); certificate pinned \(cfg.certSHA256!.prefix(16))…")
    }

    /// Adds a bridge and waits up to 90 s for its link button to be pressed.
    static func pair(ip: String) async throws -> Int32 {
        var cfg = try await HueClient.probe(ip: ip)
        let client = HueClient(config: cfg)
        print("waiting for the link button on \(cfg.name) (\(cfg.id))…")
        for _ in 0..<45 {
            if let key = try await client.requestAppKey() {
                cfg.appKey = key
                var all = ConfigFile.load().filter { $0.id != cfg.id }
                all.append(cfg)
                ConfigFile.save(all)
                print("paired \(cfg.name); certificate pinned \(cfg.certSHA256!.prefix(16))…")
                return 0
            }
            try? await Task.sleep(for: .seconds(2))
        }
        print("timed out: link button wasn't pressed")
        return 1
    }

    /// Renders the real menu offscreen to a PNG, for checking the layout without opening the menu bar.
    @MainActor
    static func snapshot(to path: String, expandFirst: Bool) async throws {
        _ = NSApplication.shared
        let store = HueStore()
        await store.refreshAll()
        let root: AnyView = CommandLine.arguments.contains("--settings")
            ? AnyView(SettingsView())
            : AnyView(MenuView(initiallyExpanded: expandFirst ? store.bridges.first?.rooms.first(where: \.isOn)?.id : nil))
        let view = root
            .environment(store)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["HUEBAR_LIGHT"] == nil ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 340, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(400))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HueFailure.badResponse }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(host.bounds.width))x\(Int(host.bounds.height)))")
    }

    static func selftest() async -> Int32 {
        let configs = ConfigFile.load()
        if configs.isEmpty { print("no bridges in \(ConfigFile.url.path)"); return 1 }
        var failed = false
        for cfg in configs {
            print("== \(cfg.name) (\(cfg.ip)) \(cfg.appKey == nil ? "NOT PAIRED" : "")")
            guard cfg.appKey != nil else { continue }
            let client = HueClient(config: cfg)
            do {
                let groups = try await client.fetchGroups()
                for g in groups {
                    let state = g.isOn ? "on \(g.brightness.map { "\(Int($0.rounded()))%" } ?? "")" : "off"
                    print("  [\(g.kind.rawValue)] \(g.name): \(state) · \(g.lights.count) lights · \(g.scenes.count) scenes")
                }
                // Write path check that changes nothing: re-send a room's current on/off state.
                if let g = groups.first(where: { $0.kind == .room && $0.groupedLightID != nil }) {
                    try await client.update("grouped_light", id: g.groupedLightID!, ["on": ["on": g.isOn]])
                    print("  write check OK (re-sent \(g.name) = \(g.isOn ? "on" : "off"))")
                }
            } catch {
                print("  error: \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}
