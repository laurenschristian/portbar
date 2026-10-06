import Darwin
import Foundation

public enum Launcher {
    public static let logs = NSHomeDirectory() + "/Library/Logs/PortBar"

    /// The command to rerun: the `php artisan serve` parent when there is one, otherwise the listener itself.
    public static func command(_ l: Listener) -> Proc {
        if let parent = Scanner.proc(l.main.ppid), parent.args.contains(where: { $0.hasSuffix("artisan") }), parent.args.contains("serve") {
            return parent
        }
        return l.main
    }

    /// Stops the server and starts the same command in the same folder and environment. Returns an error message.
    public static func restart(_ l: Listener, timeout: TimeInterval = 20) -> String? {
        if let c = l.container { return Docker.restart(c) ? nil : "docker restart failed" }
        let p = command(l)
        guard let cwd = p.cwd, FileManager.default.fileExists(atPath: cwd) else { return "its folder no longer exists" }
        guard let first = p.args.first, !first.contains(" ") else { return "it rewrote its command line, so it cannot be rerun" }
        let exe = first.contains("/") ? (first.hasPrefix("/") ? first : cwd + "/" + first) : p.exe
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "\(exe) is not executable" }
        let left = Killer.stop(l)
        guard left.isEmpty else { return "could not stop pid \(left.map(String.init).joined(separator: ", "))" }
        let log = logs + "/\(l.port).log"
        guard spawn(exe, p.args, cwd: cwd, env: p.env.isEmpty ? environ() : p.env, log: log) else { return "could not start \(exe)" }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Scanner.sockets().contains(where: { $0.port == l.port }) { return nil }
            usleep(250_000)
        }
        return "started, but nothing listens on :\(l.port) yet; see \(log)"
    }

    /// Detached in its own session so it outlives PortBar and the terminal, with output appended to `log`.
    static func spawn(_ exe: String, _ args: [String], cwd: String, env: [String], log: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, exe, &actions, &attr, argv, envp) == 0
    }

    private static func environ() -> [String] { ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } }

    /// Newest Laravel log for the project the server runs in.
    public static func laravelLog(cwd: String?) -> String? {
        var dir = cwd ?? "/"
        let fm = FileManager.default
        while dir != "/" && !dir.isEmpty {
            if fm.fileExists(atPath: dir + "/artisan") {
                let logs = dir + "/storage/logs"
                let files = (try? fm.contentsOfDirectory(atPath: logs))?.filter { $0.hasSuffix(".log") } ?? []
                return files.map { logs + "/" + $0 }.max {
                    let a = (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
                    let b = (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
                    return a < b
                }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
