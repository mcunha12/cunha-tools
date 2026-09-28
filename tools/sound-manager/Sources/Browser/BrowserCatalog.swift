import Foundation

enum BrowserCatalog {
    private static let bundleIDsByBrand = [
        "Google Chrome": "com.google.Chrome",
        "Brave": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Opera": "com.operasoftware.Opera",
        "Vivaldi": "com.vivaldi.Vivaldi",
    ]

    private static let unbrandedChromiumBundleIDs: Set<String> = [
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "ai.perplexity.comet",
    ]

    static func isExtensionBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDsByBrand.values.contains(bundleID) || unbrandedChromiumBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome")
    }

    static func session(_ session: BrowserSession, belongsTo appName: String, bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        guard let brand = specificBrand(of: session) else {
            return unbrandedChromiumBundleIDs.contains(bundleID)
        }
        if let mapped = bundleIDsByBrand[brand] {
            return bundleID == mapped || (mapped == "com.google.Chrome" && bundleID.hasPrefix(mapped))
        }
        return appName.localizedCaseInsensitiveContains(brand) || brand.localizedCaseInsensitiveContains(appName)
    }

    private static func specificBrand(of session: BrowserSession) -> String? {
        session.brands.first { brand in
            brand != "Chromium" && !brand.localizedCaseInsensitiveContains("brand")
        }
    }
}
