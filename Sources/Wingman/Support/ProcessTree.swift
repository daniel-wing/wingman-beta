import Darwin
import Foundation

/// Facts about other processes from the BSD process table (public `sysctl` API).
enum ProcessTree {
    /// The parent's process ID, or nil if `pid` isn't running. Chrome captures the
    /// microphone in a helper process whose parent is the browser itself.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    #if !NO_DIAGNOSTICS && !APP_STORE
    /// A Chromium helper's role from its command line, e.g. "utility
    /// audio.mojom.AudioService", for the diagnostic tools. Only the values of
    /// `--type=` and `--utility-sub-type=` are returned, never paths or profiles.
    static func chromiumRole(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let values = arguments(in: Array(buffer.prefix(size))).compactMap { argument -> String? in
            for flag in ["--type=", "--utility-sub-type="] where argument.hasPrefix(flag) {
                return String(argument.dropFirst(flag.count))
            }
            return nil
        }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    /// The argument strings in a `KERN_PROCARGS2` buffer: argc (Int32), the
    /// executable path, NUL padding, then argc NUL-terminated arguments.
    static func arguments(in bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var result: [String] = []
        while result.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            result.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return result
    }
    #endif
}
