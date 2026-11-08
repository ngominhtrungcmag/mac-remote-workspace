import Darwin
import Foundation

struct RdpClipboardFile: Equatable {
  let name: String
  let size: UInt64
  let isDirectory: Bool
  var relativePath: String { name.replacingOccurrences(of: "\\", with: "/") }
}

enum RdpClipboardFileError: Error, LocalizedError {
  case invalid, limit, changed, io
  var errorDescription: String? {
    switch self {
    case .invalid: "Clipboard files contain unsupported names, links, or invalid data."
    case .limit: "Clipboard copy is limited to 256 entries and 1 GiB per selection."
    case .changed: "The clipboard or source file changed. Copy the files again."
    case .io: "Clipboard file transfer failed. Check file permissions and free disk space."
    }
  }
}

/// MS-RDPECLIP FileGroupDescriptorW. All names are relative to an isolated staging directory.
enum RdpClipboardFiles {
  static let formatName = "FileGroupDescriptorW"
  static let formatID: UInt32 = 0xC001
  static let maxEntries = 256
  static let maxTotalBytes: UInt64 = 1 << 30
  static let chunkBytes = 64 << 10
  static let descriptorBytes = 592
  static let maxDescriptorBytes = 4 + maxEntries * descriptorBytes

  static func validate(_ entries: [RdpClipboardFile]) throws {
    guard !entries.isEmpty, entries.count <= maxEntries else { throw RdpClipboardFileError.limit }
    var names: [String: Bool] = [:]
    var total: UInt64 = 0
    for entry in entries {
      let path = entry.relativePath
      let parts = path.components(separatedBy: "/")
      guard entry.name.utf16.count < 260, !parts.isEmpty,
        parts.allSatisfy({ part in
          let stem = part.components(separatedBy: ".")[0].uppercased()
          return !part.isEmpty && part != "." && part != ".."
            && !part.hasSuffix(".") && !part.hasSuffix(" ")
            && !part.unicodeScalars.contains { $0.value < 32 || ":*?\"<>|".unicodeScalars.contains($0) }
            && !["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"].contains(stem)
        })
      else { throw RdpClipboardFileError.invalid }
      let key = path.precomposedStringWithCanonicalMapping.lowercased()
      guard names[key] == nil else { throw RdpClipboardFileError.invalid }
      names[key] = entry.isDirectory
      guard entry.size <= maxTotalBytes - total else { throw RdpClipboardFileError.limit }
      total += entry.size
    }
    for path in names.keys {
      var parent = (path as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard names[parent] != false else { throw RdpClipboardFileError.invalid }
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
  }

  static func encode(_ entries: [RdpClipboardFile]) throws -> Data {
    try validate(entries)
    var data = Data(count: 4 + entries.count * descriptorBytes)
    write(UInt32(entries.count), to: &data, at: 0)
    for (index, entry) in entries.enumerated() {
      let base = 4 + index * descriptorBytes
      write(entry.isDirectory ? 0x80000004 : 0x80000044, to: &data, at: base)
      write(entry.isDirectory ? 0x10 : 0x80, to: &data, at: base + 36)
      write(UInt32(entry.size >> 32), to: &data, at: base + 64)
      write(UInt32(truncatingIfNeeded: entry.size), to: &data, at: base + 68)
      let name = entry.relativePath.replacingOccurrences(of: "/", with: "\\")
      for (i, unit) in name.utf16.enumerated() {
        data[base + 72 + i * 2] = UInt8(truncatingIfNeeded: unit)
        data[base + 73 + i * 2] = UInt8(unit >> 8)
      }
    }
    return data
  }

  static func decode(_ input: Data) throws -> [RdpClipboardFile] {
    let data = Data(input)
    guard data.count >= 4 else { throw RdpClipboardFileError.invalid }
    let count = Int(read(data, at: 0))
    guard count > 0, count <= maxEntries, data.count == 4 + count * descriptorBytes else {
      throw RdpClipboardFileError.invalid
    }
    var entries: [RdpClipboardFile] = []
    for index in 0..<count {
      let base = 4 + index * descriptorBytes
      let directory = read(data, at: base + 36) & 0x10 != 0
      guard read(data, at: base) & 4 != 0,
        directory || read(data, at: base) & 0x40 != 0 else { throw RdpClipboardFileError.invalid }
      let nameData = data.subdata(in: (base + 72)..<(base + descriptorBytes))
      var end = 0
      while end < 520, nameData[end] != 0 || nameData[end + 1] != 0 { end += 2 }
      guard end < 520, let name = String(data: nameData.prefix(end), encoding: .utf16LittleEndian) else {
        throw RdpClipboardFileError.invalid
      }
      let size = (UInt64(read(data, at: base + 64)) << 32) | UInt64(read(data, at: base + 68))
      entries.append(.init(name: name, size: directory ? 0 : size, isDirectory: directory))
    }
    try validate(entries)
    return entries
  }

  static func read(_ data: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
  }

  private static func write(_ value: UInt32, to data: inout Data, at offset: Int) {
    for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
  }
}

/// Holds descriptors open so a later pathname replacement cannot redirect a remote read.
final class RdpClipboardFileSource {
  private(set) var entries: [RdpClipboardFile] = []
  private var handles: [Int: FileHandle] = [:]
  private var metadata: [Int: stat] = [:]

  init(urls: [URL]) throws {
    guard !urls.isEmpty, urls.count <= RdpClipboardFiles.maxEntries else { throw RdpClipboardFileError.limit }
    for url in urls {
      guard url.isFileURL else { throw RdpClipboardFileError.invalid }
      try add(url: url, name: url.lastPathComponent)
    }
    try RdpClipboardFiles.validate(entries)
  }

  private func add(url: URL, name: String, parent: Int32 = AT_FDCWD, child: String? = nil) throws {
    guard entries.count < RdpClipboardFiles.maxEntries else { throw RdpClipboardFileError.limit }
    guard !(child ?? url.lastPathComponent).contains("\\") else { throw RdpClipboardFileError.invalid }
    let fd = openat(parent, child ?? url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw RdpClipboardFileError.io }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw RdpClipboardFileError.io }
    let kind = info.st_mode & S_IFMT
    guard kind == S_IFREG || kind == S_IFDIR, info.st_size >= 0 else { throw RdpClipboardFileError.invalid }
    let index = entries.count
    entries.append(.init(name: name, size: kind == S_IFDIR ? 0 : UInt64(info.st_size), isDirectory: kind == S_IFDIR))
    try RdpClipboardFiles.validate(entries)
    if kind == S_IFREG {
      handles[index] = handle
      metadata[index] = info
    } else {
      guard let directory = fdopendir(dup(fd)) else { throw RdpClipboardFileError.io }
      defer { closedir(directory) }
      while true {
        errno = 0
        guard let item = readdir(directory) else {
          if errno != 0 { throw RdpClipboardFileError.io }
          break
        }
        let child = withUnsafePointer(to: &item.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        guard child != ".", child != ".." else { continue }
        try add(url: url.appendingPathComponent(child), name: name + "\\" + child, parent: fd, child: child)
      }
      withExtendedLifetime(handle) {}

    }
  }

  func read(index: Int, offset: UInt64, count: Int) throws -> Data {
    guard entries.indices.contains(index), let handle = handles[index], let original = metadata[index],
      count > 0, count <= RdpClipboardFiles.chunkBytes, offset <= entries[index].size,
      UInt64(count) <= entries[index].size - offset else { throw RdpClipboardFileError.invalid }
    var now = stat()
    guard fstat(handle.fileDescriptor, &now) == 0, now.st_size == original.st_size,
      now.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
      now.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw RdpClipboardFileError.changed }
    var data = Data(count: count)
    let readCount = data.withUnsafeMutableBytes { pread(handle.fileDescriptor, $0.baseAddress, count, off_t(offset)) }
    guard readCount == count else { throw RdpClipboardFileError.io }
    return data
  }
}

/// Incoming files are never placed directly into a user's destination or exposed while partial.
final class RdpClipboardFileReceiver {
  let root: URL
  let entries: [RdpClipboardFile]
  private(set) var index = 0
  private(set) var offset: UInt64 = 0
  private var handle: FileHandle?
  private var cancelled = false

  init(entries: [RdpClipboardFile], directory: URL? = nil) throws {
    try RdpClipboardFiles.validate(entries)
    self.entries = entries
    root = (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("mrw-rdp-clipboard-" + UUID().uuidString, isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else { throw RdpClipboardFileError.io }
    do { try advance() } catch { cancel(); throw error }
  }

  deinit { cancel() }

  var completedURLs: [URL]? {
    guard !cancelled, index == entries.count else { return nil }
    let names = Set(entries.map { $0.relativePath.components(separatedBy: "/")[0] })
    return names.sorted().map { root.appendingPathComponent($0) }
  }

  func append(_ data: Data) throws {
    guard !cancelled, index < entries.count, !data.isEmpty,
      data.count <= RdpClipboardFiles.chunkBytes,
      UInt64(data.count) <= entries[index].size - offset, let handle else { throw RdpClipboardFileError.invalid }
    try handle.write(contentsOf: data)
    offset += UInt64(data.count)
    if offset == entries[index].size {
      try handle.close()
      self.handle = nil
      index += 1
      offset = 0
      try advance()
    }
  }

  func cancel() {
    cancelled = true
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func advance() throws {
    while index < entries.count {
      let entry = entries[index]
      let url = root.appendingPathComponent(entry.relativePath)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if entry.isDirectory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } else {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RdpClipboardFileError.io }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if entry.size > 0 { handle = file; return }
        try file.close()
      }
      index += 1
    }
  }
}
