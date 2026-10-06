import Darwin
import XCTest
@testable import PortCore

private func proc(_ exe: String, _ args: [String], pid: pid_t = 100, ppid: pid_t = 1, cwd: String? = nil) -> Proc {
    Proc(pid: pid, ppid: ppid, exe: exe, args: args, cwd: cwd)
}

final class DetectTests: XCTestCase {
    func testStacks() {
        let cases: [(Proc, String, Bool)] = [
            (proc("/opt/homebrew/Cellar/php@8.4/8.4.25/bin/php", ["/opt/homebrew/Cellar/php@8.4/8.4.25/bin/php", "-S", "127.0.0.1:8070",
              "/x/vendor/laravel/framework/src/Illuminate/Foundation/Console/../resources/server.php"]), "Laravel", true),
            (proc("/opt/homebrew/bin/php", ["php", "artisan", "reverb:start", "--port=8160"]), "Reverb", true),
            (proc("/usr/local/bin/node", ["node", "/r/node_modules/.bin/../vite/bin/vite.js", "--", "--port=5243"]), "Vite", true),
            (proc("/usr/local/bin/node", ["next-server (v16.2.12)"]), "Next.js", true),
            (proc("/h/.hermes/node/bin/node", ["/h/.hermes/node/bin/node", "/r/node_modules/astro/bin/astro.mjs", "dev"]), "Astro", true),
            (proc("/usr/local/bin/node", ["node", "./node_modules/.bin/../playwright/cli.js", "run-server"]), "Playwright", true),
            (proc("/Applications/Postgres.app/Contents/Versions/18/bin/postgres", ["postgres", "-D", "/x"]), "Postgres", true),
            (proc("/opt/homebrew/opt/redis/bin/redis-server", ["redis-server 127.0.0.1:6379"]), "Redis", true),
            (proc("/usr/bin/python3", ["python3", "manage.py", "runserver"]), "Django", true),
            (proc("/opt/homebrew/bin/bun", ["bun", "--watch", "server.ts"]), "Bun", false),
            (proc("/tmp/web-backend-8097", ["/tmp/web-backend-8097"]), "web-backend-8…", false),
            (proc("", ["php-fpm: master process (/opt/homebrew/etc/php/8.5/php-fpm.conf)"]), "PHP-FPM", true),
        ]
        for (p, label, known) in cases {
            let s = Detect.stack(p)
            XCTAssertEqual(s.label, label, p.command)
            XCTAssertEqual(s.known, known, p.command)
        }
    }

    func testSystemFilter() {
        let home = "/Users/me"
        XCTAssertTrue(Detect.isSystem(proc("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", []), known: false, home: home))
        XCTAssertTrue(Detect.isSystem(proc("/Users/me/Library/Application Support/x/java", []), known: false, home: home))
        XCTAssertTrue(Detect.isSystem(proc("/usr/libexec/rapportd", []), known: false, home: home))
        XCTAssertFalse(Detect.isSystem(proc("/Applications/Postgres.app/Contents/Versions/18/bin/postgres", []), known: true, home: home))
        XCTAssertFalse(Detect.isSystem(proc("/opt/homebrew/bin/bun", []), known: false, home: home))
    }

    func testProjectNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portbar-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        func dir(_ p: String) throws { try fm.createDirectory(atPath: root + p, withIntermediateDirectories: true) }
        try dir("/platform/dev/.git")
        try dir("/platform/dev/.claude/worktrees/fix-x/public")
        try "gitdir: \(root)/platform/dev/.git/worktrees/fix-x\n".write(toFile: root + "/platform/dev/.claude/worktrees/fix-x/.git", atomically: true, encoding: .utf8)
        try dir("/apps/site/.git")
        try dir("/apps/site/src")
        try dir("/loose/thing")
        try dir("/loose/site/public")

        XCTAssertEqual(Detect.project(cwd: root + "/platform/dev", home: root), "platform · dev")
        XCTAssertEqual(Detect.project(cwd: root + "/platform/dev/.claude/worktrees/fix-x/public", home: root), "platform · fix-x")
        XCTAssertEqual(Detect.project(cwd: root + "/apps/site/src", home: root), "site")
        XCTAssertEqual(Detect.project(cwd: root + "/loose/thing", home: root), "thing")
        XCTAssertEqual(Detect.project(cwd: root + "/loose/site/public", home: root), "site")
        XCTAssertNil(Detect.project(cwd: root + "/Library/Application Support/Postgres/var-18", home: root))
        XCTAssertEqual(Detect.project(cwd: root, home: root), "~")
        XCTAssertNil(Detect.project(cwd: "/", home: root))
    }
}

final class DockerTests: XCTestCase {
    func testParse() {
        let out = "abc\tapi-db-1\tpostgres:16\t0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp\tapi\n"
            + "def\tweb\tnginx\t0.0.0.0:8000-8002->80-82/tcp, 0.0.0.0:53->53/udp\t\n"
            + "ghi\tworker\talpine\t\t\n"
        let map = Docker.parse(out)
        XCTAssertEqual(map[5433]?.name, "api-db-1")
        XCTAssertEqual(map[5433]?.project, "api")
        XCTAssertEqual(map[8001]?.id, "def")
        XCTAssertNil(map[8001]?.project)
        XCTAssertNil(map[53])
        XCTAssertEqual(map.count, 4)
    }
}

final class InventoryTests: XCTestCase {
    func testGroupsWorkersUnderMaster() {
        let master = proc("/opt/homebrew/bin/php", ["php", "-S", "127.0.0.1:8124", "/v/Illuminate/Foundation/resources/server.php"], pid: 10, ppid: 5)
        let worker = proc("/opt/homebrew/bin/php", master.args, pid: 11, ppid: 10)
        let sockets = [Socket(pid: 11, port: 8124, address: "127.0.0.1"), Socket(pid: 10, port: 8124, address: "127.0.0.1")]
        let l = Inventory.build(sockets, procs: [10: master, 11: worker], containers: [:])
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(l[0].main.pid, 10)
        XCTAssertEqual(l[0].stack, "Laravel")
        XCTAssertEqual(l[0].bind, "local")
    }

    func testDockerPortsUseContainer() {
        let backend = proc("/Applications/Docker.app/Contents/MacOS/com.docker.backend", ["com.docker.backend", "services"], pid: 20)
        let c = Container(id: "abc", name: "db", image: "postgres", project: "api")
        let sockets = [Socket(pid: 20, port: 5433, address: "::"), Socket(pid: 20, port: 7777, address: "127.0.0.1")]
        let l = Inventory.build(sockets, procs: [20: backend], containers: [5433: c])
        XCTAssertEqual(l[0].stack, "Docker")
        XCTAssertEqual(l[0].project, "api · db")
        XCTAssertFalse(l[0].isSystem)
        XCTAssertEqual(l[0].bind, "*")
        XCTAssertTrue(l[1].isSystem)
    }

    func testScanFindsOwnSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        withUnsafeMutablePointer(to: &addr) { _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        let hit = Inventory.scan().first { $0.port == port }
        XCTAssertEqual(hit?.main.pid, getpid())
        XCTAssertEqual(hit?.addresses, ["127.0.0.1"])
    }

    func testUptime() {
        let now = Date()
        XCTAssertEqual(uptime(since: now.addingTimeInterval(-42), now: now), "42s")
        XCTAssertEqual(uptime(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(uptime(since: now.addingTimeInterval(-200_000), now: now), "2d")
    }
}
