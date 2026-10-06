import Darwin
import Foundation

public struct Claim: Codable, Equatable {
    public let port: UInt16
    public let label: String
    public let cwd: String?
    public let at: Date
}

/// Hands out free ports and remembers short-lived claims so parallel agents do not pick the same one.
public enum Ports {
    /// An unused claim lapses after this; a claim whose port is listening lives as long as the server.
    public static let claimTTL: TimeInterval = 600

    static var store: UserDefaults { UserDefaults(suiteName: Activity.suite) ?? .standard }

    public static func claims(now: Date = Date(), listening: Set<UInt16>? = nil) -> [Claim] {
        let live = listening ?? Set(Scanner.sockets().map(\.port))
        let all = (store.data(forKey: "claims")).flatMap { try? JSONDecoder().decode([Claim].self, from: $0) } ?? []
        return all.filter { live.contains($0.port) || now.timeIntervalSince($0.at) < claimTTL }
    }

    /// The first port at or above `start` that nothing listens on, nobody claimed, and the kernel lets us bind.
    public static func nextFree(from start: UInt16 = 8000, claim label: String? = nil, cwd: String? = nil) -> UInt16? {
        let listening = Set(Scanner.sockets().map(\.port))
        var claims = claims(listening: listening)
        let taken = listening.union(claims.map(\.port))
        guard let port = (start...UInt16.max).first(where: { !taken.contains($0) && bindable($0) }) else { return nil }
        if let label {
            claims.append(Claim(port: port, label: label, cwd: cwd, at: Date()))
            store.set(try? JSONEncoder().encode(claims), forKey: "claims")
        }
        return port
    }

    /// Catches ports held by other users or root, which libproc cannot see.
    public static func bindable(_ port: UInt16) -> Bool {
        [AF_INET, AF_INET6].allSatisfy { family in
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return true }
            defer { close(fd) }
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian
                return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            }
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        }
    }
}
