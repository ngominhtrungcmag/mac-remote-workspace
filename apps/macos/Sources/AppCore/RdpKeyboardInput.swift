import Foundation

/// Stateful Windows App macOS shortcuts; delayed Command avoids opening Start for copy/paste.
public struct RdpKeyboardInput {
  private var modifiers: Set<UInt16> = []
  private var keys: [UInt16: RdpKeyboardEvent] = [:]
  private var shortcuts: Set<UInt16> = []
  private var remoteModifiers: [UInt16: RdpKeyboardEvent] = [:]
  private var windowsCommand = false
  private var commandUsed = false
  private static let commands: Set<UInt16> = [0x37, 0x36]
  private static let shortcutKeys: Set<UInt16> = [0x08, 0x07, 0x09, 0x00, 0x06, 0x03, 0x0D]

  public init() {}

  public static func isCommandShortcut(_ key: UInt16) -> Bool {
    shortcutKeys.contains(key)
  }

  public mutating func modifierChanged(_ key: UInt16) -> [RdpKeyboardEvent] {
    let wasPressed = modifiers.contains(key)
    if Self.commands.contains(key), !wasPressed, modifiers.isDisjoint(with: Self.commands) {
      commandUsed = false
    }
    if !modifiers.insert(key).inserted { modifiers.remove(key) }
    var tap: [RdpKeyboardEvent] = []
    if Self.commands.contains(key), wasPressed, !commandUsed,
      let event = RdpScancodeMapper.mapMacKeyCode(key) {
      tap = [event, event.released]
      commandUsed = true
    }
    if modifiers.isDisjoint(with: Self.commands) { windowsCommand = false }
    return tap + syncModifiers()
  }

  public mutating func keyDown(_ key: UInt16) -> [RdpKeyboardEvent] {
    guard let event = RdpScancodeMapper.mapMacKeyCode(key) else { return [] }
    if keys[key] == nil, !modifiers.isDisjoint(with: Self.commands) {
      commandUsed = true
      if Self.isCommandShortcut(key) {
        shortcuts.insert(key)
      } else {
        windowsCommand = true
      }
    }
    let changes = syncModifiers()
    keys[key] = event
    return changes + [event]
  }

  public mutating func keyUp(_ key: UInt16) -> [RdpKeyboardEvent] {
    guard let event = keys.removeValue(forKey: key) else { return [] }
    shortcuts.remove(key)
    return [event.released] + syncModifiers()
  }

  public mutating func releaseAll() -> [RdpKeyboardEvent] {
    let events = keys.sorted { $0.key < $1.key }.map { $0.value.released }
      + remoteModifiers.sorted { $0.key < $1.key }.map { $0.value.released }
    self = Self()
    return events
  }

  private mutating func syncModifiers() -> [RdpKeyboardEvent] {
    var desired = modifiers.subtracting(Self.commands)
    if !shortcuts.isEmpty { desired.insert(0x3B) }
    if windowsCommand, shortcuts.isEmpty { desired.formUnion(modifiers.intersection(Self.commands)) }
    var events: [RdpKeyboardEvent] = []
    for key in remoteModifiers.keys.sorted() where !desired.contains(key) {
      if let event = remoteModifiers.removeValue(forKey: key) { events.append(event.released) }
    }
    for key in desired.sorted() where remoteModifiers[key] == nil {
      if let event = RdpScancodeMapper.mapMacKeyCode(key) {
        remoteModifiers[key] = event
        events.append(event)
      }
    }
    return events
  }
}

private extension RdpKeyboardEvent {
  var released: Self {
    Self(scancode: scancode, isExtended: isExtended, isKeyUp: true)
  }
}
