import Darwin
import Foundation

enum CLI {
    static let usage = """
    usage: portbar [--all] [--sort mem] [--json]   list listening ports (dev servers and services)
           portbar <port>                          details for one port
           portbar who <port>                      one line: what holds the port
           portbar free <port>                     stop whatever holds it; succeeds if already free
           portbar restart <port>                  stop and rerun the same command in the same folder
           portbar kill <port>... [--force]
           portbar kill --all-dev [-y]             stop every dev server
           portbar kill --idle [-y]                stop orphans and servers idle past the threshold
           portbar next-free [start] [--claim <label>]   print a free port, optionally reserving it
           portbar mcp                             run the MCP server for coding agents
           portbar help
    """

    static let tty = isatty(STDOUT_FILENO) == 1
    static func style(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    static func run(_ argv: [String]) -> Int32 {
        let flags = Set(argv.filter { $0.hasPrefix("-") })
        let words = argv.enumerated().filter { i, a in !a.hasPrefix("-") && !(i > 0 && ["--sort", "--claim"].contains(argv[i - 1])) }.map(\.1)
        if flags.contains("-h") || flags.contains("--help") || words.first == "help" { print(usage); return 0 }
        if words.first == "mcp" { return MCP.run() }
        if words.first == "next-free" {
            let start = words.dropFirst().first.flatMap { UInt16($0) } ?? 8000
            let label = argv.firstIndex(of: "--claim").flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
            guard let p = Ports.nextFree(from: start, claim: label, cwd: FileManager.default.currentDirectoryPath) else { return 1 }
            print(p)
            return 0
        }
        let listeners = scan()
        let activity = Activity()
        func find(_ word: String?) -> (UInt16, Listener?)? {
            guard let word, let p = UInt16(word.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) else { return nil }
            return (p, listeners.first { $0.port == p })
        }

        switch words.first {
        case "who":
            guard let (p, l) = find(words.dropFirst().first) else { fputs(usage + "\n", stderr); return 2 }
            guard let l else { print(":\(p) is free"); return 1 }
            let parts = [l.stack, l.project, l.owner.map { "started by \($0)" }, "pid \(l.main.pid)", "up \(uptime(since: l.main.started))", megabytes(l.memory)]
            print(":\(p)  " + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
            return 0

        case "free":
            guard let (p, l) = find(words.dropFirst().first) else { fputs(usage + "\n", stderr); return 2 }
            guard let l else { print(":\(p) is already free"); return 0 }
            return stop([l], force: flags.contains("--force"))

        case "restart":
            guard let (p, l) = find(words.dropFirst().first) else { fputs(usage + "\n", stderr); return 2 }
            guard let l else { fputs("nothing listening on :\(p)\n", stderr); return 1 }
            if l.isSystem && !flags.contains("--force") { fputs(":\(p) is \(l.main.name) (system); use --force\n", stderr); return 1 }
            if let error = Launcher.restart(l) { fputs("restart :\(p) failed: \(error)\n", stderr); return 1 }
            print("restarted :\(p) \(l.stack)\(l.project.map { " (\($0))" } ?? ""); log: \(Launcher.logs)/\(p).log")
            return 0

        case "kill":
            if flags.contains("--all-dev") || flags.contains("--idle") {
                let hours = activity.thresholdHours > 0 ? activity.thresholdHours : 8
                let targets = flags.contains("--idle")
                    ? listeners.filter { Activity.stoppable($0) && ($0.orphan || (activity.idle($0) ?? 0) >= hours * 3600) }
                    : listeners.filter(Activity.stoppable)
                guard !targets.isEmpty else { print(flags.contains("--idle") ? "nothing idle for \(Int(hours))h" : "no dev servers running"); return 0 }
                if !flags.contains("-y") {
                    targets.forEach { print(row($0, activity)) }
                    print("stop these \(targets.count)? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { return 1 }
                }
                return stop(targets, force: false)
            }
            let found = words.dropFirst().compactMap { find($0) }
            guard !found.isEmpty else { fputs(usage + "\n", stderr); return 2 }
            for (p, l) in found where l == nil { fputs("nothing listening on :\(p)\n", stderr) }
            let targets = found.compactMap(\.1)
            return targets.isEmpty ? 1 : stop(targets, force: flags.contains("--force"))

        case let word?:
            guard let (p, l) = find(word) else { fputs(usage + "\n", stderr); return 2 }
            guard let l else { fputs("nothing listening on :\(p)\n", stderr); return 1 }
            if flags.contains("--json") { print(encode([l])); return 0 }
            detail(l, activity)
            return 0

        case nil:
            var shown = flags.contains("--all") || flags.contains("-a") ? listeners : listeners.filter { !$0.isSystem }
            if let i = argv.firstIndex(of: "--sort"), argv.indices.contains(i + 1), argv[i + 1] == "mem" {
                shown.sort { ($0.memory ?? 0) > ($1.memory ?? 0) }
            }
            if flags.contains("--json") { print(encode(shown)); return 0 }
            guard !shown.isEmpty else { print("no dev servers listening"); return 0 }
            print(style(pad("PORT", 6) + pad("STACK", 14) + pad("PROJECT", 40) + pad("OWNER", 12) + pad("PID", 7) + pad("UP", 5)
                        + pad("IDLE", 6) + pad("MEM", 9) + "BIND", "2"))
            shown.forEach { print(row($0, activity)) }
            let hidden = listeners.count - shown.count
            if hidden > 0 { print(style("\(hidden) system ports hidden; --all shows them", "2")) }
            return 0
        }
    }

    static func stop(_ targets: [Listener], force: Bool) -> Int32 {
        var failed = false
        for l in targets {
            if l.isSystem && !force {
                fputs(":\(l.port) is \(l.main.name) (system); use --force to stop it\n", stderr)
                failed = true
                continue
            }
            let left = Killer.stop(l)
            if left.isEmpty {
                print("stopped :\(l.port) \(l.stack)\(l.project.map { " (\($0))" } ?? "")")
            } else {
                failed = true
                fputs("could not stop :\(l.port); still running: \(left.map(String.init).joined(separator: ", "))\n", stderr)
            }
        }
        return failed ? 1 : 0
    }

    static func scan() -> [Listener] {
        let docker = Inventory.needsDocker()
        return Inventory.snapshot(containers: docker ? Docker.containers() : [:]).listeners
    }

    static func row(_ l: Listener, _ activity: Activity) -> String {
        let port = style(pad(String(l.port), 6), "1")
        var project = l.project.map { String($0.prefix(37)) } ?? ""
        if l.orphan { project = String(project.prefix(28)) + " (deleted)" }
        let line = port + pad(String(l.stack.prefix(13)), 14) + pad(project, 40) + pad(l.owner ?? "", 12) + pad(String(l.main.pid), 7)
            + pad(uptime(since: l.main.started), 5) + pad(idle(l, activity), 6) + pad(megabytes(l.memory), 9) + l.bind
        return l.isSystem ? style(line, "2") : l.orphan ? style(line, "33") : line
    }

    static func idle(_ l: Listener, _ activity: Activity) -> String {
        guard Activity.stoppable(l) else { return l.isSystem ? "" : "keep" }
        guard let t = activity.idle(l) else { return "?" }
        return t < 60 ? "now" : uptime(since: Date().addingTimeInterval(-t))
    }

    static func detail(_ l: Listener, _ activity: Activity) {
        let fields: [(String, String?)] = [
            ("port", "\(l.port)  \(l.url)"),
            ("stack", l.stack + (l.isSystem ? " (system)" : Activity.isService(l) ? " (service)" : "")),
            ("project", l.project.map { $0 + (l.orphan ? "  (folder deleted)" : "") }),
            ("owner", l.owner),
            ("claimed by", l.claim),
            ("container", l.container.map { "\($0.name) (\($0.image), \($0.id))" }),
            ("pid", l.procs.map { String($0.pid) }.joined(separator: ", ")),
            ("up", uptime(since: l.main.started)),
            ("idle", idle(l, activity)),
            ("memory", megabytes(l.memory) + (l.cpu.map { String(format: "  ·  %.1f%% CPU", $0) } ?? "")),
            ("bind", l.addresses.joined(separator: ", ")),
            ("cwd", l.cwd),
            ("log", Launcher.laravelLog(cwd: l.cwd)),
            ("command", l.main.command),
        ]
        for case let (k, v?) in fields where !v.isEmpty { print(style(pad(k, 11), "2") + v) }
    }

    static func encode(_ list: [Listener]) -> String {
        struct Out: Encodable {
            let port: UInt16, stack: String, project: String?, owner: String?, claim: String?, pids: [Int32], addresses: [String]
            let system: Bool, service: Bool, orphan: Bool, memory: UInt64?, cpu: Double?, idleSeconds: Int?
            let cwd: String?, command: String, started: Date?, container: Container?
        }
        let activity = Activity()
        let out = list.map { Out(port: $0.port, stack: $0.stack, project: $0.project, owner: $0.owner, claim: $0.claim, pids: $0.procs.map(\.pid),
                                 addresses: $0.addresses, system: $0.isSystem, service: Activity.isService($0), orphan: $0.orphan,
                                 memory: $0.memory, cpu: $0.cpu, idleSeconds: activity.idle($0).map { Int($0) },
                                 cwd: $0.cwd, command: $0.main.command, started: $0.main.started, container: $0.container) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: (try? enc.encode(out)) ?? Data(), as: UTF8.self)
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
}
