import CryptoKit
import Foundation
import Security

enum HueFailure: LocalizedError {
    case notPaired
    case unauthorized
    case certificateMismatch
    case http(Int)
    case bridge(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired yet. Open Settings and pair this bridge."
        case .unauthorized: return "The bridge rejected HueBar's key. Pair again in Settings."
        case .certificateMismatch: return "The bridge's certificate doesn't match the one HueBar trusted. Remove and re-add the bridge if you replaced or reset it."
        case .http(let code): return "The bridge answered HTTP \(code)."
        case .bridge(let message): return "Bridge error: \(message)"
        case .badResponse: return "The bridge sent a response HueBar couldn't read."
        }
    }
}

/// Hue bridges present a certificate signed by Signify's private root, issued to the
/// bridge id rather than its IP, so normal hostname validation can't pass. Instead we
/// check that the certificate names the expected bridge, then pin its exact SHA-256.
final class TLSPinner: NSObject, URLSessionDelegate, @unchecked Sendable {
    struct Observed { let sha256: String; let commonName: String }

    private let lock = NSLock()
    private let expectedBridgeID: String?
    private let pinnedSHA256: String?
    private var _observed: Observed?

    var observed: Observed? { lock.withLock { _observed } }

    init(expectedBridgeID: String?, pinnedSHA256: String?) {
        self.expectedBridgeID = expectedBridgeID?.lowercased()
        self.pinnedSHA256 = pinnedSHA256
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return (.performDefaultHandling, nil) }

        let der = SecCertificateCopyData(leaf) as Data
        let sha = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        var cn: CFString?
        SecCertificateCopyCommonName(leaf, &cn)
        let commonName = (cn as String?) ?? ""
        lock.withLock { _observed = Observed(sha256: sha, commonName: commonName) }

        if let pinned = pinnedSHA256 {
            return sha == pinned ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
        if let expected = expectedBridgeID, commonName.lowercased() != expected {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

final class HueClient: @unchecked Sendable {
    let config: BridgeConfig
    private let session: URLSession

    init(config: BridgeConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpMaximumConnectionsPerHost = 4
        let pinner = TLSPinner(expectedBridgeID: config.id, pinnedSHA256: config.certSHA256)
        session = URLSession(configuration: cfg, delegate: pinner, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    private var base: String { "https://\(config.ip)" }

    // MARK: Adding and pairing

    /// Reads the bridge's public config over HTTPS and captures its certificate. No credentials are sent.
    static func probe(ip: String) async throws -> BridgeConfig {
        struct PublicConfig: Decodable { let name: String; let bridgeid: String }
        let pinner = TLSPinner(expectedBridgeID: nil, pinnedSHA256: nil)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: cfg, delegate: pinner, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        guard let url = URL(string: "https://\(ip)/api/0/config") else { throw HueFailure.badResponse }
        let (data, _) = try await session.data(from: url)
        guard let pub = try? JSONDecoder().decode(PublicConfig.self, from: data) else { throw HueFailure.badResponse }
        guard let seen = pinner.observed, seen.commonName.lowercased() == pub.bridgeid.lowercased() else {
            throw HueFailure.certificateMismatch
        }
        return BridgeConfig(id: pub.bridgeid.lowercased(), name: pub.name, ip: ip, appKey: nil, certSHA256: seen.sha256)
    }

    /// Asks the bridge for a new app key. Returns nil while the link button hasn't been pressed.
    func requestAppKey() async throws -> String? {
        let host = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "#", with: "")
        let body: [String: Any] = ["devicetype": "HueBar#\(host.prefix(19))", "generateclientkey": true]
        var req = URLRequest(url: URL(string: "\(base)/api")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)

        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first else {
            throw HueFailure.badResponse
        }
        if let success = first["success"] as? [String: Any], let key = success["username"] as? String {
            return key
        }
        if let err = first["error"] as? [String: Any] {
            if (err["type"] as? Int) == 101 { return nil }   // link button not pressed
            throw HueFailure.bridge(err["description"] as? String ?? "unknown")
        }
        throw HueFailure.badResponse
    }

    static func discover() async throws -> [DiscoveredBridge] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://discovery.meethue.com")!)
        return try JSONDecoder().decode([DiscoveredBridge].self, from: data)
    }

    // MARK: CLIP v2

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let key = config.appKey else { throw HueFailure.notPaired }
        var req = URLRequest(url: URL(string: "\(base)/clip/v2/resource/\(path)")!)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "hue-application-key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled || error.code == .serverCertificateUntrusted {
            throw HueFailure.certificateMismatch
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw HueFailure.unauthorized }
        guard (200..<300).contains(status) else {
            if let errs = try? JSONDecoder().decode(V2Response<ResourceRef>.self, from: data).errors, let first = errs.first {
                throw HueFailure.bridge(first.description)
            }
            throw HueFailure.http(status)
        }
        return data
    }

    func list<T: Decodable>(_ type: String) async throws -> [T] {
        let data = try await request(type)
        guard let decoded = try? JSONDecoder().decode(V2Response<T>.self, from: data) else { throw HueFailure.badResponse }
        return decoded.data.items
    }

    func update(_ type: String, id: String, _ body: [String: Any]) async throws {
        _ = try await request("\(type)/\(id)", method: "PUT", body: body)
    }

    /// Fetches rooms and zones with their lights and scenes, ready for the menu.
    func fetchGroups() async throws -> [GroupItem] {
        async let roomsReq: [GroupResource] = list("room")
        async let zonesReq: [GroupResource] = list("zone")
        async let groupedReq: [GroupedLightResource] = list("grouped_light")
        async let lightsReq: [LightResource] = list("light")
        async let scenesReq: [SceneResource] = list("scene")
        let (rooms, zones, grouped, lights, scenes) = try await (roomsReq, zonesReq, groupedReq, lightsReq, scenesReq)

        let groupedByID = Dictionary(grouped.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lightByID = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lightsByDevice = Dictionary(grouping: lights, by: { $0.owner.rid })
        let scenesByGroup = Dictionary(grouping: scenes, by: { $0.group.rid })

        func item(_ res: GroupResource, _ kind: GroupItem.Kind) -> GroupItem {
            var members: [LightResource] = []
            for child in res.children {
                switch child.rtype {
                case "device": members += lightsByDevice[child.rid] ?? []
                case "light": if let l = lightByID[child.rid] { members.append(l) }
                default: break
                }
            }
            let lightItems = members
                .map { LightItem(id: $0.id, name: $0.metadata.name, isOn: $0.on.on, brightness: $0.dimming?.brightness) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            let glID = res.services.first { $0.rtype == "grouped_light" }?.rid
            let gl = glID.flatMap { groupedByID[$0] }
            let isOn = gl?.on?.on ?? lightItems.contains(where: \.isOn)
            var brightness = gl?.dimming?.brightness
            if brightness == nil {
                let dims = lightItems.filter(\.isOn).compactMap(\.brightness)
                if !dims.isEmpty { brightness = dims.reduce(0, +) / Double(dims.count) }
            }

            let sceneItems = (scenesByGroup[res.id] ?? [])
                .map { SceneItem(id: $0.id, name: $0.metadata.name, isActive: ($0.status?.active ?? "inactive") != "inactive") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            return GroupItem(id: res.id, bridgeID: config.id, kind: kind, name: res.metadata.name,
                             archetype: res.metadata.archetype, groupedLightID: glID, isOn: isOn,
                             brightness: brightness, lights: lightItems, scenes: sceneItems)
        }

        let byName: (GroupItem, GroupItem) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return rooms.map { item($0, .room) }.sorted(by: byName) + zones.map { item($0, .zone) }.sorted(by: byName)
    }
}
