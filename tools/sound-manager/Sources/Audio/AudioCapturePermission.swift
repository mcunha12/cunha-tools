import AppKit
import Foundation

enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var rawPreflight: Int {
        guard let symbol = dlsym(framework, "TCCAccessPreflight") else { return -1 }
        return unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil)
    }

    static var status: Status {
        switch rawPreflight {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(framework, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
