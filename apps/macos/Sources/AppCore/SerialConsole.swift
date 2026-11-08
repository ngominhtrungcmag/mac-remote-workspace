import Darwin
import Foundation

// P2 serial console (US-031). Local device only; no secrets or transcripts are persisted.

public enum SerialParity: String, CaseIterable, Sendable { case none, even, odd }
public enum SerialFlowControl: String, CaseIterable, Sendable { case none, rtsCts, xonXoff }

public enum SerialError: Error, Equatable, AppCoreLocalizedError {
  case invalidConfig(String)
  case notFound(String)
  case busy(String)
  case permissionDenied(String)
  case system(String, Int32)
  case closed

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidConfig(let message):
      AppCoreLocalization.format(
        "Invalid serial settings: %1$@", Self.localizedConfigMessage(message, locale: locale), locale: locale)
    case .notFound(let path):
      AppCoreLocalization.format("Serial port %1$@ was not found. Is the adapter plugged in?", path, locale: locale)
    case .busy(let path):
      AppCoreLocalization.format("Serial port %1$@ is busy (in use by another process).", path, locale: locale)
    case .permissionDenied(let path):
      AppCoreLocalization.format("Permission denied opening %1$@.", path, locale: locale)
    case .system(let path, let code):
      AppCoreLocalization.format("Could not open %1$@: %2$@.", path, String(cString: strerror(code)), locale: locale)
    case .closed:
      AppCoreLocalization.string("The serial port is closed.", locale: locale)
    }
  }

  private static func localizedConfigMessage(_ message: String, locale: Locale?) -> String {
    if message == "data bits must be 5-8" {
      return AppCoreLocalization.string("data bits must be 5-8", locale: locale)
    }
    if message == "stop bits must be 1 or 2" {
      return AppCoreLocalization.string("stop bits must be 1 or 2", locale: locale)
    }
    let baudPrefix = "unsupported baud rate "
    if message.hasPrefix(baudPrefix) {
      return AppCoreLocalization.format(
        "Unsupported serial baud rate: %1$@", String(message.dropFirst(baudPrefix.count)), locale: locale)
    }
    return AppCoreLocalization.string(message, locale: locale)
  }
}

public struct SerialConfig: Equatable, Sendable {
  public static let standardBaudRates: [Int] = [
    300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400, 460_800, 921_600,
  ]
  public static let devicePrefix = "/dev/cu."

  public var path: String
  public var baudRate: Int
  public var dataBits: Int
  public var parity: SerialParity
  public var stopBits: Int
  public var flowControl: SerialFlowControl

  public init(
    path: String, baudRate: Int = 115_200, dataBits: Int = 8, parity: SerialParity = .none,
    stopBits: Int = 1, flowControl: SerialFlowControl = .none
  ) {
    self.path = path
    self.baudRate = baudRate
    self.dataBits = dataBits
    self.parity = parity
    self.stopBits = stopBits
    self.flowControl = flowControl
  }

  /// Rejects anything but a plain device node under the given prefix (no traversal).
  public func validate(devicePrefix: String = SerialConfig.devicePrefix) throws {
    guard path.hasPrefix(devicePrefix), path.count > devicePrefix.count,
      !path.contains(".."), !path.dropFirst(5).contains("/"), !path.contains("\0")
    else { throw SerialError.invalidConfig("port must be a \(devicePrefix)* device") }
    guard Self.standardBaudRates.contains(baudRate) else {
      throw SerialError.invalidConfig("unsupported baud rate \(baudRate)")
    }
    guard (5...8).contains(dataBits) else { throw SerialError.invalidConfig("data bits must be 5-8") }
    guard (1...2).contains(stopBits) else { throw SerialError.invalidConfig("stop bits must be 1 or 2") }
  }

  /// Raw 8-bit-clean termios for this config.
  public func makeTermios() -> termios {
    var t = termios()
    cfmakeraw(&t)
    t.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
    t.c_cflag |= tcflag_t(CREAD | CLOCAL)
    switch dataBits {
    case 5: t.c_cflag |= tcflag_t(CS5)
    case 6: t.c_cflag |= tcflag_t(CS6)
    case 7: t.c_cflag |= tcflag_t(CS7)
    default: t.c_cflag |= tcflag_t(CS8)
    }
    switch parity {
    case .none: break
    case .even: t.c_cflag |= tcflag_t(PARENB)
    case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
    }
    if stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) }
    switch flowControl {
    case .none: break
    case .rtsCts: t.c_cflag |= tcflag_t(CRTSCTS)
    case .xonXoff: t.c_iflag |= tcflag_t(IXON | IXOFF)
    }
    t.c_cc.16 = 1  // VMIN
    t.c_cc.17 = 0  // VTIME
    cfsetspeed(&t, speed_t(baudRate))
    return t
  }
}

public enum SerialPortEnumerator {
  public static func availablePorts(devDirectory: String = "/dev") -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: devDirectory)) ?? []
    return names.filter { $0.hasPrefix("cu.") }.sorted().map { devDirectory + "/" + $0 }
  }
}

/// One open serial port. Reads are delivered on a private queue; close is idempotent.
public final class SerialSession: @unchecked Sendable {
  private let fd: Int32
  private let queue = DispatchQueue(label: "serial.session")
  private let source: DispatchSourceRead
  private let lock = NSLock()
  private var isClosed = false
  public let config: SerialConfig

  /// `devicePrefix` is overridable only so tests can open a pty slave.
  public static func open(
    _ config: SerialConfig, devicePrefix: String = SerialConfig.devicePrefix,
    onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void = {}
  ) throws -> SerialSession {
    try config.validate(devicePrefix: devicePrefix)
    let fd = Darwin.open(config.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
      switch errno {
      case ENOENT, ENXIO, ENODEV: throw SerialError.notFound(config.path)
      case EBUSY: throw SerialError.busy(config.path)
      case EACCES, EPERM: throw SerialError.permissionDenied(config.path)
      default: throw SerialError.system(config.path, errno)
      }
    }
    // Exclusive access: a second opener gets EBUSY.
    if ioctl(fd, UInt(TIOCEXCL)) != 0 && errno == EBUSY {
      Darwin.close(fd)
      throw SerialError.busy(config.path)
    }
    var t = config.makeTermios()
    guard tcsetattr(fd, TCSANOW, &t) == 0 else {
      let e = errno
      Darwin.close(fd)
      throw SerialError.system(config.path, e)
    }
    return SerialSession(fd: fd, config: config, onData: onData, onClose: onClose)
  }

  private init(
    fd: Int32, config: SerialConfig, onData: @escaping @Sendable (Data) -> Void,
    onClose: @escaping @Sendable () -> Void
  ) {
    self.fd = fd
    self.config = config
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      var buf = [UInt8](repeating: 0, count: 4096)
      let n = read(fd, &buf, buf.count)
      if n > 0 {
        onData(Data(buf[0..<n]))
      } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
        // EOF / device unplugged (EIO)
        self.close()
        onClose()
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
  }

  public func write(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { throw SerialError.closed }
    var offset = 0
    var stalls = 0
    try data.withUnsafeBytes { raw in
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n > 0 { offset += n; stalls = 0; continue }
        guard n < 0, errno == EAGAIN || errno == EINTR, stalls < 50 else {
          throw SerialError.system(config.path, errno)
        }
        stalls += 1
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&p, 1, 100)  // bounded: ~5 s max stall, then error
      }
    }
  }

  public func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { return }
    isClosed = true
    source.cancel()  // cancel handler closes the fd
  }

  deinit { close() }
}
