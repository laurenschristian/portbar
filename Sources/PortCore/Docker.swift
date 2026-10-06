import Foundation

public struct Container: Equatable, Codable {
    public let id: String
    public let name: String
    public let image: String
    public let project: String?
}

public enum Docker {
    static let candidates = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker",
    ]

    public static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}"

    /// Published TCP host ports of running containers, keyed by host port.
    public static func containers() -> [UInt16: Container] {
        guard let docker = binary, let out = run(docker, ["ps", "--format", format], timeout: 4) else { return [:] }
        return parse(out)
    }

    public static func stop(_ c: Container) -> Bool {
        guard let docker = binary else { return false }
        return run(docker, ["stop", c.id], timeout: 30) != nil
    }

    public static func restart(_ c: Container) -> Bool {
        guard let docker = binary else { return false }
        return run(docker, ["restart", c.id], timeout: 60) != nil
    }

    /// Memory (bytes) and CPU percent per container id. Takes about 2 s because docker samples once.
    public static func stats() -> [String: (memory: UInt64, cpu: Double)] {
        guard let docker = binary,
              let out = run(docker, ["stats", "--no-stream", "--format", "{{.ID}}\t{{.MemUsage}}\t{{.CPUPerc}}"], timeout: 10) else { return [:] }
        return parseStats(out)
    }

    static func parseStats(_ out: String) -> [String: (memory: UInt64, cpu: Double)] {
        var map: [String: (memory: UInt64, cpu: Double)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let used = f[1].components(separatedBy: " / ").first else { continue }
            map[f[0]] = (bytes(used), Double(f[2].dropLast()) ?? 0)
        }
        return map
    }

    // "512.3MiB", "1.2GiB", "980kB"
    static func bytes(_ s: String) -> UInt64 {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (unit, scale) in units where s.hasSuffix(unit) {
            return UInt64((Double(s.dropLast(unit.count)) ?? 0) * scale)
        }
        return 0
    }

    public static func parse(_ out: String) -> [UInt16: Container] {
        var map: [UInt16: Container] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            let project = f.count > 4 && !f[4].isEmpty ? f[4] : nil
            let c = Container(id: f[0], name: f[1], image: f[2], project: project)
            for port in hostPorts(f[3]) where map[port] == nil { map[port] = c }
        }
        return map
    }

    // "0.0.0.0:5433->5432/tcp, [::]:8000-8002->8000-8002/tcp"
    static func hostPorts(_ s: String) -> [UInt16] {
        s.components(separatedBy: ", ").flatMap { mapping -> [UInt16] in
            guard mapping.hasSuffix("/tcp"), let arrow = mapping.range(of: "->") else { return [] }
            let host = mapping[..<arrow.lowerBound]
            guard let colon = host.lastIndex(of: ":") else { return [] }
            let bounds = host[host.index(after: colon)...].split(separator: "-").compactMap { UInt16($0) }
            guard let lo = bounds.first else { return [] }
            return Array(lo...(bounds.last ?? lo))
        }
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
