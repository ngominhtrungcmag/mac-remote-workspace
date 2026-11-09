import Darwin
import Foundation

/// Wire messages between the app and `RdpSessionHelper`.
/// Framing: u32 big-endian body length, then body = tag byte + payload.
/// Tag 0: JSON-encoded message. Tag 1: raw frame (u32 width, u32 height, u32 bytesPerRow, pixels).
/// ponytail: frames are copied through the socket (no IOSurface yet); upgrade path is an
/// IOSurface looked up by global ID or a shared-memory fd handed over via SCM_RIGHTS.
/// Secrets (`trustDecision` credentials) only ever travel over this socket, after the app's trust decision.
enum RdpHelperMessage: Equatable, Sendable, Codable {
  // app -> helper
  case start(host: String, port: Int, width: UInt32, height: UInt32, scaleFactor: UInt32, clipboardDirectory: String? = nil, sharedFolder: String? = nil, options: RdpConnectionOptions? = nil)
  case trustDecision(accepted: Bool, username: String?, domain: String?, password: String?)
  case key(scancode: UInt16, isExtended: Bool, isKeyUp: Bool)
  case pointer(x: UInt16, y: UInt16, buttonFlags: UInt16)
  case resize(width: UInt32, height: UInt32, scaleFactor: UInt32)
  case clipboardActive(Bool)
  case cancelClipboardFiles
  case abort
  // helper -> app
  case certificate(host: String, port: Int, sha256: String, subjectCN: String, issuerCN: String, changed: Bool)
  case connected
  case clipboardStatus(message: String, busy: Bool)
  case frame(width: Int, height: Int, bytesPerRow: Int, data: Data)
  case ended(code: UInt32, message: String, connected: Bool)

  /// Upper bound for one body; a 8K BGRA frame is ~132 MB.
  static let maxBodyBytes = 160 << 20

  func encoded() throws -> Data {
    if case .frame(let w, let h, let bpr, let data) = self {
      var out = Data()
      out.reserveCapacity(data.count + 17)
      out.append(Self.be32(UInt32(data.count + 13)))
      out.append(1)
      for value in [w, h, bpr] { out.append(Self.be32(UInt32(truncatingIfNeeded: value))) }
      out.append(data)
      return out
    }
    var body = Data()
    body.append(0)
    body.append(try JSONEncoder().encode(self))
    var out = Self.be32(UInt32(body.count))
    out.append(body)
    return out
  }

  static func decode(body: Data) throws -> RdpHelperMessage {
    guard let tag = body.first else { throw RdpHelperProtocolError.malformed }
    let payload = body.dropFirst()
    switch tag {
    case 0:
      return try JSONDecoder().decode(RdpHelperMessage.self, from: payload)
    case 1:
      guard payload.count >= 12 else { throw RdpHelperProtocolError.malformed }
      let base = payload.startIndex
      let w = Int(readBE32(payload, base)), h = Int(readBE32(payload, base + 4))
      let bpr = Int(readBE32(payload, base + 8))
      let pixels = Data(payload.dropFirst(12))
      guard w > 0, h > 0,
        w <= Int(RdpDisplayResolution.maximumDimension), h <= Int(RdpDisplayResolution.maximumDimension),
        bpr >= w * 4, bpr <= Int.max / h, pixels.count == bpr * h
      else { throw RdpHelperProtocolError.malformed }
      return .frame(width: w, height: h, bytesPerRow: bpr, data: pixels)
    default:
      throw RdpHelperProtocolError.malformed
    }
  }

  private static func be32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
  }

  private static func readBE32(_ d: Data, _ i: Int) -> UInt32 {
    (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
  }
}

enum RdpHelperProtocolError: Error, Equatable {
  case malformed
  case tooLarge
}

/// Blocking message channel over a connected socket fd. Owns the fd.
final class RdpHelperChannel: @unchecked Sendable {
  private let fd: Int32
  private let writeLock = NSLock()
  private let readLock = NSLock()
  private let closeLock = NSLock()
  private var closed = false

  init(fd: Int32) {
    self.fd = fd
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  deinit { close() }

  /// False if the peer is gone.
  @discardableResult
  func send(_ message: RdpHelperMessage) -> Bool {
    guard let bytes = try? message.encoded() else { return false }
    writeLock.lock()
    defer { writeLock.unlock() }
    guard !closeLock.withLock({ closed }) else { return false }
    return bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
      }
      return true
    }
  }

  /// nil on EOF or error; throws on a malformed message.
  func receive() throws -> RdpHelperMessage? {
    readLock.lock()
    defer { readLock.unlock() }
    guard !closeLock.withLock({ closed }) else { return nil }
    guard let header = readExactly(4) else { return nil }
    let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
    guard length > 0, length <= RdpHelperMessage.maxBodyBytes else { throw RdpHelperProtocolError.tooLarge }
    guard let body = readExactly(length) else { return nil }
    return try RdpHelperMessage.decode(body: body)
  }

  func close() {
    closeLock.lock()
    guard !closed else { closeLock.unlock(); return }
    closed = true
    Darwin.shutdown(fd, SHUT_RDWR)
    closeLock.unlock()
    writeLock.lock()
    readLock.lock()
    Darwin.close(fd)
    readLock.unlock()
    writeLock.unlock()
  }

  private func readExactly(_ count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    let ok = data.withUnsafeMutableBytes { raw -> Bool in
      while offset < count {
        let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
      }
      return true
    }
    return ok ? data : nil
  }
}
