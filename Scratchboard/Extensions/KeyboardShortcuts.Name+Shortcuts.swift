import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", initial: Shortcut(.c, modifiers: [.command, .shift]))
  static let pin = Self("pin", initial: Shortcut(.p, modifiers: [.option]))
  static let delete = Self("delete", initial: Shortcut(.delete, modifiers: [.option]))
  static let captureText = Self("captureText", initial: Shortcut(.f3, modifiers: [.command]))
  static let togglePreview = Self("togglePreview", initial: Shortcut(.space, modifiers: [.control]))
}
