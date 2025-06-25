import AppKit

extension NSWorkspace {
    public static func getXcodeBundleURL() -> URL? {
        var xcodeBundleURL: URL?
        
        // Get currently running Xcode application URL
        if let xcodeApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) {
            xcodeBundleURL = xcodeApp.bundleURL
        }
        
        // Fallback to standard path if we couldn't get the running instance
        if xcodeBundleURL == nil {
            let standardPath = "/Applications/Xcode.app"
            if FileManager.default.fileExists(atPath: standardPath) {
                xcodeBundleURL = URL(fileURLWithPath: standardPath)
            }
        }
        
        return xcodeBundleURL
    }
}
