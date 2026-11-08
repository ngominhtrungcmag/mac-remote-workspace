import Darwin
import Foundation

extension InventoryImportExportService {
  static let maxSSHConfigBytes = 1_048_576

  public static func previewSSHConfig(fileURL: URL, sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"), repository: HostRepository) throws -> InventoryImportPreview {
    var visited = Set<URL>()
    var size = 0
    func read(_ url: URL) throws -> String {
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL
      guard visited.insert(canonical).inserted else { return "" }
      let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let fileSize = (attributes[.size] as? NSNumber)?.intValue,
        fileSize <= maxSSHConfigBytes - size else {
        throw InventoryImportExportError.invalidCSV("SSH config exceeds 1 MiB or is not a regular file.")
      }
      let handle = try FileHandle(forReadingFrom: canonical)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maxSSHConfigBytes - size + 1) ?? Data()
      size += data.count
      guard size <= maxSSHConfigBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
        throw InventoryImportExportError.invalidCSV("SSH config exceeds 1 MiB or contains binary data.")
      }
      var result = ""
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
        if parts.count == 2 && parts[0].lowercased() == "include" {
          for pattern in parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=")).split(whereSeparator: \.isWhitespace) {
            let path = String(pattern)
            let expanded = (path as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : sshDirectory.appendingPathComponent(expanded).path
            var matches = glob_t()
            let status = glob(full, 0, nil, &matches)
            defer { globfree(&matches) }
            if status == 0, let paths = matches.gl_pathv {
              for index in 0..<Int(matches.gl_pathc) {
                if let path = paths[index] { result += try read(URL(fileURLWithPath: String(cString: path))) + "\n" }
              }
            } else if status != GLOB_NOMATCH { throw InventoryImportExportError.invalidCSV("SSH config Include could not be read.") }
          }
        } else { result += String(line) + "\n" }
      }
      return result
    }
    return try previewSSHConfig(text: read(fileURL), repository: repository)
  }

  public static func previewSSHConfig(text: String, repository: HostRepository) throws -> InventoryImportPreview {
    guard text.utf8.count <= maxSSHConfigBytes, !text.contains("\0") else {
      throw InventoryImportExportError.invalidCSV("SSH config exceeds 1 MiB or contains binary data.")
    }
    struct Block {
      var alias: String
      var hostName: String?
      var user: String?
      var port: String?
      var identity: String?
      var jump: String?
    }
    var blocks: [Block] = []
    var current: [Int] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
      guard parts.count == 2 else { continue }
      let key = parts[0].lowercased()
      let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
      switch key {
      case "host":
        current = []
        for alias in value.split(whereSeparator: \.isWhitespace).map(String.init) where !alias.contains(where: { "*?!".contains($0) }) {
          blocks.append(Block(alias: alias)); current.append(blocks.count - 1)
        }
      case "match": current = []
      case "hostname": for i in current where blocks[i].hostName == nil { blocks[i].hostName = value }
      case "user": for i in current where blocks[i].user == nil { blocks[i].user = value }
      case "port": for i in current where blocks[i].port == nil { blocks[i].port = value }
      case "identityfile": for i in current where blocks[i].identity == nil { blocks[i].identity = value }
      case "proxyjump": for i in current where blocks[i].jump == nil { blocks[i].jump = value.lowercased() == "none" ? nil : value }
      default: break
      }
    }
    if blocks.isEmpty { throw InventoryImportExportError.emptyDocument }
    var hosts: [ImportedHostDraft] = []
    var errors: [String] = []
    var seen = Set<String>()
    for block in blocks {
      let address = block.hostName ?? block.alias
      guard isSafeToken(block.alias), isSafeToken(address),
        block.user.map(isSafeToken) ?? true,
        block.identity.map(isSafePath) ?? true,
        block.port.map({ Int($0).map { (1...65535).contains($0) } ?? false }) ?? true,
        block.jump.map({ (try? SSHConnectionSettings.validateProxyJump($0)) != nil }) ?? true else {
        errors.append("Host '\(block.alias)' has invalid SSH settings."); continue
      }
      guard seen.insert(block.alias.lowercased()).inserted else { continue }
      let settings = SSHConnectionSettings(username: block.user ?? "", port: block.port.flatMap(Int.init) ?? 22,
        auth: .sshAgent, keyFilePath: block.identity ?? "", proxyJump: block.jump)
      hosts.append(ImportedHostDraft(workspaceName: "Local", groupName: nil, displayName: block.alias,
        address: address, environment: .development, sshSettings: settings, matchAliasOnly: true))
    }
    return try computePreview(totalHostsInFile: blocks.count, workspaces: [ImportedWorkspaceDraft(name: "Local")],
      groups: [], hosts: hosts, validationErrors: errors, repository: repository)
  }

  private static let unsafeChars = Set("`$;&|<>\"'\\")
  private static func isSafeToken(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 255 && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy {
      $0.value > 0x20 && $0.value < 0x7f && !unsafeChars.contains(Character($0))
    }
  }
  private static func isSafePath(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.count <= 4096 && !s.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
