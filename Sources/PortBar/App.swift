import AppKit
import ServiceManagement

private let defaults = UserDefaults.standard

final class PortBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let work = DispatchQueue(label: "portbar.scan", qos: .userInitiated)
    private var listeners: [Listener] = []
    private var containers: [UInt16: Container] = [:]
    private var dockerAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var showSystem: Bool { get { defaults.bool(forKey: "showSystem") } set { defaults.set(newValue, forKey: "showSystem") } }

    func applicationDidFinishLaunching(_ note: Notification) {
        status.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "PortBar")
        status.button?.image?.isTemplate = true
        status.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        status.menu = menu
        // The count is the only thing that changes while the menu is closed; 30 s with leeway is enough.
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
            let found = Inventory.scan(containers: DispatchQueue.main.sync { containers })
            DispatchQueue.main.async { [self] in
                listeners = found
                let count = found.filter { !$0.isSystem }.count
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
        let dev = listeners.filter { !$0.isSystem }
        let system = listeners.filter(\.isSystem)
        if dev.isEmpty { menu.addItem(label("No dev servers listening")) }
        dev.forEach { menu.addItem(row($0)) }
        if showSystem && !system.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label("System"))
            system.forEach { menu.addItem(row($0)) }
        }
        menu.addItem(.separator())
        let killAll = item("Stop All Dev Servers…") { $0.stopAll() }
        killAll.isEnabled = !dev.isEmpty
        menu.addItem(killAll)
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
        let up = uptime(since: l.main.started) + (l.bind == "*" ? "  ·  LAN" : "")
        s.append(NSAttributedString(string: "\t\(up)", attributes: base.merging([
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        ]) { $1 }))
        i.attributedTitle = s
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
        let dev = listeners.filter { !$0.isSystem }
        let a = NSAlert()
        a.messageText = "Stop \(dev.count) dev servers?"
        a.informativeText = dev.map { ":\($0.port)  \($0.stack)  \($0.project ?? "")" }.joined(separator: "\n")
        a.addButton(withTitle: "Stop All")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { stop(dev) }
    }

    // MARK: Helpers

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
