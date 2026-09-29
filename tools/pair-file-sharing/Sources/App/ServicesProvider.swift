import AppKit

// Finder > Services > "Enviar para o celular" (NSServices in Info.plist).
final class ServicesProvider: NSObject {
    var handler: ([URL]) -> Void = { _ in }

    @objc func sendToPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        handler(urls)
    }
}
