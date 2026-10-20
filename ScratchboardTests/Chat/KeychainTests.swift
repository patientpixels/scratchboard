import XCTest
@testable import Scratchboard

@MainActor
class KeychainTests: XCTestCase {
  func testInMemoryRoundTrip() throws {
    let store = InMemorySecretStore()
    XCTAssertNil(store.string(for: "key"))

    try store.set("secret", for: "key")
    XCTAssertEqual(store.string(for: "key"), "secret")

    try store.set("other", for: "key")
    XCTAssertEqual(store.string(for: "key"), "other")

    try store.set("", for: "key")
    XCTAssertNil(store.string(for: "key"))

    try store.set("again", for: "key")
    try store.delete("key")
    XCTAssertNil(store.string(for: "key"))
  }

  func testRealKeychainRoundTrip() throws {
    let keychain = Keychain(service: "com.oliverspindler.Scratchboard.tests.\(UUID().uuidString)")
    let account = "roundTrip"
    defer { try? keychain.delete(account) }

    do {
      try keychain.set("secret", for: account)
    } catch let error as KeychainError {
      throw XCTSkip("Keychain not accessible from test host: \(error.localizedDescription)")
    }

    XCTAssertEqual(keychain.string(for: account), "secret")

    try keychain.set("updated ✨", for: account)
    XCTAssertEqual(keychain.string(for: account), "updated ✨")

    try keychain.set("", for: account)
    XCTAssertNil(keychain.string(for: account))

    try keychain.set("again", for: account)
    try keychain.delete(account)
    XCTAssertNil(keychain.string(for: account))

    // Deleting a missing item is not an error.
    XCTAssertNoThrow(try keychain.delete(account))
  }
}
