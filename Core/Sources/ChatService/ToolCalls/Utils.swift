import AppKit
import AppKitExtension
import Foundation
import Logger
import XcodeInspector

class Utils {
    public static func openFileInXcode(
        fileURL: URL, 
        completion: ((NSRunningApplication?, Error?) -> Void)? = nil
    ) {
        guard let xcodeBundleURL = NSWorkspace.getXcodeBundleURL()
        else {
            if let completion = completion {
                completion(nil, NSError(domain: "The Xcode app is not found.", code: 0))
            }
            return
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: xcodeBundleURL,
            configuration: configuration
        ) { app, error in
            if let completion = completion {
                completion(app, error)
            } else if let error = error {
                Logger.client.error("Failed to open file \(String(describing: error))")
            }
        }
    }
    
    public static func getXcode(by workspacePath: String) -> XcodeAppInstanceInspector? {
        return XcodeInspector.shared.xcodes.first(
            where: {
                $0.workspaceURL?.path == workspacePath
            })
    }
}
