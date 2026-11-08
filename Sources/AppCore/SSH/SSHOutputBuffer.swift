import Foundation

/// Thread-safe bounded output buffer for streaming terminal session data.
/// Preserves split multibyte UTF-8 sequences until subsequent chunks arrive,
/// caps maximum stored data size, and provides coalesced draining.
public final class SSHOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer: Data
  public let capacity: Int

  public init(capacity: Int = 102400) { // 100 KB default capacity
    self.capacity = max(1, capacity)
    self.buffer = Data()
  }

  /// Appends incoming data chunk into the buffer.
  /// If buffer exceeds capacity, older bytes are discarded.
  public func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }

    buffer.append(data)
    if buffer.count > capacity {
      let excess = buffer.count - capacity
      buffer.removeSubrange(0..<excess)
    }
  }

  /// Drains complete UTF-8 characters from the buffer into a String.
  /// Any trailing incomplete multi-byte sequence remains in the buffer
  /// until the rest of the bytes arrive.
  public func drainDecodableString() -> String {
    lock.lock()
    defer { lock.unlock() }

    guard !buffer.isEmpty else { return "" }

    let completeByteCount = Self.validUTF8PrefixLength(in: buffer)
    if completeByteCount == 0 {
      // If the buffer only contains an incomplete sequence (up to 3 bytes), wait.
      // But if buffer has exceeded 4 bytes and still 0 valid prefix (malformed data),
      // decode with replacement to avoid deadlocking.
      if buffer.count >= 4 {
        let fallback = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return fallback
      }
      return ""
    }

    let validData = buffer.subdata(in: 0..<completeByteCount)
    buffer.removeSubrange(0..<completeByteCount)
    return String(decoding: validData, as: UTF8.self)
  }

  /// Drains all buffered raw bytes (for a terminal emulator that handles UTF-8/escape sequences itself).
  public func drainBytes() -> Data {
    lock.lock()
    defer { lock.unlock() }
    let out = buffer
    buffer.removeAll(keepingCapacity: true)
    return out
  }

  /// Clears buffer.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    buffer.removeAll(keepingCapacity: true)
  }

  /// Determines how many bytes from the beginning form complete valid UTF-8 sequences,
  /// preserving trailing incomplete code point bytes (1 to 3 bytes).
  public static func validUTF8PrefixLength(in data: Data) -> Int {
    guard !data.isEmpty else { return 0 }

    return data.withUnsafeBytes { rawBuffer -> Int in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
      let count = rawBuffer.count

      // Check trailing 1 to 3 bytes for an incomplete leading multi-byte sequence
      var trailingIncomplete = 0
      for i in 1...min(4, count) {
        let byte = base[count - i]
        if (byte & 0x80) == 0 {
          // ASCII byte - complete
          break
        } else if (byte & 0xC0) == 0xC0 {
          // Leading byte of multi-byte sequence
          let expectedLength: Int
          if (byte & 0xE0) == 0xC0 {
            expectedLength = 2
          } else if (byte & 0xF0) == 0xE0 {
            expectedLength = 3
          } else if (byte & 0xF8) == 0xF0 {
            expectedLength = 4
          } else {
            // Invalid leading byte
            break
          }

          let availableLength = i
          if availableLength < expectedLength {
            trailingIncomplete = availableLength
          }
          break
        }
      }

      return count - trailingIncomplete
    }
  }
}
