import Foundation

// MARK: - Saved configuration

struct BridgeConfig: Codable, Identifiable, Hashable {
    var id: String              // bridge id, lowercased (e.g. 001788fffe123456)
    var name: String
    var ip: String
    var appKey: String?         // "hue-application-key"; nil until paired
    var certSHA256: String?     // pinned leaf certificate, captured when the bridge was added
}

struct Shortcut: Codable, Identifiable, Hashable {
    enum Action: String, Codable { case scene, nextScene, toggle }

    var id = UUID()
    var keyCode: UInt32
    var modifiers: UInt32       // Carbon modifier mask
    var keyLabel: String
    var action: Action
    var bridgeID: String
    var groupID: String
    var sceneID: String?
    var groupName: String       // names are kept for display if the bridge is unreachable
    var sceneName: String?

    var keys: String { KeyCombo.symbols(modifiers) + keyLabel }

    var actionDescription: String {
        switch action {
        case .scene: return "\(groupName) → \(sceneName ?? "scene")"
        case .nextScene: return "\(groupName) → next scene"
        case .toggle: return "\(groupName) → on/off"
        }
    }
}

enum ShortcutFile {
    static var url: URL { ConfigFile.directory.appendingPathComponent("shortcuts.json") }

    static func load() -> [Shortcut] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
    }

    static func save(_ shortcuts: [Shortcut]) {
        try? FileManager.default.createDirectory(at: ConfigFile.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(shortcuts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum ConfigFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HueBar", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("bridges.json") }

    static func load() -> [BridgeConfig] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BridgeConfig].self, from: data)) ?? []
    }

    static func save(_ bridges: [BridgeConfig]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(bridges) else { return }
        try? data.write(to: url, options: .atomic)
        // The app keys are credentials for the bridge: keep the file private.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Hue CLIP v2 resources (only the fields HueBar uses)

struct ResourceRef: Codable, Hashable {
    let rid: String
    let rtype: String
}

struct Metadata: Decodable {
    let name: String
    let archetype: String?
}

struct OnState: Decodable { let on: Bool }
struct Dimming: Decodable { let brightness: Double }

/// Rooms and zones share this shape: rooms list devices as children, zones list lights.
struct GroupResource: Decodable {
    let id: String
    let metadata: Metadata
    let children: [ResourceRef]
    let services: [ResourceRef]
}

struct GroupedLightResource: Decodable {
    let id: String
    let on: OnState?
    let dimming: Dimming?
}

struct LightResource: Decodable {
    let id: String
    let owner: ResourceRef
    let metadata: Metadata
    let on: OnState
    let dimming: Dimming?
}

struct SceneResource: Decodable {
    struct Status: Decodable { let active: String? }
    let id: String
    let metadata: Metadata
    let group: ResourceRef
    let status: Status?
}

struct V2Response<T: Decodable>: Decodable {
    struct V2Error: Decodable { let description: String }
    let errors: [V2Error]?
    let data: LossyArray<T>
}

/// Decodes what it can and skips elements it doesn't understand, so one odd
/// resource on the bridge can't blank the whole menu.
struct LossyArray<T: Decodable>: Decodable {
    let items: [T]
    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [T] = []
        while !container.isAtEnd {
            if let item = try? container.decode(T.self) {
                out.append(item)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        items = out
    }
}

// MARK: - What the menu shows

struct LightItem: Identifiable, Hashable {
    let id: String
    var name: String
    var isOn: Bool
    var brightness: Double?
}

struct SceneItem: Identifiable, Hashable {
    let id: String
    var name: String
    var isActive: Bool
}

struct GroupItem: Identifiable, Hashable {
    enum Kind: String { case room, zone }

    let id: String
    let bridgeID: String
    let kind: Kind
    var name: String
    var archetype: String?
    var groupedLightID: String?
    var isOn: Bool
    var brightness: Double?
    var lights: [LightItem]
    var scenes: [SceneItem]

    var activeSceneName: String? { scenes.first(where: \.isActive)?.name }

    var symbol: String {
        if kind == .zone { return "square.dashed" }
        switch archetype ?? "" {
        case "living_room", "lounge", "tv": return "sofa"
        case "kitchen", "dining": return "fork.knife"
        case "bedroom", "kids_bedroom", "guest_room": return "bed.double"
        case "bathroom", "toilet": return "shower"
        case "office", "computer", "studio": return "desktopcomputer"
        case "hallway", "staircase", "front_door", "top_floor", "upstairs", "downstairs": return "door.left.hand.open"
        case "garden", "terrace", "balcony", "porch", "pool", "driveway", "carport": return "leaf"
        case "garage": return "car"
        case "gym": return "dumbbell"
        case "laundry_room", "storage", "attic": return "shippingbox"
        case "nursery": return "teddybear"
        case "music": return "music.note"
        default: return "lightbulb.2"
        }
    }
}

struct BridgeState: Identifiable {
    var config: BridgeConfig
    var groups: [GroupItem] = []
    var error: String?
    var loaded = false

    var id: String { config.id }
    var rooms: [GroupItem] { groups.filter { $0.kind == .room } }
    var zones: [GroupItem] { groups.filter { $0.kind == .zone } }
}

struct DiscoveredBridge: Decodable, Hashable {
    let id: String
    let internalipaddress: String
}
