import Foundation

/// Coordinates asynchronous session work and its final authorized action.
public final class NativeSSHSessionCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var currentSessionID = UUID()

  public init() {}

  public func reset() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    currentSessionID = UUID()
    return currentSessionID
  }

  public func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    currentSessionID = UUID()
  }

  public func isValid(_ id: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return currentSessionID == id
  }

  @discardableResult
  public func performIfValid(_ id: UUID, operation: () throws -> Void) rethrows -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard currentSessionID == id else { return false }
    try operation()
    return true
  }
}
