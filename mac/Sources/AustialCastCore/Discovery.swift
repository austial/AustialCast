import Combine
import Foundation
import Network
import AustialCastProtocol

public struct DiscoveredReceiver: Identifiable, Hashable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public init(id: String, name: String, endpoint: NWEndpoint) { self.id = id; self.name = name; self.endpoint = endpoint }
}

/// Finds TVs advertising `_austialcast._tcp` on the local network via Bonjour.
public final class ReceiverBrowser: ObservableObject, @unchecked Sendable {
    @Published public private(set) var receivers: [DiscoveredReceiver] = []
    @Published public private(set) var failure: String?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "austialcast.browser")

    public init() {}

    /// Pure conversion kept separate for unit tests.
    public static func receivers(from results: [(endpoint: NWEndpoint, txt: [String: String])]) -> [DiscoveredReceiver] {
        var seen = Set<String>()
        var out: [DiscoveredReceiver] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            let id = r.txt["id"] ?? name
            guard seen.insert(id).inserted else { continue }
            out.append(DiscoveredReceiver(id: id, name: r.txt["name"] ?? name, endpoint: r.endpoint))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func start() {
        stop()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.failure = e.localizedDescription }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped = results.map { result -> (NWEndpoint, [String: String]) in
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata {
                    for key in ["id", "name"] { if let v = record.dictionary[key] { txt[key] = v } }
                }
                return (result.endpoint, txt)
            }
            let list = ReceiverBrowser.receivers(from: mapped.map { (endpoint: $0.0, txt: $0.1) })
            DispatchQueue.main.async { self?.receivers = list }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Parses user input such as `192.168.1.20`, `192.168.1.20:7391` or `[fe80::1]:7391`.
public func parseHostPort(_ input: String) -> (host: String, port: UInt16)? {
    let s = input.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    if s.hasPrefix("[") {
        guard let close = s.firstIndex(of: "]") else { return nil }
        let host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]
        if rest.isEmpty { return (host, defaultPort) }
        guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()), p > 0 else { return nil }
        return (host, p)
    }
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 1 { return (s, defaultPort) }
    if parts.count == 2 {
        guard !parts[0].isEmpty, let p = UInt16(parts[1]), p > 0 else { return nil }
        return (String(parts[0]), p)
    }
    // Bare IPv6 address without port.
    return s.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) ? (s, defaultPort) : nil
}
