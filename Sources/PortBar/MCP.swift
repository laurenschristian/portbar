import Foundation

/// Minimal MCP server over stdio (newline-delimited JSON-RPC) so coding agents can find and reserve ports.
enum MCP {
    static let tools: [[String: Any]] = [
        tool("list_ports", "List listening dev servers and services on this Mac: port, stack, project, owner, memory, idle state.",
             ["all": ["type": "boolean", "description": "Include system ports"]]),
        tool("who", "Show what holds one port.", ["port": ["type": "integer"]], required: ["port"]),
        tool("claim_port", """
            Reserve a free port before starting a dev server (php artisan serve --port, vite --port, next dev -p). \
            Always use this instead of guessing a port; other agents run servers in parallel. The claim lasts 10 minutes \
            unless the server starts listening, then it lasts as long as the server.
            """,
             ["preferred": ["type": "integer", "description": "First port to try, e.g. 8000 for Laravel, 5173 for Vite"],
              "label": ["type": "string", "description": "Who claims it, e.g. the worktree or task name"],
              "cwd": ["type": "string", "description": "Project folder the server will run in"]],
             required: ["label"]),
        tool("stop_port", "Stop the dev server on a port. Refuses databases, Docker containers and system processes.",
             ["port": ["type": "integer"]], required: ["port"]),
        tool("restart_port", "Stop and rerun the dev server on a port with the same command, folder and environment.",
             ["port": ["type": "integer"]], required: ["port"]),
    ]

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            guard let id = msg["id"] else { continue }
            let params = msg["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "portbar", "version": version]])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                let (text, isError) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
            case "ping":
                reply(id, [:])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
            }
        }
        return 0
    }

    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let port = (args["port"] as? Int).flatMap { UInt16(exactly: $0) }
        let listeners = CLI.scan()
        let target = port.flatMap { p in listeners.first { $0.port == p } }
        switch name {
        case "list_ports":
            let all = args["all"] as? Bool ?? false
            return (CLI.encode(all ? listeners : listeners.filter { !$0.isSystem }), false)
        case "who":
            guard let port else { return ("port is required", true) }
            return (target.map { CLI.encode([$0]) } ?? ":\(port) is free", false)
        case "claim_port":
            let start = (args["preferred"] as? Int).flatMap { UInt16(exactly: $0) } ?? 8000
            let label = args["label"] as? String ?? "agent"
            guard let p = Ports.nextFree(from: start, claim: label, cwd: args["cwd"] as? String) else { return ("no free port", true) }
            return ("{\"port\": \(p)}", false)
        case "stop_port", "restart_port":
            guard let port else { return ("port is required", true) }
            guard let l = target else { return (":\(port) is free", false) }
            guard Activity.stoppable(l) else { return (":\(port) is \(l.stack), a pinned service or system process. Ask the user to stop it.", true) }
            if name == "restart_port" {
                return Launcher.restart(l).map { ("restart failed: \($0)", true) } ?? ("restarted :\(port)", false)
            }
            let left = Killer.stop(l)
            return left.isEmpty ? ("stopped :\(port) \(l.stack)", false) : ("still running: \(left)", true)
        default:
            return ("unknown tool \(name)", true)
        }
    }

    /// Bundle.main does not resolve the `portbar` symlink, so read the Info.plist next to the real binary.
    static var version: String {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let plist = exe?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return plist.flatMap { NSDictionary(contentsOf: $0)?["CFBundleShortVersionString"] as? String } ?? "dev"
    }

    static func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
