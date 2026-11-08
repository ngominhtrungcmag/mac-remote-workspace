import Foundation

/// Represents a translated Windows RDP Set 1 keyboard scancode event.
public struct RdpKeyboardEvent: Sendable, Equatable {
  public let scancode: UInt16
  public let isExtended: Bool
  public let isKeyUp: Bool

  public init(scancode: UInt16, isExtended: Bool = false, isKeyUp: Bool = false) {
    self.scancode = scancode
    self.isExtended = isExtended
    self.isKeyUp = isKeyUp
  }
}

/// Translates macOS Carbon / NSEvent virtual keycodes into Windows Set 1 Scancodes
/// for RDP input forwarding (US-021, FR-021).
public enum RdpScancodeMapper {
  private struct ScancodeEntry {
    let scancode: UInt16
    let isExtended: Bool
  }

  // Scancode mapping table from macOS Carbon keycodes to Windows Set 1 Scancodes
  private static let table: [UInt16: ScancodeEntry] = [
    // Letters
    0x00: ScancodeEntry(scancode: 0x1E, isExtended: false), // A
    0x01: ScancodeEntry(scancode: 0x1F, isExtended: false), // S
    0x02: ScancodeEntry(scancode: 0x20, isExtended: false), // D
    0x03: ScancodeEntry(scancode: 0x21, isExtended: false), // F
    0x04: ScancodeEntry(scancode: 0x23, isExtended: false), // H
    0x05: ScancodeEntry(scancode: 0x22, isExtended: false), // G
    0x06: ScancodeEntry(scancode: 0x2C, isExtended: false), // Z
    0x07: ScancodeEntry(scancode: 0x2D, isExtended: false), // X
    0x08: ScancodeEntry(scancode: 0x2E, isExtended: false), // C
    0x09: ScancodeEntry(scancode: 0x2F, isExtended: false), // V
    0x0B: ScancodeEntry(scancode: 0x30, isExtended: false), // B
    0x0C: ScancodeEntry(scancode: 0x10, isExtended: false), // Q
    0x0D: ScancodeEntry(scancode: 0x11, isExtended: false), // W
    0x0E: ScancodeEntry(scancode: 0x12, isExtended: false), // E
    0x0F: ScancodeEntry(scancode: 0x13, isExtended: false), // R
    0x10: ScancodeEntry(scancode: 0x15, isExtended: false), // Y
    0x11: ScancodeEntry(scancode: 0x14, isExtended: false), // T
    0x1F: ScancodeEntry(scancode: 0x18, isExtended: false), // O
    0x20: ScancodeEntry(scancode: 0x16, isExtended: false), // U
    0x22: ScancodeEntry(scancode: 0x17, isExtended: false), // I
    0x23: ScancodeEntry(scancode: 0x19, isExtended: false), // P
    0x25: ScancodeEntry(scancode: 0x26, isExtended: false), // L
    0x26: ScancodeEntry(scancode: 0x24, isExtended: false), // J
    0x28: ScancodeEntry(scancode: 0x25, isExtended: false), // K
    0x2D: ScancodeEntry(scancode: 0x31, isExtended: false), // N
    0x2E: ScancodeEntry(scancode: 0x32, isExtended: false), // M

    // Numbers & Punctuation
    0x12: ScancodeEntry(scancode: 0x02, isExtended: false), // 1
    0x13: ScancodeEntry(scancode: 0x03, isExtended: false), // 2
    0x14: ScancodeEntry(scancode: 0x04, isExtended: false), // 3
    0x15: ScancodeEntry(scancode: 0x05, isExtended: false), // 4
    0x16: ScancodeEntry(scancode: 0x07, isExtended: false), // 6
    0x17: ScancodeEntry(scancode: 0x06, isExtended: false), // 5
    0x18: ScancodeEntry(scancode: 0x0D, isExtended: false), // Equal
    0x19: ScancodeEntry(scancode: 0x0A, isExtended: false), // 9
    0x1A: ScancodeEntry(scancode: 0x08, isExtended: false), // 7
    0x1B: ScancodeEntry(scancode: 0x0C, isExtended: false), // Minus
    0x1C: ScancodeEntry(scancode: 0x09, isExtended: false), // 8
    0x1D: ScancodeEntry(scancode: 0x0B, isExtended: false), // 0
    0x1E: ScancodeEntry(scancode: 0x1B, isExtended: false), // Right Bracket ]
    0x21: ScancodeEntry(scancode: 0x1A, isExtended: false), // Left Bracket [
    0x27: ScancodeEntry(scancode: 0x28, isExtended: false), // Quote
    0x29: ScancodeEntry(scancode: 0x27, isExtended: false), // Semicolon
    0x2A: ScancodeEntry(scancode: 0x2B, isExtended: false), // Backslash
    0x2B: ScancodeEntry(scancode: 0x33, isExtended: false), // Comma
    0x2C: ScancodeEntry(scancode: 0x35, isExtended: false), // Slash
    0x2F: ScancodeEntry(scancode: 0x34, isExtended: false), // Period
    0x32: ScancodeEntry(scancode: 0x29, isExtended: false), // Grave / Tilde

    // Controls & Navigation
    0x24: ScancodeEntry(scancode: 0x1C, isExtended: false), // Return / Enter
    0x30: ScancodeEntry(scancode: 0x0F, isExtended: false), // Tab
    0x31: ScancodeEntry(scancode: 0x39, isExtended: false), // Space
    0x33: ScancodeEntry(scancode: 0x0E, isExtended: false), // Backspace (Delete on Mac)
    0x35: ScancodeEntry(scancode: 0x01, isExtended: false), // Escape
    0x75: ScancodeEntry(scancode: 0x53, isExtended: true),  // Forward Delete
    0x7B: ScancodeEntry(scancode: 0x4B, isExtended: true),  // Left Arrow
    0x7C: ScancodeEntry(scancode: 0x4D, isExtended: true),  // Right Arrow
    0x7D: ScancodeEntry(scancode: 0x50, isExtended: true),  // Down Arrow
    0x7E: ScancodeEntry(scancode: 0x48, isExtended: true),  // Up Arrow
    0x73: ScancodeEntry(scancode: 0x47, isExtended: true),  // Home
    0x77: ScancodeEntry(scancode: 0x4F, isExtended: true),  // End
    0x74: ScancodeEntry(scancode: 0x49, isExtended: true),  // Page Up
    0x79: ScancodeEntry(scancode: 0x51, isExtended: true),  // Page Down

    // Modifiers (Cmd -> Win, Option -> Alt, Ctrl -> Ctrl)
    0x37: ScancodeEntry(scancode: 0x5B, isExtended: true),  // Left Command -> Left Windows key
    0x36: ScancodeEntry(scancode: 0x5C, isExtended: true),  // Right Command -> Right Windows key
    0x38: ScancodeEntry(scancode: 0x2A, isExtended: false), // Left Shift
    0x3C: ScancodeEntry(scancode: 0x36, isExtended: false), // Right Shift
    0x3A: ScancodeEntry(scancode: 0x38, isExtended: false), // Left Option -> Left Alt
    0x3D: ScancodeEntry(scancode: 0x38, isExtended: true),  // Right Option -> Right Alt (AltGr)
    0x3B: ScancodeEntry(scancode: 0x1D, isExtended: false), // Left Control -> Left Ctrl
    0x3E: ScancodeEntry(scancode: 0x1D, isExtended: true),  // Right Control -> Right Ctrl
    0x39: ScancodeEntry(scancode: 0x3A, isExtended: false), // CapsLock

    // Function keys (F1 - F12)
    0x7A: ScancodeEntry(scancode: 0x3B, isExtended: false), // F1
    0x78: ScancodeEntry(scancode: 0x3C, isExtended: false), // F2
    0x63: ScancodeEntry(scancode: 0x3D, isExtended: false), // F3
    0x76: ScancodeEntry(scancode: 0x3E, isExtended: false), // F4
    0x60: ScancodeEntry(scancode: 0x3F, isExtended: false), // F5
    0x61: ScancodeEntry(scancode: 0x40, isExtended: false), // F6
    0x62: ScancodeEntry(scancode: 0x41, isExtended: false), // F7
    0x64: ScancodeEntry(scancode: 0x42, isExtended: false), // F8
    0x65: ScancodeEntry(scancode: 0x43, isExtended: false), // F9
    0x6D: ScancodeEntry(scancode: 0x44, isExtended: false), // F10
    0x67: ScancodeEntry(scancode: 0x57, isExtended: false), // F11
    0x6F: ScancodeEntry(scancode: 0x58, isExtended: false), // F12
  ]

  /// Translates a macOS keycode into an RDP keyboard event.
  public static func mapMacKeyCode(_ keyCode: UInt16, isKeyUp: Bool = false) -> RdpKeyboardEvent? {
    guard let entry = table[keyCode] else { return nil }
    return RdpKeyboardEvent(scancode: entry.scancode, isExtended: entry.isExtended, isKeyUp: isKeyUp)
  }

  /// Generates the key down/up sequence for Windows "Ctrl+Alt+Del".
  public static func ctrlAltDelSequence() -> [RdpKeyboardEvent] {
    [
      // Key down: Left Ctrl, Left Alt, Extended Delete
      RdpKeyboardEvent(scancode: 0x1D, isExtended: false, isKeyUp: false), // Ctrl down
      RdpKeyboardEvent(scancode: 0x38, isExtended: false, isKeyUp: false), // Alt down
      RdpKeyboardEvent(scancode: 0x53, isExtended: true, isKeyUp: false),  // Del down
      // Key up: Extended Delete, Left Alt, Left Ctrl
      RdpKeyboardEvent(scancode: 0x53, isExtended: true, isKeyUp: true),   // Del up
      RdpKeyboardEvent(scancode: 0x38, isExtended: false, isKeyUp: true),  // Alt up
      RdpKeyboardEvent(scancode: 0x1D, isExtended: false, isKeyUp: true),  // Ctrl up
    ]
  }
}
