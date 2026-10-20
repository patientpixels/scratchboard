import AppKit
import Defaults
import SwiftData
import XCTest
@testable import Scratchboard

@MainActor
final class EditSessionLifecycleTests: XCTestCase {
  private let savedSize = Defaults[.size]
  private var context: ModelContext { Storage.shared.context }

  override func setUp() {
    super.setUp()
    History.shared.clearAll()
    Defaults[.size] = 10
  }

  override func tearDown() {
    History.shared.clearAll()
    Defaults[.size] = savedSize
    super.tearDown()
  }

  func testDeletingLastLinkedItemDeletesSession() throws {
    let origin = History.shared.add(textItem("A"))
    let result = History.shared.add(textItem("B"))
    let session = link(origin.item, result.item)

    History.shared.delete(origin)
    XCTAssertEqual(try sessionCount(), 1)
    XCTAssertEqual(session.items, [result.item])

    History.shared.delete(result)
    XCTAssertEqual(try sessionCount(), 0)
  }

  func testClearKeepsSessionsOfPinnedItems() throws {
    let pinned = History.shared.add(textItem("A"))
    History.shared.togglePin(pinned)
    let unpinned = History.shared.add(textItem("B"))
    let kept = link(pinned.item)
    link(unpinned.item)
    XCTAssertEqual(try sessionCount(), 2)

    History.shared.clear()

    let sessions = try context.fetch(FetchDescriptor<EditSession>())
    XCTAssertEqual(sessions, [kept])
    XCTAssertTrue(pinned.item.editSession === kept)
  }

  func testClearAllDeletesSessions() throws {
    let pinned = History.shared.add(textItem("A"))
    History.shared.togglePin(pinned)
    link(pinned.item)
    link(History.shared.add(textItem("B")).item)

    History.shared.clearAll()

    XCTAssertEqual(try sessionCount(), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItem>()), 0)
  }

  func testHistorySizeLimitDeletesSessionOfDroppedItem() throws {
    Defaults[.size] = 2
    link(History.shared.add(textItem("A")).item)
    History.shared.add(textItem("B"))
    XCTAssertEqual(try sessionCount(), 1)

    History.shared.add(textItem("C"))

    XCTAssertEqual(History.shared.items.count, 2)
    XCTAssertEqual(try sessionCount(), 0)
  }

  func testCopyingLinkedTextAgainKeepsSession() throws {
    let origin = History.shared.add(textItem("A")).item
    let session = link(origin)
    origin.editSessionVersion = 1

    let merged = History.shared.add(textItem("A")).item

    XCTAssertEqual(History.shared.items.count, 1)
    XCTAssertTrue(merged.editSession === session)
    XCTAssertEqual(merged.editSessionVersion, 1)
    XCTAssertEqual(try sessionCount(), 1)
  }

  func testStartupCleanupDeletesOrphanedSessions() throws {
    context.insert(EditSession())
    link(History.shared.add(textItem("A")).item)
    try context.save()

    _ = try Storage.shared.cleanupOrphanedContents()

    XCTAssertEqual(try sessionCount(), 1)
  }

  @discardableResult
  private func link(_ items: HistoryItem...) -> EditSession {
    let session = EditSession()
    context.insert(session)
    for item in items {
      item.editSession = session
    }
    try? context.save()
    return session
  }

  private func sessionCount() throws -> Int {
    try context.fetchCount(FetchDescriptor<EditSession>())
  }
}
