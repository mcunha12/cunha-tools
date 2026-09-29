import AppKit
import CunhaKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @EnvironmentObject private var center: TransferCenter
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    let openPairing: () -> Void
    @State private var isTargeted = false

    private var isPaired: Bool { center.pairing?.isComplete == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 10) {
                dropArea
                ForEach(center.transfers) { TransferRow(transfer: $0) }
                if let outcome = center.lastOutcome, center.transfers.isEmpty { OutcomeRow(outcome: outcome) }
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear(perform: launchAtLogin.refresh)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isPaired ? "iphone.gen3" : "iphone.gen3.slash")
                .foregroundStyle(isPaired ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pair File Sharing").font(.headline)
                Text(isPaired ? "Pareado com \(center.pairing!.displayName)" : "Nenhum celular pareado")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isPaired ? "Parear de novo" : "Parear celular", action: openPairing)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var dropArea: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Solte arquivos ou pastas aqui")
                .font(.callout)
            Button("Escolher arquivos…", action: chooseFiles)
                .controlSize(.small)
                .disabled(!isPaired)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .opacity(isPaired ? 1 : 0.5)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            center.send(files)
            return !files.isEmpty
        } isTargeted: { isTargeted = $0 }
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.setEnabled))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!launchAtLogin.isInstalled)
                .help(launchAtLogin.isInstalled ? "" : "Mova o Pair File Sharing para a pasta Aplicativos para ativar.")
            if launchAtLogin.needsApproval {
                Button("Aprovar nos Ajustes", action: launchAtLogin.openLoginItemsSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if let error = center.listenerError {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Recebimento indisponível: \(error)")
            }
            Spacer()
            Button("Pasta", action: center.openDownloads)
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Abrir Downloads/Pair File Sharing")
            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // The transient popover closes when the panel opens, so the center is captured before the modal loop.
    private func chooseFiles() {
        let center = self.center
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Enviar"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        center.send(panel.urls)
    }
}

private struct TransferRow: View {
    @EnvironmentObject private var center: TransferCenter
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: transfer.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                Text(transfer.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    center.cancel(transfer)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancelar")
            }
            .font(.callout)
            if transfer.total > 0 {
                ProgressView(value: transfer.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var detail: String {
        guard transfer.total > 0 else { return transfer.direction == .send ? "Conectando ao celular…" : "Preparando…" }
        var parts = ["\(Format.bytes(transfer.done)) de \(Format.bytes(transfer.total))"]
        if transfer.bytesPerSecond > 0 { parts.append(Format.rate(transfer.bytesPerSecond)) }
        if let left = transfer.secondsLeft { parts.append("faltam \(Format.duration(left))") }
        return parts.joined(separator: " · ")
    }
}

private struct OutcomeRow: View {
    @EnvironmentObject private var center: TransferCenter
    let outcome: Outcome

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: outcome.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(outcome.isError ? .orange : .green)
            Text(outcome.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !outcome.urls.isEmpty {
                Button("Mostrar") { center.reveal(outcome.urls) }
                    .controlSize(.small)
            }
        }
    }
}
