import Darwin
import Foundation
import Security

/// Native reads shared by helper capture and GUI revalidation. These facts stay off wire.
public struct HostProcessReadEnvironment {
    public var ordinaryProcess: (Int32) -> HostProcessSnapshot?
    public var kernelProcess: (Int32) -> HostProcessSnapshot?
    public var executablePath: (Int32) -> String?
    public var verifySystemLoginSignature: (Int32) -> Bool

    public init(
        ordinaryProcess: @escaping (Int32) -> HostProcessSnapshot?,
        kernelProcess: @escaping (Int32) -> HostProcessSnapshot?,
        executablePath: @escaping (Int32) -> String?,
        verifySystemLoginSignature: @escaping (Int32) -> Bool
    ) {
        self.ordinaryProcess = ordinaryProcess
        self.kernelProcess = kernelProcess
        self.executablePath = executablePath
        self.verifySystemLoginSignature = verifySystemLoginSignature
    }

    public static var live: Self {
        Self(
            ordinaryProcess: readBSDProcess, kernelProcess: readKernelProcess,
            executablePath: readExecutablePath, verifySystemLoginSignature: verifyLoginSignature)
    }

    private static func readBSDProcess(_ pid: Int32) -> HostProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_pid == UInt32(pid), info.pbi_ppid <= Int32.max
        else { return nil }
        return HostProcessSnapshot(
            identity: HostProcessIdentity(
                pid: pid, startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec),
            parentPID: Int32(info.pbi_ppid), userID: info.pbi_uid, realUserID: info.pbi_ruid)
    }

    private static func readKernelProcess(_ pid: Int32) -> HostProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
            size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return nil }
        return HostProcessSnapshot(
            identity: HostProcessIdentity(
                pid: pid, startSeconds: UInt64(start.tv_sec),
                startMicroseconds: UInt64(start.tv_usec)),
            parentPID: info.kp_eproc.e_ppid,
            userID: info.kp_eproc.e_ucred.cr_uid, realUserID: info.kp_eproc.e_pcred.p_ruid)
    }

    private static func readExecutablePath(_ pid: Int32) -> String? {
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN; Swift cannot import it.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
            let end = buffer.firstIndex(of: 0), end > 0
        else { return nil }
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func verifyLoginSignature(_ pid: Int32) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(
                "anchor apple and identifier \"com.apple.login\"" as CFString,
                SecCSFlags(), &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}
