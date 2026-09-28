import CoreAudio
import Darwin
import Foundation

struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool

    static func all() -> [AudioProcess] {
        AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList).compactMap { objectID in
            let pid: pid_t = objectID.read(kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != getpid() else { return nil }
            let playing: UInt32 = objectID.read(kAudioProcessPropertyIsRunningOutput, default: 0)
            return AudioProcess(
                objectID: objectID,
                pid: pid,
                bundleID: objectID.readString(kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 },
                isPlaying: playing != 0
            )
        }
    }
}

enum ProcessLineage {
    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsible = responsiblePIDFunction?(pid), responsible > 0 else { return nil }
        return responsible
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }
}
