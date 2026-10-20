import AppKit
import SwiftData
import XCTest
@testable import Scratchboard

@MainActor
final class StorageMigrationTests: XCTestCase {
  private var directory: URL!
  private var url: URL { directory.appending(path: "Storage.sqlite") }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory.appending(path: "StorageMigrationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  // A store written the way Maccy does it (unversioned, no migration plan)
  // opens with the migration plan and keeps its items.
  func testUnversionedStoreMigratesToV2() throws {
    try writeUnversionedStore()

    try openMigrated { context in
      let items = try context.fetch(FetchDescriptor<HistoryItem>(sortBy: [SortDescriptor(\.title)]))
      XCTAssertEqual(items.map(\.title), ["bar", "foo"])
      XCTAssertEqual(items.map(\.text), ["bar", "foo"])
      XCTAssertEqual(items.map(\.pin), [nil, "f"])
      XCTAssertEqual(items.map(\.numberOfCopies), [1, 3])
      XCTAssertEqual(items.map(\.application), [nil, "com.apple.Notes"])
      XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItemContent>()), 2)
      XCTAssertNil(items[0].editSession)

      let session = EditSession()
      session.versions = [ArtefactVersion(number: 1, text: "foo", author: .original, createdAt: .now)]
      context.insert(session)
      items[1].editSession = session
      items[1].editSessionVersion = 1
      try context.save()
    }

    try openMigrated { context in
      let pinned = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin != nil })
      let item = try XCTUnwrap(context.fetch(pinned).first)
      XCTAssertEqual(item.editSession?.versions.map(\.text), ["foo"])
      XCTAssertEqual(item.editSessionVersion, 1)
    }
  }

  // Fixtures/MaccyStore.sqlite was written by the pre-versioning code
  // (`ModelContainer(for: HistoryItem.self)`), so this guards SchemaV1
  // against drifting from the real Maccy schema.
  func testMaccyFixtureMigratesToV2() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "MaccyStore", withExtension: "sqlite"))
    try FileManager.default.copyItem(at: fixture, to: url)

    try openMigrated { context in
      let items = try context.fetch(FetchDescriptor<HistoryItem>(sortBy: [SortDescriptor(\.title)]))
      XCTAssertEqual(items.map(\.text), ["bar", "foo"])
      XCTAssertEqual(items.map(\.pin), [nil, "f"])
      XCTAssertEqual(items.map(\.numberOfCopies), [1, 3])

      let session = EditSession()
      context.insert(session)
      items[0].editSession = session
      try context.save()
    }

    try openMigrated { context in
      XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItem>()), 2)
      XCTAssertEqual(try context.fetch(FetchDescriptor<EditSession>()).first?.items.count, 1)
    }
  }

  func testNewStoreOpensWithMigrationPlan() throws {
    try openMigrated { context in
      context.insert(EditSession())
      try context.save()
    }
    try openMigrated { context in
      XCTAssertEqual(try context.fetchCount(FetchDescriptor<EditSession>()), 1)
    }
  }

  private func writeUnversionedStore() throws {
    let container = try ModelContainer(for: SchemaV1.HistoryItem.self, configurations: ModelConfiguration(url: url))
    let context = ModelContext(container)

    let foo = SchemaV1.HistoryItem(contents: [content("foo")])
    foo.title = "foo"
    foo.pin = "f"
    foo.numberOfCopies = 3
    foo.application = "com.apple.Notes"
    let bar = SchemaV1.HistoryItem(contents: [content("bar")])
    bar.title = "bar"
    context.insert(foo)
    context.insert(bar)
    try context.save()
  }

  private func openMigrated(_ body: (ModelContext) throws -> Void) throws {
    let container = try Storage.makeContainer(configuration: ModelConfiguration(url: url))
    try body(ModelContext(container))
  }

  private func content(_ text: String) -> SchemaV1.HistoryItemContent {
    SchemaV1.HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
  }
}
