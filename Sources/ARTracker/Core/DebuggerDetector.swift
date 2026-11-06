import Foundation
import Darwin

public enum DebuggerDetector {
    /// Returns true if a native debugger (e.g. LLDB via Xcode) is actively attached to the process.
    public static var isAttached: Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard status == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

