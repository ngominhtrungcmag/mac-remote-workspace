import Foundation

/// Exponential backoff for manual/automatic reconnect attempts (TC-024). Pure and clock-injected.
public struct SSHReconnectBackoff: Sendable, Equatable {
  public let base: TimeInterval
  public let cap: TimeInterval
  /// Fraction (0...1) of each delay that may be randomly shaved off; 0 disables jitter (FR-027).
  public let jitter: Double
  public private(set) var consecutiveFailures = 0
  public private(set) var notBefore: Date?

  public init(base: TimeInterval = 1, cap: TimeInterval = 30, jitter: Double = 0) {
    self.jitter = min(1, max(0, jitter))
    self.base = max(0.001, base)
    self.cap = max(self.base, cap)
  }

  /// `sample` is a uniform value in 0..<1; the delay lands in [d * (1 - jitter), d] with d capped at `cap`.
  public func delay(afterFailures n: Int, sample: Double = 0) -> TimeInterval {
    guard n > 0 else { return 0 }
    let d = min(cap, base * pow(2, Double(min(n - 1, 30))))
    return d * (1 - jitter * min(1, max(0, sample)))
  }

  /// Seconds the caller must still wait before another attempt (0 = allowed now).
  public func remaining(now: Date = Date()) -> TimeInterval {
    guard let notBefore else { return 0 }
    return max(0, notBefore.timeIntervalSince(now))
  }

  public mutating func recordFailure(now: Date = Date(), sample: Double = .random(in: 0..<1)) {
    consecutiveFailures += 1
    notBefore = now.addingTimeInterval(delay(afterFailures: consecutiveFailures, sample: sample))
  }

  /// Successful connection or explicit user cancel clears the throttle.
  public mutating func reset() {
    consecutiveFailures = 0
    notBefore = nil
  }
}

/// Persisted placeholder for a session tab. Holds no credentials, output or commands (FR-012).
public struct SSHSessionPlaceholder: Codable, Sendable, Equatable {
  public let hostID: String
  public let tabCount: Int
  public init(hostID: String, tabCount: Int) {
    self.hostID = hostID
    self.tabCount = tabCount
  }
}

/// Stores workspace session layout. Restored sessions are always unconnected; nothing is replayed.
public final class SSHSessionRestoreStore: @unchecked Sendable {
  public static let maxTabs = 8
  private let url: URL
  private let lock = NSLock()

  public init(url: URL) { self.url = url }

  public static var defaultURL: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory()))
      .appendingPathComponent("MacRemoteWorkspace/session-layout.json")
  }

  public func load() -> [SSHSessionPlaceholder] {
    lock.lock(); defer { lock.unlock() }
    guard let data = try? Data(contentsOf: url),
      let items = try? JSONDecoder().decode([SSHSessionPlaceholder].self, from: data)
    else { return [] }  // corrupt/missing file degrades to empty layout
    return items.filter { !$0.hostID.isEmpty }
      .map { SSHSessionPlaceholder(hostID: $0.hostID, tabCount: min(Self.maxTabs, max(1, $0.tabCount))) }
  }

  public func tabCount(forHost hostID: String) -> Int {
    load().first { $0.hostID == hostID }?.tabCount ?? 1
  }

  public func save(hostID: String, tabCount: Int) {
    var items = load().filter { $0.hostID != hostID }
    if tabCount > 1 { items.append(SSHSessionPlaceholder(hostID: hostID, tabCount: min(Self.maxTabs, tabCount))) }
    lock.lock(); defer { lock.unlock() }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
  }
}
