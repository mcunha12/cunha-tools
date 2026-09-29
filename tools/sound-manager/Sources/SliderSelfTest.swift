import AppKit
import CunhaKit
import SwiftUI

// --selftest-slider: synthetic mouse events on a LevelSlider 205 pt wide, as in the menu.
enum SliderSelfTest {
    private final class Level: ObservableObject {
        @Published var value = 0.3
        var ceiling = 1.0
    }

    private struct Host: View {
        @ObservedObject var level: Level
        var body: some View {
            LevelSlider(value: level.value, ceiling: level.ceiling) { level.value = $0 }
                .frame(width: SliderSelfTest.width)
                .padding(SliderSelfTest.padding)
        }
    }

    private struct Case {
        let label: String
        var start = 0.3
        var ceiling = 1.0
        let press: (Double) -> CGFloat
        var dragBy: CGFloat = 0
        let expected: (Double) -> Double
    }

    private static let width: CGFloat = 205
    private static let padding: CGFloat = 10
    private static let knob: CGFloat = 14

    private static func knobCenter(_ value: Double) -> CGFloat { padding + knob / 2 + (width - knob) * value }

    private static let cases: [Case] = [
        Case(label: "clique a 2 pt da ponta direita → 100%", press: { _ in padding + width - 2 }, expected: { _ in 1 }),
        Case(label: "clique a 10 pt da ponta direita → 100%", press: { _ in padding + width - 10 }, expected: { _ in 1 }),
        Case(label: "clique a 14 pt da ponta direita → 100%", press: { _ in padding + width - 14 }, expected: { _ in 1 }),
        Case(label: "clique a 10 pt da ponta esquerda → 0%", press: { _ in padding + 10 }, expected: { _ in 0 }),
        Case(label: "clique no meio da trilha → 50%", press: { _ in padding + width / 2 }, expected: { _ in 0.5 }),
        Case(label: "clique no centro do botão sem arrastar mantém 30%", press: knobCenter, expected: { $0 }),
        Case(label: "clique no centro do botão em 90% mantém 90%", start: 0.9, press: knobCenter, expected: { $0 }),
        Case(label: "arraste de 40 pt pelo botão sobe 40 pt de trilha", press: knobCenter, dragBy: 40, expected: { $0 + Double(40 / (width - knob)) }),
        Case(label: "clique na ponta direita com teto 60% → 60%", ceiling: 0.6, press: { _ in padding + width - 4 }, expected: { _ in 0.6 }),
    ]

    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let level = Level()
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width + 2 * padding, height: 18 + 2 * padding), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: Host(level: level))
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            var checks = SelfTestChecks(name: "selftest-slider")
            var remaining = cases[...]

            func next() {
                guard let test = remaining.popFirst() else { exit(checks.finish()) }
                level.value = test.start
                level.ceiling = test.ceiling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let x = test.press(test.start)
                    send(.leftMouseDown, x: x, to: window)
                    if test.dragBy != 0 {
                        for step in 1...8 { send(.leftMouseDragged, x: x + test.dragBy * CGFloat(step) / 8, to: window) }
                    }
                    send(.leftMouseUp, x: x + test.dragBy, to: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        checks.close(level.value, test.expected(test.start), test.label, tolerance: 0.005)
                        next()
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
        }
        application.run()
        exit(1)
    }

    private static func send(_ type: NSEvent.EventType, x: CGFloat, to window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: padding + 9), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )
        if let event { window.sendEvent(event) }
    }
}
