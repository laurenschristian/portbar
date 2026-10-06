import Darwin
import Foundation

public struct Listener: Equatable {
    public let port: UInt16
    public let addresses: [String]
    public let procs: [Proc]
    public let stack: String
    public let project: String?
    public let isSystem: Bool
    public let container: Container?
    /// Who started it: "Claude Code", a terminal or editor name, or nil for background launches.
    public var owner: String?
    /// The working directory no longer exists, typically a removed git worktree.
    public var orphan = false
    public var memory: UInt64?

    public var main: Proc { procs[0] }
    public var url: String { "http://localhost:\(port)" }
    /// Wildcard binds are reachable from the LAN, which is worth seeing at a glance.
    public var bind: String { addresses.contains { $0 == "0.0.0.0" || $0 == "::" } ? "*" : "local" }
    public var cwd: String? { container == nil ? main.cwd : nil }
}

public enum Inventory {
    public static func scan(containers: [UInt16: Container] = [:]) -> [Listener] { snapshot(containers: containers).listeners }

    public static func snapshot(containers: [UInt16: Container] = [:]) -> (listeners: [Listener], active: Set<UInt16>) {
        let (sockets, active) = Scanner.scan()
        var procs: [pid_t: Proc] = [:]
        for pid in Set(sockets.map(\.pid)) { procs[pid] = Scanner.proc(pid) }
        var listeners = build(sockets, procs: procs, containers: containers)
        let parents = Scanner.parents()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        for i in listeners.indices where listeners[i].container == nil {
            listeners[i].owner = owner(of: listeners[i].main.ppid)
            // Count the whole tree: Vite's esbuild and php -S workers live in child processes.
            var seen = Set<pid_t>(), queue = listeners[i].procs.map(\.pid)
            while let pid = queue.popLast() {
                if seen.insert(pid).inserted { queue += children[pid] ?? [] }
            }
            listeners[i].memory = seen.compactMap(Scanner.memory).reduce(0, +)
        }
        return (listeners, active)
    }

    static let owners: [(String, String)] = [
        ("codex", "Codex"), ("ghostty", "Ghostty"), ("iterm2", "iTerm"), ("terminal", "Terminal"), ("wezterm-gui", "WezTerm"),
        ("kitty", "kitty"), ("warp", "Warp"), ("alacritty", "Alacritty"), ("tmux", "tmux"), ("cursor", "Cursor"), ("zed", "Zed"),
    ]

    /// Walks up the parent chain to the first known launcher.
    static func owner(of start: pid_t) -> String? {
        var pid = start
        for _ in 0..<40 where pid > 1 {
            guard let p = Scanner.proc(pid) else { return nil }
            let first = (p.args.first?.split(separator: " ").first.map(String.init) ?? "") as NSString
            let names = [p.name.lowercased(), first.lastPathComponent.lowercased()]
            if names.contains("claude") || p.exe.contains("/claude/versions/") { return "Claude Code" }
            if p.exe.contains("Visual Studio Code") { return "VS Code" }
            if let hit = owners.first(where: { names.contains($0.0) }) { return hit.1 }
            pid = p.ppid
        }
        return nil
    }

    /// True when a Docker engine owns a listening port, so `docker ps` is worth the 100 ms.
    public static func needsDocker() -> Bool {
        Set(Scanner.sockets().map(\.pid)).contains { Scanner.proc($0).map(Detect.isDockerHost) ?? false }
    }

    public static func build(_ sockets: [Socket], procs: [pid_t: Proc], containers: [UInt16: Container], home: String = NSHomeDirectory()) -> [Listener] {
        Dictionary(grouping: sockets, by: \.port).compactMap { port, group -> Listener? in
            let pids = Set(group.map(\.pid))
            let members = pids.compactMap { procs[$0] }.sorted { $0.pid < $1.pid }
            // Prefer the process whose parent is not in the group: the php -S master over its workers.
            guard let main = members.first(where: { !pids.contains($0.ppid) }) ?? members.first else { return nil }
            let ordered = [main] + members.filter { $0.pid != main.pid }
            let addresses = Array(Set(group.map(\.address))).sorted()
            if let c = containers[port], Detect.isDockerHost(main) {
                return Listener(port: port, addresses: addresses, procs: ordered, stack: "Docker",
                                project: c.project.map { "\($0) · \(c.name)" } ?? c.name, isSystem: false, container: c)
            }
            let (stack, known) = Detect.stack(main)
            var l = Listener(port: port, addresses: addresses, procs: ordered, stack: stack,
                             project: Detect.project(cwd: main.cwd, home: home),
                             isSystem: Detect.isSystem(main, known: known, home: home), container: nil)
            l.orphan = main.cwd.map { $0 != "/" && !FileManager.default.fileExists(atPath: $0) } ?? false
            return l
        }.sorted { $0.port < $1.port }
    }
}

public enum Killer {
    /// Listening pids plus a `php artisan serve` parent, which would otherwise respawn the server.
    public static func targets(_ l: Listener) -> [pid_t] {
        var pids = l.procs.map(\.pid)
        if let parent = Scanner.proc(l.main.ppid), parent.args.contains(where: { $0.hasSuffix("artisan") }), parent.args.contains("serve") {
            pids.append(parent.pid)
        }
        return pids.filter { $0 > 1 && $0 != getpid() && (Scanner.proc($0)?.uid ?? 0) == getuid() }
    }

    /// SIGTERM, wait up to `grace`, then SIGKILL. Returns pids still alive afterwards.
    @discardableResult
    public static func stop(_ l: Listener, grace: TimeInterval = 3) -> [pid_t] {
        if let c = l.container { return Docker.stop(c) ? [] : [l.main.pid] }
        let pids = targets(l)
        pids.forEach { kill($0, SIGTERM) }
        if wait(pids, grace) { return [] }
        pids.filter(Scanner.isAlive).forEach { kill($0, SIGKILL) }
        _ = wait(pids, 1)
        return pids.filter(Scanner.isAlive)
    }

    private static func wait(_ pids: [pid_t], _ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !pids.contains(where: Scanner.isAlive) { return true }
            usleep(100_000)
        }
        return !pids.contains(where: Scanner.isAlive)
    }
}

public func megabytes(_ bytes: UInt64?) -> String {
    guard let bytes, bytes > 0 else { return "" }
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb.rounded())) MB"
}

public func uptime(since: Date?, now: Date = Date()) -> String {
    guard let since else { return "" }
    let s = max(0, Int(now.timeIntervalSince(since)))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}
