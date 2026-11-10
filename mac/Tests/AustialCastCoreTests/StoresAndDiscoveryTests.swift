import Network
import XCTest
@testable import AustialCastCore
import AustialCastProtocol

final class StoresAndDiscoveryTests: XCTestCase {
    private func exercise(_ store: TokenStore) {
        XCTAssertNil(store.token(for: "tv1"))
        store.save(token: Data([1, 2, 3]), receiverId: "tv1", name: "Living Room")
        store.save(token: Data([4]), receiverId: "tv2", name: "Bedroom")
        XCTAssertEqual(store.token(for: "tv1"), Data([1, 2, 3]))
        XCTAssertEqual(store.all().map(\.name), ["Bedroom", "Living Room"])
        store.save(token: Data([9]), receiverId: "tv1", name: "Living Room")
        XCTAssertEqual(store.token(for: "tv1"), Data([9]), "saving again replaces the token")
        store.remove(receiverId: "tv1")
        XCTAssertNil(store.token(for: "tv1"))
        store.remove(receiverId: "tv2")
        XCTAssertTrue(store.all().isEmpty)
    }

    func testMemoryStore() { exercise(MemoryTokenStore()) }

    func testFileStoreAndPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("austialcast-test-\(UUID().uuidString)/tokens.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)
        exercise(store)
        store.save(token: Data([7]), receiverId: "x", name: "X")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "token file must be private")
        XCTAssertEqual(FileTokenStore(url: url).token(for: "x"), Data([7]), "persists across instances")
    }

    func testKeychainStore() {
        let store = KeychainTokenStore(service: "app.austial.cast.tests.\(UUID().uuidString)")
        store.save(token: Data([1, 2, 3]), receiverId: "k1", name: "Keychain TV")
        defer { store.remove(receiverId: "k1") }
        // Unsigned test binaries may be refused keychain access; only assert when it worked.
        if let t = store.token(for: "k1") {
            XCTAssertEqual(t, Data([1, 2, 3]))
            XCTAssertEqual(store.all().first?.name, "Keychain TV")
        } else {
            print("note: keychain unavailable in this environment, skipping assertions")
        }
    }

    func testFallbackStoreUsesFileWhenPrimaryFails() {
        final class BrokenStore: TokenStore, @unchecked Sendable {
            func token(for receiverId: String) -> Data? { nil }
            func save(token: Data, receiverId: String, name: String) {}
            func remove(receiverId: String) {}
            func all() -> [PairedReceiver] { [] }
        }
        let fallback = MemoryTokenStore()
        let store = FallbackTokenStore(primary: BrokenStore(), fallback: fallback)
        store.save(token: Data([5]), receiverId: "a", name: "A")
        XCTAssertEqual(store.token(for: "a"), Data([5]))
        XCTAssertEqual(store.all().map(\.id), ["a"])
        store.remove(receiverId: "a")
        XCTAssertNil(store.token(for: "a"))
    }

    func testDeviceIdIsStable() {
        let defaults = UserDefaults(suiteName: "austialcast.tests.\(UUID().uuidString)")!
        let a = IdentityStore.deviceId(defaults: defaults)
        XCTAssertEqual(a, IdentityStore.deviceId(defaults: defaults))
        XCTAssertNotEqual(a, IdentityStore.deviceId(defaults: UserDefaults(suiteName: "austialcast.tests.\(UUID().uuidString)")!))
    }

    func testParseHostPort() {
        XCTAssertTrue(parseHostPort("192.168.1.20")! == ("192.168.1.20", defaultPort))
        XCTAssertTrue(parseHostPort(" 192.168.1.20:8000 ")! == ("192.168.1.20", 8000))
        XCTAssertTrue(parseHostPort("tv.local:7391")! == ("tv.local", 7391))
        XCTAssertTrue(parseHostPort("[fe80::1]:9000")! == ("fe80::1", 9000))
        XCTAssertTrue(parseHostPort("[fe80::1]")! == ("fe80::1", defaultPort))
        XCTAssertTrue(parseHostPort("fe80::1")! == ("fe80::1", defaultPort))
        XCTAssertNil(parseHostPort(""))
        XCTAssertNil(parseHostPort("host:abc"))
        XCTAssertNil(parseHostPort("host:0"))
        XCTAssertNil(parseHostPort("host:99999"))
        XCTAssertNil(parseHostPort(":7391"))
        XCTAssertNil(parseHostPort("[::1"))
    }

    func testReceiverListFromBonjourResults() {
        func svc(_ name: String) -> NWEndpoint { .service(name: name, type: "_austialcast._tcp", domain: "local.", interface: nil) }
        let list = ReceiverBrowser.receivers(from: [
            (svc("zeta"), ["id": "id-z", "name": "Zeta TV"]),
            (svc("alpha"), [:]),
            (svc("dup"), ["id": "id-z"]),
            (.hostPort(host: "1.2.3.4", port: 80), [:]),
        ])
        XCTAssertEqual(list.map(\.name), ["alpha", "Zeta TV"])
        XCTAssertEqual(list.map(\.id), ["alpha", "id-z"], "duplicates by id collapse; non-service endpoints are ignored")
    }
}
