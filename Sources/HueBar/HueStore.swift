import Foundation
import Observation

@MainActor
@Observable
final class HueStore {
    private(set) var configs: [BridgeConfig]
    private(set) var bridges: [BridgeState] = []
    private(set) var isRefreshing = false
    var pairingBridgeID: String?
    var settingsMessage: String?
    private(set) var shortcuts: [Shortcut] = ShortcutFile.load()
    /// Shortcuts macOS refused to register, usually because another app owns the combination.
    private(set) var shortcutConflicts: Set<UUID> = []

    var anyOn: Bool { bridges.contains { $0.rooms.contains(where: \.isOn) } }

    @ObservationIgnored private var clients: [String: HueClient] = [:]
    @ObservationIgnored private var lastInteraction = Date.distantPast
    @ObservationIgnored private var lastDiscovery = Date.distantPast
    @ObservationIgnored private var pendingBrightness: [String: Double] = [:]
    @ObservationIgnored private var throttled: Set<String> = []

    init() {
        configs = ConfigFile.load()
        bridges = configs.map { BridgeState(config: $0) }
        Task { [weak self] in self?.registerShortcuts() }
        // Keeps the menu bar icon roughly in sync even when the menu is closed.
        Task { [weak self] in
            while let self {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func client(for id: String) -> HueClient? {
        if let c = clients[id] { return c }
        guard let cfg = configs.first(where: { $0.id == id }) else { return nil }
        let c = HueClient(config: cfg)
        clients[id] = c
        return c
    }

    // MARK: Refresh

    func refreshAll() async {
        // Don't let a poll yank a slider the user is still dragging.
        guard Date().timeIntervalSince(lastInteraction) > 2, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for cfg in configs { group.addTask { await self.refresh(cfg.id) } }
        }
    }

    private func refresh(_ id: String, allowRediscovery: Bool = true) async {
        guard let client = client(for: id) else { return }
        do {
            let groups = try await client.fetchGroups()
            guard Date().timeIntervalSince(lastInteraction) > 2 else { return }
            setBridge(id) { $0.groups = groups; $0.error = nil; $0.loaded = true }
        } catch let error as URLError where allowRediscovery && [.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            if await rediscover(id) {
                await refresh(id, allowRediscovery: false)
            } else {
                setBridge(id) { $0.error = "Can't reach \($0.config.name) at \($0.config.ip)."; $0.loaded = true }
            }
        } catch {
            setBridge(id) { $0.error = error.localizedDescription; $0.loaded = true }
        }
    }

    /// If the bridge's IP changed (DHCP), find it again by id via Philips' discovery service.
    private func rediscover(_ id: String) async -> Bool {
        guard Date().timeIntervalSince(lastDiscovery) > 15 * 60 else { return false }
        lastDiscovery = Date()
        guard let found = try? await HueClient.discover(),
              let match = found.first(where: { $0.id.lowercased() == id }),
              var cfg = configs.first(where: { $0.id == id }),
              cfg.ip != match.internalipaddress
        else { return false }
        cfg.ip = match.internalipaddress
        upsert(cfg)
        return true
    }

    private func setBridge(_ id: String, _ change: (inout BridgeState) -> Void) {
        guard let i = bridges.firstIndex(where: { $0.id == id }) else { return }
        change(&bridges[i])
    }

    private func setGroups(_ bridgeID: String, _ change: (inout GroupItem) -> Void) {
        setBridge(bridgeID) { b in
            for i in b.groups.indices { change(&b.groups[i]) }
        }
    }

    // MARK: Actions

    private func send(_ bridgeID: String, _ type: String, _ id: String, _ body: [String: Any]) {
        guard let client = client(for: bridgeID) else { return }
        Task {
            do { try await client.update(type, id: id, body) }
            catch { setBridge(bridgeID) { $0.error = error.localizedDescription } }
        }
    }

    func setOn(_ group: GroupItem, _ on: Bool) {
        guard let gl = group.groupedLightID else { return }
        lastInteraction = Date()
        let memberIDs = Set(group.lights.map(\.id))
        setGroups(group.bridgeID) { g in
            if g.id == group.id { g.isOn = on }
            for i in g.lights.indices where memberIDs.contains(g.lights[i].id) { g.lights[i].isOn = on }
            if g.id == group.id, !on { for i in g.scenes.indices { g.scenes[i].isActive = false } }
        }
        send(group.bridgeID, "grouped_light", gl, ["on": ["on": on]])
    }

    func setBrightness(_ group: GroupItem, _ value: Double) {
        guard let gl = group.groupedLightID else { return }
        lastInteraction = Date()
        setGroups(group.bridgeID) { g in if g.id == group.id { g.brightness = value } }
        throttle(group.bridgeID, "grouped_light", gl, value)
    }

    func setOn(_ light: LightItem, bridgeID: String, _ on: Bool) {
        lastInteraction = Date()
        setGroups(bridgeID) { g in
            for i in g.lights.indices where g.lights[i].id == light.id { g.lights[i].isOn = on }
            if g.lights.contains(where: { $0.id == light.id }) { g.isOn = g.lights.contains(where: \.isOn) }
        }
        send(bridgeID, "light", light.id, ["on": ["on": on]])
    }

    func setBrightness(_ light: LightItem, bridgeID: String, _ value: Double) {
        lastInteraction = Date()
        setGroups(bridgeID) { g in
            for i in g.lights.indices where g.lights[i].id == light.id { g.lights[i].brightness = value }
        }
        throttle(bridgeID, "light", light.id, value)
    }

    func recall(_ scene: SceneItem, in group: GroupItem) {
        lastInteraction = Date()
        setGroups(group.bridgeID) { g in
            guard g.id == group.id else { return }
            g.isOn = true
            for i in g.scenes.indices { g.scenes[i].isActive = g.scenes[i].id == scene.id }
        }
        send(group.bridgeID, "scene", scene.id, ["recall": ["action": "active"]])
        // Pick up the scene's real brightness once the bridge has applied it.
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await refreshAll()
        }
    }

    func allOff() {
        for bridge in bridges {
            for room in bridge.rooms where room.isOn { setOn(room, false) }
        }
    }

    /// Slider drags fire constantly; the bridge copes with a few commands a second,
    /// so send at most every 250 ms and always finish on the latest value.
    private func throttle(_ bridgeID: String, _ type: String, _ id: String, _ value: Double) {
        pendingBrightness[id] = value
        guard !throttled.contains(id), let client = client(for: bridgeID) else { return }
        throttled.insert(id)
        Task {
            while let v = pendingBrightness.removeValue(forKey: id) {
                do { try await client.update(type, id: id, ["on": ["on": true], "dimming": ["brightness": v]]) }
                catch { setBridge(bridgeID) { $0.error = error.localizedDescription } }
                try? await Task.sleep(for: .milliseconds(250))
            }
            throttled.remove(id)
        }
    }

    // MARK: Keyboard shortcuts

    func registerShortcuts() {
        HotKeyCenter.shared.unregisterAll()
        var conflicts: Set<UUID> = []
        for shortcut in shortcuts {
            let status = HotKeyCenter.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { await self?.perform(shortcut) }
            }
            if status != noErr { conflicts.insert(shortcut.id) }
        }
        shortcutConflicts = conflicts
    }

    /// While a new shortcut is being recorded, existing ones must not fire (or swallow the keys).
    func suspendShortcuts() { HotKeyCenter.shared.unregisterAll() }

    func addShortcut(_ shortcut: Shortcut) {
        // One action per key combination: a new binding replaces an old one.
        shortcuts.removeAll { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }
        shortcuts.append(shortcut)
        ShortcutFile.save(shortcuts)
        registerShortcuts()
    }

    func removeShortcut(_ id: UUID) {
        shortcuts.removeAll { $0.id == id }
        ShortcutFile.save(shortcuts)
        registerShortcuts()
    }

    func shortcut(forScene sceneID: String) -> Shortcut? {
        shortcuts.first { $0.action == .scene && $0.sceneID == sceneID }
    }

    private func group(_ bridgeID: String, _ groupID: String) -> GroupItem? {
        bridges.first { $0.id == bridgeID }?.groups.first { $0.id == groupID }
    }

    func perform(_ shortcut: Shortcut) async {
        // Cycling and toggling depend on current state; refresh it unless we've just acted ourselves.
        if shortcut.action != .scene, Date().timeIntervalSince(lastInteraction) > 2 {
            await refresh(shortcut.bridgeID)
        }
        let target = group(shortcut.bridgeID, shortcut.groupID)
        switch shortcut.action {
        case .scene:
            guard let sceneID = shortcut.sceneID else { return }
            if let target, let scene = target.scenes.first(where: { $0.id == sceneID }) {
                recall(scene, in: target)
            } else {
                // Not loaded yet (e.g. just after launch): the ids are enough to recall it.
                send(shortcut.bridgeID, "scene", sceneID, ["recall": ["action": "active"]])
            }
        case .nextScene:
            guard let target, !target.scenes.isEmpty else { return }
            let current = target.isOn ? target.scenes.firstIndex(where: \.isActive) : nil
            let next = current.map { ($0 + 1) % target.scenes.count } ?? 0
            recall(target.scenes[next], in: target)
        case .toggle:
            guard let target else { return }
            setOn(target, !target.isOn)
        }
    }

    // MARK: Bridges (Settings)

    func upsert(_ cfg: BridgeConfig) {
        if let i = configs.firstIndex(where: { $0.id == cfg.id }) { configs[i] = cfg } else { configs.append(cfg) }
        if let i = bridges.firstIndex(where: { $0.id == cfg.id }) { bridges[i].config = cfg } else { bridges.append(BridgeState(config: cfg)) }
        clients[cfg.id] = nil
        ConfigFile.save(configs)
    }

    func removeBridge(_ id: String) {
        configs.removeAll { $0.id == id }
        bridges.removeAll { $0.id == id }
        clients[id] = nil
        ConfigFile.save(configs)
    }

    func addBridge(ip: String) async {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        settingsMessage = "Contacting \(ip)…"
        do {
            var cfg = try await HueClient.probe(ip: ip)
            if let existing = configs.first(where: { $0.id == cfg.id }) {
                cfg.appKey = existing.appKey
            }
            upsert(cfg)
            settingsMessage = "Added \(cfg.name). Now pair it."
            await pair(cfg.id)
        } catch {
            settingsMessage = "Couldn't add \(ip): \(error.localizedDescription)"
        }
    }

    func pair(_ id: String) async {
        guard let cfg = configs.first(where: { $0.id == id }) else { return }
        pairingBridgeID = id
        defer { pairingBridgeID = nil }
        settingsMessage = "Press the round link button on \(cfg.name) now…"
        let client = HueClient(config: cfg)
        for _ in 0..<20 {
            do {
                if let key = try await client.requestAppKey() {
                    var updated = cfg
                    updated.appKey = key
                    upsert(updated)
                    settingsMessage = "Paired with \(cfg.name)."
                    await refresh(id)
                    return
                }
            } catch {
                settingsMessage = "Pairing failed: \(error.localizedDescription)"
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        settingsMessage = "Timed out. Press the bridge's link button, then click Pair again."
    }
}
