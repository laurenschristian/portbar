import Foundation

/// Remembers when each listener last saw traffic. The app writes it every scan; the CLI only reads it.
public final class Activity {
    public static let suite = "com.laurenschristian.portbar"
    static let services: Set<String> = [
        "Postgres", "Redis", "MySQL", "MongoDB", "PHP-FPM", "Meilisearch", "Mailpit", "MinIO", "Ollama", "Caddy", "Nginx",
    ]

    private let store: UserDefaults
    private var lastActive: [String: Date]
    private var cpu: [String: Double] = [:]

    public init(store: UserDefaults = UserDefaults(suiteName: Activity.suite) ?? .standard) {
        self.store = store
        lastActive = (store.dictionary(forKey: "lastActive") as? [String: Date]) ?? [:]
    }

    /// Auto-stop threshold in hours; 0 means off.
    public var thresholdHours: Double {
        get { store.object(forKey: "idleHours") as? Double ?? 8 }
        set { store.set(newValue, forKey: "idleHours") }
    }

    /// A restarted server gets a new key, so its idle clock starts over.
    static func key(_ l: Listener) -> String {
        "\(l.port)-\(l.main.pid)-\(Int(l.main.started?.timeIntervalSince1970 ?? 0))"
    }

    /// Always-on services: databases and every Docker container. Pinned in the menu, never auto-stopped.
    public static func isService(_ l: Listener) -> Bool { l.container != nil || services.contains(l.stack) }

    public static func stoppable(_ l: Listener) -> Bool { !l.isSystem && !isService(l) }

    /// An open connection or any CPU use since the last scan counts as activity. First sight starts the clock.
    public func update(_ listeners: [Listener], active: Set<UInt16>, cpu read: (pid_t) -> Double? = Scanner.cpu, now: Date = Date()) {
        var next: [String: Date] = [:]
        var nextCPU: [String: Double] = [:]
        for l in listeners {
            let k = Self.key(l)
            // The Docker engine's CPU is shared by every container, so only connections count there.
            let used = l.container == nil ? l.procs.compactMap { read($0.pid) }.reduce(0, +) : nil
            if let used { nextCPU[k] = used }
            let busy = active.contains(l.port) || (used != nil && cpu[k] != nil && used! - cpu[k]! > 0.05)
            next[k] = busy || lastActive[k] == nil ? now : lastActive[k]
        }
        lastActive = next
        cpu = nextCPU
        store.set(next, forKey: "lastActive")
    }

    public func idle(_ l: Listener, now: Date = Date()) -> TimeInterval? {
        lastActive[Self.key(l)].map { now.timeIntervalSince($0) }
    }

    public func expired(_ listeners: [Listener], now: Date = Date()) -> [Listener] {
        guard thresholdHours > 0 else { return [] }
        // Orphans go at once: their worktree is gone, so nobody can be using them.
        return listeners.filter { Self.stoppable($0) && ($0.orphan || (idle($0, now: now) ?? 0) >= thresholdHours * 3600) }
    }
}
