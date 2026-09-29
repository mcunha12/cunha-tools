import AppKit
import SwiftUI

struct PairingView: View {
    @ObservedObject var flow: PairingFlow
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(24)
        .frame(width: 380)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .working(let text):
            ProgressView().controlSize(.large)
            Text(text).font(.callout)
        case .qr(let host):
            if let image = flow.qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            }
            Text("Aponte a câmera do celular para o código e confirme no app Cunha Tools.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(host.map { "O celular precisa estar no mesmo Wi-Fi deste Mac (\($0))." } ?? "Este Mac não está em uma rede Wi-Fi ou cabeada.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let note = flow.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Tentar pelo adb", action: flow.begin)
                Button("Cancelar", action: close)
            }
        case .done(let name):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Pareado com \(name)").font(.headline)
            Text("Arraste arquivos para o ícone na barra de menus para enviar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Fechar", action: close).keyboardShortcut(.defaultAction)
        }
    }
}

@MainActor
final class PairingWindowController: NSObject, NSWindowDelegate {
    private let flow: PairingFlow
    private var window: NSWindow?

    init(center: TransferCenter) {
        flow = PairingFlow(center: center)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Parear celular"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PairingView(flow: flow, close: { [weak window] in window?.close() }))
            window.center()
            self.window = window
            flow.begin()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        flow.end()
        window = nil
    }
}
