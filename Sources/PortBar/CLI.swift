import Darwin
import Foundation

enum CLI {
    static let usage = """
    usage: portbar [--all] [--json]       list listening ports (dev servers only unless --all)
           portbar <port>                 details for one port
           portbar kill <port>... [--force]
           portbar kill --all-dev [-y]    stop every dev server
           portbar help
    """

    static let tty = isatty(STDOUT_FILENO) == 1
    static func style(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    static func run(_ argv: [String]) -> Int32 {
        let flags = Set(argv.filter { $0.hasPrefix("-") })
        let words = argv.filter { !$0.hasPrefix("-") }
        if flags.contains("-h") || flags.contains("--help") || words.first == "help" { print(usage); return 0 }
        let listeners = scan()

        if words.first == "kill" {
            var targets: [Listener]
            if flags.contains("--all-dev") {
                targets = listeners.filter { !$0.isSystem }
                guard !targets.isEmpty else { print("no dev servers running"); return 0 }
                if !flags.contains("-y") {
                    targets.forEach { print(row($0)) }
                    print("stop these \(targets.count)? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { return 1 }
                }
            } else {
                let ports = words.dropFirst().compactMap { UInt16($0) }
                guard !ports.isEmpty else { fputs(usage + "\n", stderr); return 2 }
                targets = []
                for p in ports {
                    guard let l = listeners.first(where: { $0.port == p }) else { fputs("nothing listening on :\(p)\n", stderr); continue }
                    if l.isSystem && !flags.contains("--force") {
                        fputs(":\(p) is \(l.main.name) (system); use --force to stop it\n", stderr)
                        continue
                    }
                    targets.append(l)
                }
            }
            var failed = false
            for l in targets {
                let left = Killer.stop(l)
                if left.isEmpty {
                    print("stopped :\(l.port) \(l.stack)\(l.project.map { " (\($0))" } ?? "")")
                } else {
                    failed = true
                    fputs("could not stop :\(l.port); still running: \(left.map(String.init).joined(separator: ", "))\n", stderr)
                }
            }
            return failed || targets.isEmpty ? 1 : 0
        }

        if let word = words.first {
            guard let p = UInt16(word) else { fputs(usage + "\n", stderr); return 2 }
            guard let l = listeners.first(where: { $0.port == p }) else { fputs("nothing listening on :\(p)\n", stderr); return 1 }
            if flags.contains("--json") { return json([l]) }
            detail(l)
            return 0
        }

        let shown = flags.contains("--all") || flags.contains("-a") ? listeners : listeners.filter { !$0.isSystem }
        if flags.contains("--json") { return json(shown) }
        guard !shown.isEmpty else { print("no dev servers listening"); return 0 }
        print(style(pad("PORT", 6) + pad("STACK", 16) + pad("PROJECT", 44) + pad("PID", 8) + pad("UP", 6) + "BIND", "2"))
        shown.forEach { print(row($0)) }
        let hidden = listeners.count - shown.count
        if hidden > 0 { print(style("\(hidden) system ports hidden; --all shows them", "2")) }
        return 0
    }

    static func scan() -> [Listener] {
        Inventory.scan(containers: Inventory.needsDocker() ? Docker.containers() : [:])
    }

    static func row(_ l: Listener) -> String {
        let port = style(pad(String(l.port), 6), "1")
        let project = l.project.map { pad(String($0.prefix(42)), 44) } ?? pad("", 44)
        let line = port + pad(l.stack, 16) + project + pad(String(l.main.pid), 8) + pad(uptime(since: l.main.started), 6) + l.bind
        return l.isSystem ? style(line, "2") : line
    }

    static func detail(_ l: Listener) {
        let fields: [(String, String?)] = [
            ("port", "\(l.port)  \(l.url)"),
            ("stack", l.stack + (l.isSystem ? " (system)" : "")),
            ("project", l.project),
            ("container", l.container.map { "\($0.name) (\($0.image), \($0.id))" }),
            ("pid", l.procs.map { String($0.pid) }.joined(separator: ", ")),
            ("up", uptime(since: l.main.started)),
            ("bind", l.addresses.joined(separator: ", ")),
            ("cwd", l.cwd),
            ("command", l.main.command),
        ]
        for case let (k, v?) in fields where !v.isEmpty { print(style(pad(k, 11), "2") + v) }
    }

    static func json(_ list: [Listener]) -> Int32 {
        struct Out: Encodable {
            let port: UInt16, stack: String, project: String?, pids: [Int32], addresses: [String]
            let system: Bool, cwd: String?, command: String, started: Date?, container: Container?
        }
        let out = list.map { Out(port: $0.port, stack: $0.stack, project: $0.project, pids: $0.procs.map(\.pid), addresses: $0.addresses,
                                 system: $0.isSystem, cwd: $0.cwd, command: $0.main.command, started: $0.main.started, container: $0.container) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? enc.encode(out)) ?? Data(), as: UTF8.self))
        return 0
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
}
