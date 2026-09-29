import AppKit
import Combine
import CunhaKit
import SwiftUI

// Menu bar icon: click opens the popover, files dropped on the icon go to the phone.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let center: TransferCenter
    private var observation: AnyCancellable?

    init(center: TransferCenter, launchAtLogin: LaunchAtLogin, openPairing: @escaping () -> Void) {
        self.center = center
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(openPairing: openPairing)
            .environmentObject(center)
            .environmentObject(launchAtLogin))
        if let button = statusItem.button {
            button.image = Self.icon(busy: false)
            button.action = #selector(togglePopover)
            button.target = self
        }
        acceptDrops()
        DispatchQueue.main.async { [weak self] in self?.acceptDrops() }
        observation = center.$transfers.map { !$0.isEmpty }.removeDuplicates().sink { [weak self] busy in
            self?.statusItem.button?.image = Self.icon(busy: busy)
        }
    }

    // The button's window forwards dragging messages to its delegate.
    private func acceptDrops() {
        guard let window = statusItem.button?.window, window.delegate !== self else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    private static func icon(busy: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: busy ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle", accessibilityDescription: "Pair File Sharing")
        image?.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPopover() {
        if !popover.isShown { togglePopover() }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        statusItem.button?.highlight(true)
        return fileURLs(sender).isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        center.send(urls)
        showPopover()
        return true
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
