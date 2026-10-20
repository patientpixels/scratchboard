import AppKit.NSPasteboard
import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Scratchboard/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try Self.makeContainer(configuration: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: Schema(versionedSchema: SchemaV2.self),
      migrationPlan: StorageMigrationPlan.self,
      configurations: configuration
    )
  }

  // Deletes edit sessions that no history item links to anymore.
  @discardableResult
  func deleteOrphanedEditSessions() -> Int {
    EditSession.deleteOrphans(in: context)
  }

  // Bulk deletion can't nullify the item → edit session relationship, so
  // items have to be detached before they're bulk-deleted.
  func detachEditSessions(unpinnedOnly: Bool) {
    let descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.editSession != nil })
    guard let items = try? context.fetch(descriptor) else { return }

    for item in items where !unpinnedOnly || item.pin == nil {
      item.editSession = nil
      item.editSessionVersion = nil
    }
    context.processPendingChanges()
    try? context.save()
  }

  func cleanupOrphanedContents() throws -> Int {
    deleteOrphanedEditSessions()
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func removeUnpersistableContents() throws -> Int {
    let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
    let unwanted = contents.filter {
      !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
    }

    guard !unwanted.isEmpty else {
      return 0
    }

    unwanted.forEach(context.delete)
    context.processPendingChanges()
    try context.save()

    return unwanted.count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Scratchboard
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}

nonisolated enum StorageMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
  static var stages: [MigrationStage] {
    [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
  }
}

// Current schema: the top-level `HistoryItem`, `HistoryItemContent` and
// `EditSession` models.
nonisolated enum SchemaV2: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
  static var models: [any PersistentModel.Type] {
    [HistoryItem.self, HistoryItemContent.self, EditSession.self]
  }
}

// The unversioned schema Maccy writes. It must match those model definitions
// exactly, or existing stores aren't recognized as V1.
nonisolated enum SchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
  static var models: [any PersistentModel.Type] { [HistoryItem.self, HistoryItemContent.self] }

  @Model
  class HistoryItem {
    var application: String?
    var firstCopiedAt: Date = Date.now
    var lastCopiedAt: Date = Date.now
    var numberOfCopies: Int = 1
    var pin: String?
    var title = ""

    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent] = []

    init(contents: [HistoryItemContent] = []) {
      self.contents = contents
    }
  }

  @Model
  class HistoryItemContent {
    var type: String = ""
    var value: Data?

    @Relationship
    var item: HistoryItem?

    init(type: String, value: Data? = nil) {
      self.type = type
      self.value = value
    }
  }
}
