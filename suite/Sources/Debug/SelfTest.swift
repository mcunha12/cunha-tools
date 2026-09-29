import AppKit
import CunhaKit

// Checks run inside the binary: --selftest-install, --selftest-update, --selftest-phone, --selftest-bonjour, --selftest-platform-tools <dir>. Exit code 1 on failure.
enum SelfTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest-install") { run(InstallSelfTest.run) }
        if arguments.contains("--selftest-update") { run(UpdateSelfTest.run) }
        if arguments.contains("--selftest-phone") { run(PhoneSelfTest.run) }
        if arguments.contains("--selftest-bonjour") { run(PhoneSelfTest.bonjour) }
        if let index = arguments.firstIndex(of: "--selftest-platform-tools"), arguments.count > index + 1 {
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            run { await PhoneSelfTest.platformTools(into: folder, checker: $0) }
        }
        return false
    }

    private static func run(_ body: @escaping @MainActor (Checker) async -> Void) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let checker = Checker()
            await body(checker)
            log("\(checker.passed) ok, \(checker.failed) falhas")
            exit(checker.failed == 0 ? 0 : 1)
        }
        application.run()
        exit(1)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("selftest: \(message)\n".utf8))
    }
}

@MainActor
final class Checker {
    private(set) var passed = 0
    private(set) var failed = 0

    func check(_ condition: Bool, _ label: String) {
        if condition { passed += 1 } else { failed += 1 }
        SelfTest.log("\(condition ? "ok   " : "FALHA") \(label)")
    }

    func fail(_ label: String) { check(false, label) }
}
