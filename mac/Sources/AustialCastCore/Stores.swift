import Foundation
import Security

/// Stores the pairing token issued by each TV so later casts need no PIN.
public protocol TokenStore: AnyObject, Sendable {
    func token(for receiverId: String) -> Data?
    func save(token: Data, receiverId: String, name: String)
    func remove(receiverId: String)
    func all() -> [PairedReceiver]
}

public struct PairedReceiver: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var items: [String: (name: String, token: Data)] = [:]
    private let lock = NSLock()
    public init() {}
    public func token(for receiverId: String) -> Data? { lock.lock(); defer { lock.unlock() }; return items[receiverId]?.token }
    public func save(token: Data, receiverId: String, name: String) { lock.lock(); items[receiverId] = (name, token); lock.unlock() }
    public func remove(receiverId: String) { lock.lock(); items[receiverId] = nil; lock.unlock() }
    public func all() -> [PairedReceiver] {
        lock.lock(); defer { lock.unlock() }
        return items.map { PairedReceiver(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
    }
}

/// JSON file store (mode 0600). Used by the CLI and as a fallback when the keychain is unavailable.
public final class FileTokenStore: TokenStore, @unchecked Sendable {
    private struct Entry: Codable { var name: String; var token: String }
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AustialCast/tokens.json")
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func store(_ items: [String: Entry]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func token(for receiverId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[receiverId].flatMap { Data(hex: $0.token) }
    }

    public func save(token: Data, receiverId: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        items[receiverId] = Entry(name: name, token: token.hex)
        store(items)
    }

    public func remove(receiverId: String) {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        items[receiverId] = nil
        store(items)
    }

    public func all() -> [PairedReceiver] {
        lock.lock(); defer { lock.unlock() }
        return load().map { PairedReceiver(id: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
    }
}

/// macOS keychain store (generic passwords).
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.austial.cast.receiver-tokens") { self.service = service }

    private func baseQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    public func token(for receiverId: String) -> Data? {
        var q = baseQuery(receiverId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func save(token: Data, receiverId: String, name: String) {
        SecItemDelete(baseQuery(receiverId) as CFDictionary)
        var q = baseQuery(receiverId)
        q[kSecValueData as String] = token
        q[kSecAttrLabel as String] = name
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public func remove(receiverId: String) { SecItemDelete(baseQuery(receiverId) as CFDictionary) }

    public func all() -> [PairedReceiver] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String else { return nil }
            return PairedReceiver(id: id, name: (item[kSecAttrLabel as String] as? String) ?? id)
        }.sorted { $0.name < $1.name }
    }
}

/// Keychain first, JSON file as fallback (e.g. unsigned dev builds without keychain access).
public final class FallbackTokenStore: TokenStore, @unchecked Sendable {
    private let primary: TokenStore
    private let fallback: TokenStore
    public init(primary: TokenStore, fallback: TokenStore) { self.primary = primary; self.fallback = fallback }

    public func token(for receiverId: String) -> Data? { primary.token(for: receiverId) ?? fallback.token(for: receiverId) }

    public func save(token: Data, receiverId: String, name: String) {
        primary.save(token: token, receiverId: receiverId, name: name)
        if primary.token(for: receiverId) != token { fallback.save(token: token, receiverId: receiverId, name: name) }
    }

    public func remove(receiverId: String) { primary.remove(receiverId: receiverId); fallback.remove(receiverId: receiverId) }

    public func all() -> [PairedReceiver] {
        var seen = Set<String>()
        return (primary.all() + fallback.all()).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }
}

public enum IdentityStore {
    /// A stable per-installation device id, persisted in UserDefaults (or `suite` for tests).
    public static func deviceId(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: "austialcast.deviceId") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "austialcast.deviceId")
        return id
    }

    public static func current(defaults: UserDefaults = .standard) -> DeviceIdentity {
        DeviceIdentity(deviceId: deviceId(defaults: defaults), name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }
}
