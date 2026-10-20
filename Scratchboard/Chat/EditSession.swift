import Foundation
import SwiftData

// Persisted state of a chat edit session. Versions and transcript are stored
// as JSON so their shape can evolve without schema migrations. Linked history
// items are the clip the session started from and the saved results; each
// item records the version it corresponds to in `editSessionVersion`.
@Model
final class EditSession {
  var createdAt: Date = Date.now
  var updatedAt: Date = Date.now
  var currentNumber: Int = 1
  var versionsData = Data()
  var transcriptData = Data()

  @Relationship(deleteRule: .nullify, inverse: \HistoryItem.editSession)
  var items: [HistoryItem] = []

  init() {}

  var versions: [ArtefactVersion] {
    get { (try? JSONDecoder().decode([ArtefactVersion].self, from: versionsData)) ?? [] }
    set { versionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
  }

  var transcript: [TranscriptEntry] {
    get { (try? JSONDecoder().decode([TranscriptEntry].self, from: transcriptData)) ?? [] }
    set { transcriptData = (try? JSONEncoder().encode(newValue)) ?? Data() }
  }

  // Deletes sessions that no history item links to anymore.
  @discardableResult
  static func deleteOrphans(in context: ModelContext) -> Int {
    context.processPendingChanges()
    try? context.save()

    let descriptor = FetchDescriptor<EditSession>(predicate: #Predicate { $0.items.isEmpty })
    guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else {
      return 0
    }

    orphans.forEach(context.delete)
    context.processPendingChanges()
    try? context.save()

    return orphans.count
  }
}
