import AppKit
import ServiceManagement
import UserNotifications

private let defaults = UserDefaults.standard

final class PortBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "portbar.scan", qos: .userInitiated)
    private var listeners: [Listener] = []
    private var containers: [UInt16: Container] = [:]
    private var dockerAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    private let activity = Activity()
    private var showSystem: Bool { get { defaults.bool(forKey: "showSystem") } set { defaults.set(newValue, forKey: "showSystem") } }

    func applicationDidFinishLaunching(_ note: Notification) {
        status.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "PortBar")
        status.button?.image?.isTemplate = true
        status.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        status.menu = menu
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        // Count and idle clocks only need coarse updates while the menu is closed.
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now(), repeating: 30, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.refresh(docker: false) }
        t.resume()
        timer = t
    }

    // MARK: Scanning

    private func refresh(docker force: Bool, then: (() -> Void)? = nil) {
        work.async { [self] in
            if force || Date().timeIntervalSince(dockerAt) > 120 {
                let next = Inventory.needsDocker() ? Docker.containers() : [:]
                DispatchQueue.main.sync { containers = next }
                dockerAt = Date()
            }
            var (found, active) = Inventory.snapshot(containers: DispatchQueue.main.sync { containers })
            activity.update(found, active: active)
            let expired = activity.expired(found)
            for l in expired where Killer.stop(l).isEmpty {
                notify("Stopped :\(l.port) \(l.stack)", "\(l.project ?? l.main.name) was idle for \(span(activity.idle(l) ?? 0)).")
            }
            if !expired.isEmpty { (found, active) = Inventory.snapshot(containers: DispatchQueue.main.sync { containers }) }
            DispatchQueue.main.async { [self] in
                listeners = found
                let count = found.filter(Activity.stoppable).count
                status.button?.title = count > 0 ? " \(count)" : ""
                then?()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Draw from the last scan at once, then redraw with fresh data (tracked menus update in place).
        build()
        refresh(docker: true) { [weak self] in self?.build() }
    }

    // MARK: Menu

    private func build() {
        menu.removeAllItems()
        let dev = listeners.filter(Activity.stoppable)
        let services = listeners.filter { !$0.isSystem && Activity.isService($0) }
        let system = listeners.filter(\.isSystem)
        if dev.isEmpty { menu.addItem(label("No dev servers listening")) }
        dev.forEach { menu.addItem(row($0)) }
        if !services.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("Services"))
            services.forEach { menu.addItem(row($0)) }
        }
        if showSystem && !system.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("System"))
            system.forEach { menu.addItem(row($0)) }
        }
        menu.addItem(.separator())
        let killAll = item("Stop All Dev Servers…") { $0.stopAll() }
        killAll.isEnabled = !dev.isEmpty
        menu.addItem(killAll)
        let idle = dev.filter { (activity.idle($0) ?? 0) >= 3600 }
        let stopIdle = item("Stop Idle Servers (\(idle.count))") { $0.stop(idle) }
        stopIdle.isEnabled = !idle.isEmpty
        stopIdle.toolTip = "Dev servers with no connections or CPU use for an hour or more"
        menu.addItem(stopIdle)
        let auto = NSMenu()
        for (title, hours) in [("Off", 0.0), ("After 8 Hours", 8), ("After 24 Hours", 24), ("After 3 Days", 72)] {
            auto.addItem(item(title, on: activity.thresholdHours == hours) { $0.activity.thresholdHours = hours; $0.build() })
        }
        let autoItem = NSMenuItem(title: "Auto-Stop Idle Servers", action: nil, keyEquivalent: "")
        autoItem.submenu = auto
        menu.addItem(autoItem)
        menu.addItem(item("Show System Ports (\(system.count))", on: showSystem) { app in
            app.showSystem.toggle()
            app.build()
        })
        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", on: SMAppService.mainApp.status == .enabled) { _ in
            let s = SMAppService.mainApp
            try? s.status == .enabled ? s.unregister() : s.register()
        })
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(label("PortBar \(version)"))
        menu.addItem(NSMenuItem(title: "Quit PortBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    private func row(_ l: Listener) -> NSMenuItem {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 58), NSTextTab(textAlignment: .left, location: 150),
                         NSTextTab(textAlignment: .right, location: 440)]
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .font: NSFont.menuFont(ofSize: 0)]
        let dim = l.isSystem ? NSColor.secondaryLabelColor : NSColor.labelColor
        let s = NSMutableAttributedString(string: ":\(l.port)", attributes: base.merging([
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: dim,
        ]) { $1 })
        s.append(NSAttributedString(string: "\t\(l.stack)", attributes: base.merging([.foregroundColor: dim]) { $1 }))
        let project = l.project.map { $0.count > 34 ? String($0.prefix(33)) + "…" : $0 } ?? (l.isSystem ? l.main.name : "")
        s.append(NSAttributedString(string: "\t\(project)", attributes: base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        let idle = Activity.stoppable(l) ? activity.idle(l) ?? 0 : 0
        let up = (idle >= 3600 ? "idle \(span(idle))" : uptime(since: l.main.started)) + (l.bind == "*" ? "  ·  LAN" : "")
        s.append(NSAttributedString(string: "\t\(up)", attributes: base.merging([
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        ]) { $1 }))
        i.attributedTitle = s
        i.image = Icons.image(for: l.stack)
        i.toolTip = l.main.command
        i.submenu = actions(l)
        return i
    }

    private func actions(_ l: Listener) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(item("Open \(l.url)") { _ in NSWorkspace.shared.open(URL(string: l.url)!) })
        m.addItem(item("Copy URL") { _ in toPasteboard(l.url) })
        if let cwd = l.cwd {
            m.addItem(item("Reveal Folder in Finder") { _ in NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) })
        }
        m.addItem(.separator())
        if let c = l.container {
            m.addItem(label("\(c.name)  ·  \(c.image)"))
        } else {
            m.addItem(label("PID \(l.procs.map { String($0.pid) }.joined(separator: ", "))  ·  \(l.main.name)"))
            if let cwd = l.cwd { m.addItem(label((cwd as NSString).abbreviatingWithTildeInPath)) }
        }
        if Activity.stoppable(l), let idle = activity.idle(l) {
            m.addItem(label(idle < 60 ? "Active now  ·  up \(uptime(since: l.main.started))" : "Idle \(span(idle))  ·  up \(uptime(since: l.main.started))"))
        } else if !l.isSystem {
            m.addItem(label("Never auto-stopped"))
        }
        m.addItem(label("Listening on \(l.addresses.joined(separator: ", "))"))
        let cmd = label(l.main.command.count > 70 ? String(l.main.command.prefix(69)) + "…" : l.main.command)
        cmd.toolTip = l.main.command
        m.addItem(cmd)
        m.addItem(item("Copy Command") { _ in toPasteboard(l.main.command) })
        m.addItem(.separator())
        let stop = item(l.container == nil ? "Kill Process" : "Stop Container") { $0.stop([l]) }
        stop.isEnabled = !l.isSystem
        if l.isSystem { stop.toolTip = "System processes are protected. Use `portbar kill \(l.port) --force`." }
        m.addItem(stop)
        return m
    }

    // MARK: Actions

    private func stop(_ targets: [Listener]) {
        work.async { [self] in
            let failed = targets.filter { !Killer.stop($0).isEmpty }
            DispatchQueue.main.async { [self] in
                if !failed.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Could not stop \(failed.map { ":\($0.port)" }.joined(separator: ", "))"
                    a.informativeText = "The process ignored SIGTERM and SIGKILL, or belongs to another user."
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
                refresh(docker: true)
            }
        }
    }

    private func stopAll() {
        let dev = listeners.filter(Activity.stoppable)
        let a = NSAlert()
        a.messageText = "Stop \(dev.count) dev servers?"
        a.informativeText = dev.map { ":\($0.port)  \($0.stack)  \($0.project ?? "")" }.joined(separator: "\n")
        a.addButton(withTitle: "Stop All")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { stop(dev) }
    }

    // MARK: Helpers

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func label(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private final class Action: NSObject {
        let run: (PortBar) -> Void
        init(_ run: @escaping (PortBar) -> Void) { self.run = run }
    }

    private func item(_ title: String, on: Bool = false, _ run: @escaping (PortBar) -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = Action(run)
        return i
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run(self)
    }
}

private func toPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

private func span(_ t: TimeInterval) -> String { uptime(since: Date().addingTimeInterval(-t)) }
