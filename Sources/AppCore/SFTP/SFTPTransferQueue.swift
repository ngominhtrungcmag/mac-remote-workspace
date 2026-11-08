import Combine
import Foundation

/// Coordinates native background file uploads and downloads.
/// Bounded to a maximum of 2 concurrent operations per ADR/SRS guidance.
@MainActor
public final class SFTPTransferQueue: ObservableObject {
  @Published public private(set) var items: [SFTPTransferItem] = []

  private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _isCancelled
    }

    func cancel() {
      lock.lock()
      _isCancelled = true
      lock.unlock()
    }
  }

  private let maxConcurrency = 2
  private var activeCount = 0
  private var pendingOrder: [UUID] = []
  private var pendingTransfers: [UUID: @Sendable () async -> Void] = [:]
  private var cancellationBoxes: [UUID: CancellationBox] = [:]
  private var activeTransfers: Set<UUID> = []

  private var idleActions: [@Sendable () -> Void] = []

  public init() {}

  /// Runs `work` once no transfer is queued or running (immediately if already idle). Used to release
  /// session-scoped secrets that queued transfers still need after their browser sheet closed.
  public func runWhenIdle(_ work: @escaping @Sendable () -> Void) {
    if hasActiveTransfers { idleActions.append(work) } else { work() }
  }

  public var hasActiveTransfers: Bool {
    items.contains { item in
      if case .running = item.status { return true }
      if case .queued = item.status { return true }
      return false
    }
  }

  // MARK: - Enqueue Operations

  public func enqueueUpload(
    client: NativeSFTPClient,
    localURL: URL,
    remotePath: String,
    overwrite: Bool
  ) -> UUID {
    let id = UUID()
    let localSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0

    let item = SFTPTransferItem(
      id: id,
      kind: .upload,
      sourceDescription: localURL.lastPathComponent,
      destinationDescription: remotePath,
      totalBytes: localSize,
      transferredBytes: 0,
      status: .queued
    )
    items.insert(item, at: 0)

    let box = CancellationBox()
    cancellationBoxes[id] = box

    pendingOrder.append(id)
    pendingTransfers[id] = { [weak self] in
      await self?.executeUpload(
        id: id,
        client: client,
        localURL: localURL,
        remotePath: remotePath,
        overwrite: overwrite,
        isCancelled: { box.isCancelled }
      )
    }

    processNext()
    return id
  }

  public func enqueueDownload(
    client: NativeSFTPClient,
    remotePath: String,
    localDirectoryURL: URL,
    filename: String,
    overwrite: Bool,
    totalBytes: Int64 = 0
  ) -> UUID {
    let id = UUID()
    let item = SFTPTransferItem(
      id: id,
      kind: .download,
      sourceDescription: remotePath,
      destinationDescription: localDirectoryURL.appendingPathComponent(filename).path,
      totalBytes: totalBytes,
      transferredBytes: 0,
      status: .queued
    )
    items.insert(item, at: 0)

    let box = CancellationBox()
    cancellationBoxes[id] = box

    pendingOrder.append(id)
    pendingTransfers[id] = { [weak self] in
      await self?.executeDownload(
        id: id,
        client: client,
        remotePath: remotePath,
        localDirectoryURL: localDirectoryURL,
        filename: filename,
        overwrite: overwrite,
        isCancelled: { box.isCancelled }
      )
    }

    processNext()
    return id
  }

  // MARK: - Cancellation & Cleanup

  public func cancelTransfer(id: UUID) {
    guard let box = cancellationBoxes[id] else { return }
    box.cancel()
    if pendingTransfers.removeValue(forKey: id) != nil {
      pendingOrder.removeAll { $0 == id }
      cancellationBoxes.removeValue(forKey: id)
      updateStatus(id: id, status: .cancelled)
    }
  }

  /// App-quit path (FR-028): cancels every queued/running transfer, then waits (bounded) for
  /// in-flight workers to exit so sftp children are killed and `.mrw-part-*` files are removed.
  public func cancelAllAndWait(timeoutSeconds: TimeInterval = 10) async {
    for item in items {
      switch item.status {
      case .queued, .running: cancelTransfer(id: item.id)
      default: break
      }
    }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while activeCount > 0 && Date() < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  public func clearFinished() {
    items.removeAll { item in
      switch item.status {
      case .completed, .cancelled, .failed: return true
      default: return false
      }
    }
  }

  #if DEBUG
  public func insertItemForTesting(_ item: SFTPTransferItem) {
    items.append(item)
  }

  func insertActiveItemForTesting(_ item: SFTPTransferItem) {
    items.append(item)
    cancellationBoxes[item.id] = CancellationBox()
    activeTransfers.insert(item.id)
  }
  #endif

  // MARK: - Queue Dispatcher

  private func processNext() {
    guard activeCount < maxConcurrency else { return }
    guard let id = pendingOrder.first, let work = pendingTransfers.removeValue(forKey: id) else { return }
    pendingOrder.removeFirst()
    activeCount += 1
    activeTransfers.insert(id)
    updateStatus(id: id, status: .running(progress: nil))

    Task {
      await work()
      self.activeCount -= 1
      self.processNext()
    }
  }

  private func executeUpload(
    id: UUID,
    client: NativeSFTPClient,
    localURL: URL,
    remotePath: String,
    overwrite: Bool,
    isCancelled: @escaping @Sendable () -> Bool
  ) async {
    let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
      do {
        try client.uploadFile(
          from: localURL,
          to: remotePath,
          overwrite: overwrite,
          onProgress: { transferred, total in
            Task { @MainActor in
              self.updateProgress(id: id, transferred: transferred, total: total)
            }
          },
          isCancelled: isCancelled
        )
        return .success(())
      } catch {
        return .failure(error)
      }
    }.value

    finishTransfer(id: id, result: result)
  }

  private func executeDownload(
    id: UUID,
    client: NativeSFTPClient,
    remotePath: String,
    localDirectoryURL: URL,
    filename: String,
    overwrite: Bool,
    isCancelled: @escaping @Sendable () -> Bool
  ) async {
    let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
      do {
        let savedURL = try client.downloadFile(
          from: remotePath,
          to: localDirectoryURL,
          filename: filename,
          overwrite: overwrite,
          onProgress: { transferred, total in
            Task { @MainActor in
              self.updateProgress(id: id, transferred: transferred, total: total)
            }
          },
          isCancelled: isCancelled
        )
        return .success(savedURL)
      } catch {
        return .failure(error)
      }
    }.value

    finishTransfer(id: id, result: result.map { _ in () })
  }

  func updateProgress(id: UUID, transferred: Int64, total: Int64) {
    guard activeTransfers.contains(id), cancellationBoxes[id]?.isCancelled == false,
          let idx = items.firstIndex(where: { $0.id == id }),
          case .running = items[idx].status else { return }
    items[idx].transferredBytes = transferred
    let knownTotal = total > 0 ? total : (items[idx].kind == .download ? items[idx].totalBytes : 0)
    items[idx].status = .running(progress: knownTotal > 0 ? min(1, Double(transferred) / Double(knownTotal)) : nil)
  }

  func finishTransfer(id: UUID, result: Result<Void, Error>) {
    guard activeTransfers.remove(id) != nil else { return }
    cancellationBoxes.removeValue(forKey: id)
    switch result {
    case .success:
      updateStatus(id: id, status: .completed)
    case .failure(let err):
      if case SFTPError.cancelled = err {
        updateStatus(id: id, status: .cancelled)
      } else {
        updateStatus(id: id, status: .failed(err.localizedDescription))
      }
    }
  }

  private func updateStatus(id: UUID, status: SFTPTransferStatus) {
    defer {
      if !idleActions.isEmpty, !hasActiveTransfers {
        let actions = idleActions
        idleActions = []
        actions.forEach { $0() }
      }
    }
    if let idx = items.firstIndex(where: { $0.id == id }) {
      items[idx].status = status
      if case .completed = status {
        items[idx].finishedAt = Date()
        items[idx].transferredBytes = items[idx].totalBytes
        RedactedLogger.shared.info("sftp", "transfer \(id) completed")
      } else if case .failed = status {
        items[idx].finishedAt = Date()
        RedactedLogger.shared.error("sftp", "transfer \(id) failed")
      } else if case .cancelled = status {
        items[idx].finishedAt = Date()
      }
    }
  }
}
