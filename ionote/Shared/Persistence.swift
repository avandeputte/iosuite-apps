import Foundation
import SwiftData
#if os(macOS)
import Security
#endif

/// Builds the SwiftData container for notes. With the iCloud entitlement it syncs through the
/// CloudKit private database of the container named in Info.plist (`CloudKitContainer`);
/// without it (an unsigned debug build) it keeps notes on this device only.
enum Persistence {
    /// e.g. "iCloud.net.iothing.ionotes", set from the bundle id in project.yml.
    static var cloudKitContainerID: String? {
        Bundle.main.object(forInfoDictionaryKey: "CloudKitContainer") as? String
    }

    static func makeContainer(syncWithICloud: Bool) -> ModelContainer {
        let schema = Schema([NoteRecord.self, FolderRecord.self, TagRecord.self])
        if syncWithICloud, let id = cloudKitContainerID, Entitlements.hasCloudKit {
            let config = ModelConfiguration("Notes", schema: schema, url: AppPaths.notesStoreURL,
                                            cloudKitDatabase: .private(id))
            if let container = try? ModelContainer(for: schema, configurations: [config]) {
                return container
            }
            NSLog("ionotes: could not open the iCloud store, falling back to local only")
        }
        let local = ModelConfiguration("Notes", schema: schema, url: AppPaths.notesStoreURL, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("ionotes could not open its notes store: \(error)")
        }
    }
}

enum Entitlements {
    /// True when the running app was signed with the CloudKit entitlement. Creating a CKContainer
    /// without it crashes, so check first.
    static var hasCloudKit: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        return true  // iOS builds always carry their entitlements
        #endif
    }
}
