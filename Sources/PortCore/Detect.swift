import Foundation

public enum Detect {
    /// First match wins, so frameworks sit above the runtimes that host them.
    static let words: [(String, Set<String>)] = [
        ("Laravel", ["illuminate/foundation"]),
        ("Vite", ["vite"]),
        ("Next.js", ["next", "next-server", "next-router-worker"]),
        ("Astro", ["astro"]),
        ("Nuxt", ["nuxt", "nuxi"]),
        ("Remix", ["remix", "remix-serve"]),
        ("SvelteKit", ["svelte-kit"]),
        ("Mintlify", ["mint", "mintlify"]),
        ("Docusaurus", ["docusaurus"]),
        ("VitePress", ["vitepress"]),
        ("Storybook", ["storybook", "start-storybook"]),
        ("Webpack", ["webpack", "webpack-dev-server"]),
        ("Gatsby", ["gatsby"]),
        ("Expo", ["expo"]),
        ("Wrangler", ["wrangler", "workerd"]),
        ("Playwright", ["playwright"]),
        ("Uvicorn", ["uvicorn"]),
        ("Gunicorn", ["gunicorn"]),
        ("Flask", ["flask"]),
        ("Jupyter", ["jupyter", "jupyter-lab", "jupyter-notebook"]),
        ("Rails", ["rails", "puma"]),
        ("Hugo", ["hugo"]),
        ("Jekyll", ["jekyll"]),
        ("MkDocs", ["mkdocs"]),
        ("Postgres", ["postgres", "postmaster"]),
        ("Redis", ["redis-server"]),
        ("MySQL", ["mysqld", "mariadbd"]),
        ("MongoDB", ["mongod"]),
        ("Meilisearch", ["meilisearch"]),
        ("Mailpit", ["mailpit"]),
        ("MinIO", ["minio"]),
        ("Ollama", ["ollama"]),
        ("Caddy", ["caddy"]),
        ("Nginx", ["nginx"]),
        ("PHP-FPM", ["php-fpm"]),
    ]

    static let artisan: [(String, String)] = [
        ("serve", "Laravel"), ("reverb", "Reverb"), ("horizon", "Horizon"), ("octane", "Octane"),
    ]

    static let runtimes: [(String, String)] = [
        ("node", "Node"), ("bun", "Bun"), ("deno", "Deno"), ("php", "PHP"), ("python", "Python"),
        ("ruby", "Ruby"), ("java", "Java"), ("dotnet", "dotnet"), ("beam.smp", "Elixir"),
    ]

    static let dockerHosts: Set<String> = [
        "com.docker.backend", "vpnkit-bridge", "docker-proxy", "OrbStack Helper", "limactl", "rancher-desktop",
    ]

    /// Returns the stack label and whether it came from a known framework or service (not a bare runtime).
    public static func stack(_ p: Proc) -> (label: String, known: Bool) {
        let args = p.args.map { $0.lowercased() }
        if let i = args.firstIndex(where: { $0.hasSuffix("artisan") }), i + 1 < args.count {
            let cmd = args[i + 1]
            if let hit = artisan.first(where: { cmd.hasPrefix($0.0) }) { return (hit.1, true) }
            return ("Laravel", true)
        }
        let joined = args.joined(separator: " ")
        if joined.contains("manage.py") && joined.contains("runserver") { return ("Django", true) }
        if joined.contains("http.server") { return ("Python http.server", true) }
        let tokens = Set(tokens(args) + [p.name.lowercased()])
        for (label, keys) in words where !keys.isDisjoint(with: tokens) || keys.contains(where: { $0.contains("/") && joined.contains($0) }) {
            return (label, true)
        }
        let first = p.args.first?.split(separator: " ").first.map(String.init) ?? ""
        let exe = ((first as NSString).lastPathComponent).trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        for name in [p.name.lowercased(), exe] {
            if let hit = runtimes.first(where: { name == $0.0 || name.hasPrefix($0.0 + "3") || name.hasPrefix($0.0 + "@") || name.hasPrefix($0.0 + "8") }) {
                return (hit.1, false)
            }
        }
        let name = p.name.isEmpty ? exe : p.name
        return (name.count > 14 ? String(name.prefix(13)) + "…" : name, false)
    }

    public static func isDockerHost(_ p: Proc) -> Bool { dockerHosts.contains(p.name) }

    /// App bundles and system paths are noise unless they run a known service (Postgres.app, for example).
    public static func isSystem(_ p: Proc, known: Bool, home: String = NSHomeDirectory()) -> Bool {
        if known { return false }
        let path = p.exe.isEmpty ? (p.args.first ?? "") : p.exe
        if path.contains(".app/Contents/") || path.contains(".appex/") { return true }
        let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/", home + "/Library/"]
        return prefixes.contains { path.hasPrefix($0) } || path.isEmpty
    }

    /// "repo" for a checkout, "repo · worktree" for git worktrees and repo/main style layouts.
    public static func project(cwd: String?, home: String = NSHomeDirectory(), fm: FileManager = .default) -> String? {
        guard let cwd, cwd != "/" else { return nil }
        // Service data dirs (Postgres.app, Homebrew var) say nothing about which project it is.
        if [home + "/Library/", "/opt/homebrew/", "/usr/local/var/", "/private/"].contains(where: { cwd.hasPrefix($0) }) { return nil }
        var dir = cwd
        while dir != "/" && dir != home && !dir.isEmpty {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if !isDir.boolValue, let main = worktreeMain(git) {
                    let leaf = (dir as NSString).lastPathComponent
                    let repo = repoName(main)
                    return repo == leaf ? repo : "\(repo) · \(leaf)"
                }
                return label(dir)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if cwd == home { return "~" }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf == "public" ? ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent : leaf
    }

    static let generic: Set<String> = ["main", "master", "dev", "develop", "development", "staging", "production", "prod", "trunk"]

    private static func label(_ dir: String) -> String {
        let base = (dir as NSString).lastPathComponent
        guard generic.contains(base.lowercased()) else { return base }
        return "\(((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent) · \(base)"
    }

    private static func repoName(_ dir: String) -> String {
        let base = (dir as NSString).lastPathComponent
        return generic.contains(base.lowercased()) ? ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent : base
    }

    // A worktree's .git file reads "gitdir: <main>/.git/worktrees/<name>".
    private static func worktreeMain(_ gitFile: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let r = path.range(of: "/.git/worktrees/") else { return nil }
        return String(path[..<r.lowerBound])
    }

    private static func tokens(_ args: [String]) -> [String] {
        args.flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "=" }) }.map { t in
            var s = String(t).trimmingCharacters(in: CharacterSet(charactersIn: ":()"))
            for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where s.hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
            return s
        }
    }
}
