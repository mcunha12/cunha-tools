import Foundation

@main
enum Main {
    static func main() {
        if let status = SelfTest.runIfRequested() { exit(status) }
        PairFileSharingApp.run()
    }
}
