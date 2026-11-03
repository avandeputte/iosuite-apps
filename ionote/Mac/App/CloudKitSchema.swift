import CoreData
import Foundation
import SwiftData

/// Creates every record type and field of the notes model in the iCloud container's Development
/// environment, so the schema can be deployed to Production in the CloudKit Console (TestFlight and
/// App Store builds only see Production). SwiftData has no call for this, so it goes through Core Data,
/// as Apple's "Syncing model data across a person's devices" article shows. Uses a throwaway store.
enum CloudKitSchema {
    static func initialize() -> Bool {
        guard let id = Persistence.cloudKitContainerID, Entitlements.hasCloudKit else {
            print("ionotes: this build isn't signed for iCloud")
            return false
        }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [NoteRecord.self, FolderRecord.self, TagRecord.self]) else {
            print("ionotes: could not build the Core Data model")
            return false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ionotes-schema-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: id)
        description.shouldAddStoreAsynchronously = false
        let container = NSPersistentCloudKitContainer(name: "Notes", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            print("ionotes: could not open the schema store: \(loadError)")
            return false
        }
        do {
            try container.initializeCloudKitSchema()
            print("ionotes: CloudKit schema initialized in \(id) (Development)")
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            return true
        } catch {
            print("ionotes: initializeCloudKitSchema failed: \(error)")
            return false
        }
    }
}
