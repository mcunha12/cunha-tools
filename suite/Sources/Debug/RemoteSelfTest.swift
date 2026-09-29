import AppKit
import CunhaKit

// --selftest-remote: drives the running Sound Manager through SoundManagerRemote, as the Volumes card does, and restores every value it changes.
@MainActor
enum RemoteSelfTest {
    private final class Log<Value> { var values: [Value] = [] }

    static func run(_ checker: Checker) async {
        guard let tool = RunningTool.instances(of: SoundChannel.bundleID).first, let url = tool.bundleURL else {
            return checker.fail("Sound Manager aberto")
        }
        SelfTest.log("Sound Manager em \(url.path), pid \(tool.processIdentifier)")
        let remote = SoundManagerRemote()
        remote.start()
        checker.check(await wait(3) { remote.state != nil }, "estado recebido em até 3 s")
        guard let output = remote.state?.output else { return checker.fail("dispositivo de saída no estado") }

        await masterVolume(remote, output: output, checker: checker)
        await appVolume(remote, checker: checker)
        await menuBarIcon(remote, pid: tool.processIdentifier, url: url, checker: checker)
        await malformedMessages(pid: tool.processIdentifier, checker: checker)
        await relaunch(remote, url: url, checker: checker)
        remote.stop()
    }

    private static func masterVolume(_ remote: SoundManagerRemote, output: SoundState.Output, checker: Checker) async {
        let original = output.volume
        let wasMuted = output.muted
        let target = original >= 0.5 ? original - 0.2 : original + 0.2
        SelfTest.log("volume geral: \(percent(original)), mudo \(wasMuted), \(output.name)")

        let sent = Log<Double>()
        let observer = SoundChannel.observeActions { if case let .setMasterVolume(volume) = $0 { sent.values.append(volume) } }
        let steps = 60
        let drag = (1...steps).map { original + (target - original) * Double($0) / Double(steps) }
        let start = Date()
        for volume in drag {
            remote.setVolume(volume, for: .master)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let elapsed = Date().timeIntervalSince(start)
        checker.check(await wait(1) { sent.values.last == drag.last }, "a última mensagem leva o valor final do arraste")
        SoundChannel.stopObserving(observer)
        let limit = Int(elapsed / SoundManagerRemote.sendInterval) + 2
        checker.check(sent.values.count <= limit, "\(steps) eventos de arraste em \(String(format: "%.2f", elapsed)) s viram \(sent.values.count) mensagens (máximo \(limit))")
        checker.check(await wait(2) { abs(masterLevel(remote) - target) < 0.02 }, "arraste do volume geral chega a \(percent(target)) no eco")
        if output.isSoftware {
            SelfTest.log("pulado: dispositivo sem volume próprio, sem leitura direta do macOS")
        } else if let real = systemVolume() {
            checker.check(abs(Double(real) / 100 - target) <= 0.02, "volume real do Mac em \(real)%, pedido \(percent(target))")
        } else {
            checker.fail("leitura do volume pelo macOS")
        }

        remote.toggleMute(for: .master)
        checker.check(await wait(2) { remote.state?.output?.muted == !wasMuted }, "mudo do volume geral troca pelo canal")
        remote.toggleMute(for: .master)
        checker.check(await wait(2) { remote.state?.output?.muted == wasMuted }, "mudo do volume geral volta")

        remote.setVolume(original, for: .master)
        checker.check(await wait(2) { abs(masterLevel(remote) - original) < 0.02 }, "volume geral restaurado em \(percent(original))")
        if remote.state?.output?.muted != wasMuted {
            remote.toggleMute(for: .master)
            checker.check(await wait(2) { remote.state?.output?.muted == wasMuted }, "mudo do volume geral restaurado")
        }
    }

    private static func appVolume(_ remote: SoundManagerRemote, checker: Checker) async {
        guard let state = remote.state, let app = state.apps.first else {
            return SelfTest.log("pulado: nenhum app tocando som, volume e mudo por app sem teste")
        }
        SelfTest.log("app: \(app.name), salvo \(percent(app.volume)), efetivo \(percent(app.effectiveVolume)), mudo \(app.muted)")
        remote.toggleMute(for: .app(app.id))
        checker.check(await wait(2) { appState(remote, app.id)?.muted == !app.muted }, "mudo de \(app.name) troca pelo canal")
        remote.toggleMute(for: .app(app.id))
        checker.check(await wait(2) { appState(remote, app.id)?.muted == app.muted }, "mudo de \(app.name) volta")

        // An app saved above the ceiling cannot get its saved value back: a drag stores at most the ceiling.
        guard app.volume <= state.ceiling else {
            return SelfTest.log("pulado: volume de \(app.name) salvo acima do teto de \(percent(state.ceiling)); sem volta exata")
        }
        let target = app.volume > 0.2 ? app.volume - 0.2 : min(app.volume + 0.2, state.ceiling)
        remote.setVolume(target, for: .app(app.id))
        checker.check(await wait(2) { abs((appState(remote, app.id)?.volume ?? -1) - target) < 0.01 }, "volume de \(app.name) vai a \(percent(target))")
        remote.setVolume(app.volume, for: .app(app.id))
        checker.check(await wait(2) { abs((appState(remote, app.id)?.volume ?? -1) - app.volume) < 0.01 }, "volume de \(app.name) restaurado em \(percent(app.volume))")
    }

    // Control Center hosts every menu bar item, so the check counts all on screen: hiding the icon takes exactly one off.
    private static func menuBarIcon(_ remote: SoundManagerRemote, pid: pid_t, url: URL, checker: Checker) async {
        let wasVisible = remote.showsMenuBarIcon
        if !wasVisible {
            remote.setMenuBarIcon(visible: true)
            _ = await wait(2) { remote.state?.showsMenuBarIcon == true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let visibleCount = statusItemCount()
        remote.setMenuBarIcon(visible: false)
        checker.check(await wait(2) { remote.state?.showsMenuBarIcon == false }, "estado diz ícone oculto")
        checker.check(await wait(2) { statusItemCount() == visibleCount - 1 }, "ícone sai da barra de menus (\(visibleCount) → \(statusItemCount()) itens)")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        checker.check(await wait(3) { remote.state?.showsMenuBarIcon == true }, "abrir o Sound Manager de novo mostra o ícone")
        checker.check(await wait(2) { statusItemCount() == visibleCount }, "ícone volta à barra de menus (\(statusItemCount()) itens)")
        checker.check(RunningTool.instances(of: SoundChannel.bundleID).map(\.processIdentifier) == [pid], "abrir de novo não cria outra cópia")

        if !wasVisible {
            remote.setMenuBarIcon(visible: false)
            checker.check(await wait(2) { remote.state?.showsMenuBarIcon == false }, "ícone oculto restaurado")
        }
    }

    private static func malformedMessages(pid: pid_t, checker: Checker) async {
        let center = DistributedNotificationCenter.default()
        let payloads: [Any] = ["{não é json", 42, #"{"setMasterVolume":"alto"}"#]
        for payload in payloads {
            center.postNotificationName(SoundChannel.actionName, object: nil, userInfo: [SoundChannel.payloadKey: payload], deliverImmediately: true)
        }
        let answers = Log<SoundState>()
        let observer = SoundChannel.observeStates { answers.values.append($0) }
        SoundChannel.send(.requestState)
        let answered = await wait(2) { !answers.values.isEmpty }
        SoundChannel.stopObserving(observer)
        checker.check(answered && RunningTool.instances(of: SoundChannel.bundleID).map(\.processIdentifier) == [pid], "Sound Manager ignora \(payloads.count) mensagens inválidas e segue respondendo")
    }

    private static func relaunch(_ remote: SoundManagerRemote, url: URL, checker: Checker) async {
        await RunningTool.quit(bundleID: SoundChannel.bundleID)
        checker.check(await wait(3) { remote.state == nil }, "estado some quando o Sound Manager fecha")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return checker.fail("abrir \(url.path): \(error.localizedDescription)")
        }
        checker.check(await wait(5) { remote.state != nil }, "estado volta quando o Sound Manager abre")
    }

    private static func masterLevel(_ remote: SoundManagerRemote) -> Double { remote.state?.output?.volume ?? -1 }

    private static func appState(_ remote: SoundManagerRemote, _ id: String) -> SoundState.App? {
        remote.state?.apps.first { $0.id == id }
    }

    // Read from macOS itself, apart from Sound Manager's echo.
    private static func systemVolume() -> Int? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&error)
        return result?.stringValue.flatMap { Int($0) }
    }

    private static func statusItemCount() -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.statusWindow))
        return windows.filter { $0[kCGWindowLayer as String] as? Int == level }.count
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
