import AppKit
import UserNotifications

// Posts "received" notifications; clicking one reveals the files in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current() }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func received(title: String, body: String, urls: [URL]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paths": urls.map(\.path)]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        DispatchQueue.main.async {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty {
                let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Pair File Sharing")
                NSWorkspace.shared.open(folder)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
