import Darwin
import Foundation

public struct Socket: Equatable {
    public let pid: pid_t
    public let port: UInt16
    public let address: String

    public init(pid: pid_t, port: UInt16, address: String) {
        self.pid = pid
        self.port = port
        self.address = address
    }
}

public struct Proc: Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let exe: String
    public let args: [String]
    public let cwd: String?
    public let started: Date?

    public init(pid: pid_t, ppid: pid_t = 1, uid: uid_t = getuid(), exe: String, args: [String], cwd: String? = nil, started: Date? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.exe = exe
        self.args = args
        self.cwd = cwd
        self.started = started
    }

    public var name: String { (exe as NSString).lastPathComponent }
    public var command: String { args.isEmpty ? exe : args.joined(separator: " ") }
}

/// Reads sockets and process details straight from libproc. Only processes of the current user are visible.
public enum Scanner {
    public static func sockets() -> [Socket] { scan().listening }

    /// Listening sockets, plus local ports that currently hold an established connection.
    public static func scan() -> (listening: [Socket], active: Set<UInt16>) {
        var result: [Socket] = []
        var active: Set<UInt16> = []
        for pid in allPids() {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                      info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                switch info.psi.soi_proto.pri_tcp.tcpsi_state {
                case TSI_S_LISTEN: result.append(Socket(pid: pid, port: port, address: address(ini)))
                case TSI_S_ESTABLISHED: active.insert(port)
                default: break
                }
            }
        }
        return (result, active)
    }

    /// Total user + system CPU time in seconds.
    public static func cpu(_ pid: pid_t) -> Double? {
        var task = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return nil }
        return Double(task.pti_total_user + task.pti_total_system) * timebase / 1e9
    }

    // pti_total_* are mach absolute time units, not nanoseconds, on Apple Silicon.
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public static func proc(_ pid: pid_t) -> Proc? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let exe = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        var vnode = proc_vnodepathinfo()
        var cwd: String?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6)
        return Proc(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, exe: exe, args: args(pid),
                    cwd: cwd?.isEmpty == false ? cwd : nil, started: started)
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return bsd.pbi_status != UInt32(SZOMB)
    }

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    // KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated strings.
    private static func args(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        } else {
            var a = ini.insi_laddr.ina_6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }
}
