import Foundation

// MARK: - Export Documents (FR-014, US-004, TC-012)

public struct ExportedWorkspace: Codable, Sendable, Equatable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ExportedSnippet: Codable, Sendable, Equatable {
  public let title: String
  public let command: String
  public init(title: String, command: String) { self.title = title; self.command = command }
}

public struct ExportedProfile: Codable, Sendable, Equatable {
  public let protocolName: String
  public let port: Int
  public let username: String
  public let authMethod: String
  public let keyPath: String?
  enum CodingKeys: String, CodingKey {
    case protocolName = "protocol", port, username
    case authMethod = "auth_method", keyPath = "key_path"
  }
  public init(protocolName: String, port: Int, username: String, authMethod: String, keyPath: String? = nil) {
    self.protocolName = protocolName; self.port = port; self.username = username
    self.authMethod = authMethod; self.keyPath = keyPath
  }
}

public struct ExportedGroup: Codable, Sendable, Equatable {
  public let id: String
  public let workspaceId: String
  public let name: String
  public let snippets: [ExportedSnippet]?

  enum CodingKeys: String, CodingKey {
    case snippets
    case id
    case workspaceId = "workspace_id"
    case name
  }

  public init(id: String, workspaceId: String, name: String, snippets: [ExportedSnippet]? = nil) {
    self.id = id
    self.workspaceId = workspaceId
    self.name = name
    self.snippets = snippets
  }
}

public struct ExportedHost: Codable, Sendable, Equatable {
  public let id: String
  public let workspaceId: String
  public let groupId: String?
  public let displayName: String
  public let address: String
  public let environment: String
  public let tags: [String]?
  public let profiles: [ExportedProfile]?
  public let protocols: [String]?
  public let sshSettings: SSHConnectionSettings?
  public let snippets: [ExportedSnippet]?

  enum CodingKeys: String, CodingKey {
    case id
    case workspaceId = "workspace_id"
    case groupId = "group_id"
    case displayName = "display_name"
    case address
    case environment, tags, profiles, protocols, snippets
    case sshSettings = "ssh_settings"
  }

  public init(
    id: String,
    workspaceId: String,
    groupId: String?,
    displayName: String,
    address: String,
    environment: String, tags: [String]? = nil, profiles: [ExportedProfile]? = nil, protocols: [String]? = nil,
    sshSettings: SSHConnectionSettings? = nil, snippets: [ExportedSnippet]? = nil
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.groupId = groupId
    self.displayName = displayName
    self.address = address
    self.environment = environment
    self.tags = tags; self.profiles = profiles; self.protocols = protocols; self.sshSettings = sshSettings; self.snippets = snippets
  }
}

public struct InventoryExportDocument: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let generatedAt: String
  public let workspaces: [ExportedWorkspace]
  public let groups: [ExportedGroup]
  public let hosts: [ExportedHost]
  public let secretsIncluded: Bool

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case workspaces
    case groups
    case hosts
    case secretsIncluded = "secrets_included"
  }

  public init(
    schemaVersion: Int = 1,
    generatedAt: String = ISO8601DateFormatter().string(from: Date()),
    workspaces: [ExportedWorkspace],
    groups: [ExportedGroup],
    hosts: [ExportedHost],
    secretsIncluded: Bool = false
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.workspaces = workspaces
    self.groups = groups
    self.hosts = hosts
    self.secretsIncluded = secretsIncluded
  }
}

// MARK: - Import Preview & Conflicts (TC-012)

public struct ImportConflict: Sendable, Equatable, Identifiable {
  public var id: String { "\(workspaceName):\(displayName)" }
  public let workspaceName: String
  public let displayName: String
  public let address: String
  public let existingDisplayName: String
  public let existingAddress: String

  public init(
    workspaceName: String,
    displayName: String,
    address: String,
    existingDisplayName: String,
    existingAddress: String
  ) {
    self.workspaceName = workspaceName
    self.displayName = displayName
    self.address = address
    self.existingDisplayName = existingDisplayName
    self.existingAddress = existingAddress
  }
}

public struct InventoryImportPreview: Sendable, Equatable {
  public let totalHostsInFile: Int
  public let workspaces: [ImportedWorkspaceDraft]
  public let groups: [ImportedGroupDraft]
  public let hosts: [ImportedHostDraft]
  public let conflicts: [ImportConflict]
  public let validationErrors: [String]

  public var canImport: Bool {
    !hosts.isEmpty && validationErrors.isEmpty
  }

  public init(
    totalHostsInFile: Int,
    workspaces: [ImportedWorkspaceDraft],
    groups: [ImportedGroupDraft],
    hosts: [ImportedHostDraft],
    conflicts: [ImportConflict],
    validationErrors: [String]
  ) {
    self.totalHostsInFile = totalHostsInFile
    self.workspaces = workspaces
    self.groups = groups
    self.hosts = hosts
    self.conflicts = conflicts
    self.validationErrors = validationErrors
  }
}

public enum InventoryImportExportError: AppCoreLocalizedError, Equatable {
  case unsupportedSchemaVersion(Int)
  case invalidJSON
  case duplicateIdentifier(String)
  case invalidCSV(String)
  case secretsDetectedInExport
  case emptyDocument

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .unsupportedSchemaVersion(let version):
      AppCoreLocalization.format("Unsupported schema version %1$@. This app supports versions 1 and 2.", String(version), locale: locale)
    case .invalidJSON:
      AppCoreLocalization.string("The import file is not valid JSON.", locale: locale)
    case .duplicateIdentifier(let kind):
      AppCoreLocalization.format("The import file contains duplicate %1$@ identifiers.", AppCoreLocalization.string(kind, locale: locale), locale: locale)
    case .invalidCSV(let detail):
      AppCoreLocalization.format("The import CSV file is invalid: %1$@", AppCoreLocalization.string(detail, locale: locale), locale: locale)
    case .secretsDetectedInExport:
      AppCoreLocalization.string("Export aborted: secrets or credentials detected in output.", locale: locale)
    case .emptyDocument:
      AppCoreLocalization.string("The file contains no host records to import.", locale: locale)
    }
  }
}

// MARK: - Inventory Import/Export Service

public enum InventoryImportExportService {

  // MARK: - Export

  /// Serializes the entire inventory into a versioned, secret-free JSON document per ADR/data-model specs.
  public static func exportToJSON(repository: HostRepository) throws -> Data {
    let doc = try buildExportDocument(repository: repository)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(doc)
    RedactedLogger.shared.info("export", "inventory export JSON")

    try validateExportFields(data)
    return data
  }

  static func validateExportFields(_ data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(root.keys).isSubset(of: ["schema_version", "generated_at", "workspaces", "groups", "hosts", "secrets_included"]),
          root["secrets_included"] as? Bool == false else {
      throw InventoryImportExportError.secretsDetectedInExport
    }
    for (key, allowed) in [
      ("workspaces", Set(["id", "name"])),
      ("groups", Set(["id", "workspace_id", "name", "snippets"])),
      ("hosts", Set(["id", "workspace_id", "group_id", "display_name", "address", "environment", "tags", "profiles", "protocols", "ssh_settings", "snippets"]))
    ] {
      guard let records = root[key] as? [[String: Any]], records.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else {
        throw InventoryImportExportError.secretsDetectedInExport
      }
    }
    for key in ["groups", "hosts"] {
      for record in (root[key] as? [[String: Any]] ?? []) {
        if let value = record["snippets"] {
          guard let snippets = value as? [[String: Any]],
            snippets.allSatisfy({ Set($0.keys).isSubset(of: ["title", "command"]) }) else {
            throw InventoryImportExportError.secretsDetectedInExport
          }
        }
        if let value = record["profiles"] {
          guard let profiles = value as? [[String: Any]],
            profiles.allSatisfy({ Set($0.keys).isSubset(of: ["protocol", "port", "username", "auth_method", "key_path"]) }) else {
            throw InventoryImportExportError.secretsDetectedInExport
          }
        }
        if let value = record["ssh_settings"] {
          guard let settings = value as? [String: Any],
            Set(settings.keys).isSubset(of: ["username", "port", "auth", "credentialID", "keyFilePath", "proxyJump"]) else {
            throw InventoryImportExportError.secretsDetectedInExport
          }
        }
        if let protocols = record["protocols"], !(protocols is [String]) { throw InventoryImportExportError.secretsDetectedInExport }
        if let tags = record["tags"], !(tags is [String]) { throw InventoryImportExportError.secretsDetectedInExport }
      }
    }
  }

  /// Exports inventory as an RFC 4180 compliant CSV table.
  /// Columns: Workspace,Group,DisplayName,Address,Environment
  public static func exportToCSV(repository: HostRepository) throws -> String {
    let doc = try buildExportDocument(repository: repository)
    var lines: [String] = ["Workspace,Group,DisplayName,Address,Environment"]

    let workspaceMap = Dictionary(uniqueKeysWithValues: doc.workspaces.map { ($0.id, $0.name) })
    let groupMap = Dictionary(uniqueKeysWithValues: doc.groups.map { ($0.id, $0.name) })

    for host in doc.hosts {
      let wsName = workspaceMap[host.workspaceId] ?? "Local"
      let grpName = host.groupId.flatMap { groupMap[$0] } ?? ""
      let row = [
        escapeCSVField(wsName),
        escapeCSVField(grpName),
        escapeCSVField(host.displayName),
        escapeCSVField(host.address),
        escapeCSVField(host.environment)
      ].joined(separator: ",")
      lines.append(row)
    }

    return lines.joined(separator: "\r\n") + "\r\n"
  }

  private static func buildExportDocument(repository: HostRepository) throws -> InventoryExportDocument {
    let rawWorkspaces = try repository.listWorkspaces()
    var rawGroups: [HostGroupRecord] = []
    for ws in rawWorkspaces {
      rawGroups += try repository.listGroups(workspaceID: ws.id)
    }
    let rawHosts = try repository.listHosts()

    let expWorkspaces = rawWorkspaces.map { ExportedWorkspace(id: $0.id, name: $0.name) }
    let sqlite = repository as? SQLiteHostRepository
    let expGroups = try rawGroups.map { group in
      ExportedGroup(id: group.id, workspaceId: group.workspaceID, name: group.name,
        snippets: try sqlite?.exportedSnippets(hostID: nil, groupID: group.id))
    }
    let expHosts = try rawHosts.map {
      ExportedHost(
        id: $0.id,
        workspaceId: $0.workspaceID,
        groupId: $0.groupID,
        displayName: $0.displayName,
        address: $0.address,
        environment: $0.environment.rawValue, tags: $0.tags,
        profiles: try sqlite?.exportedProfiles(hostID: $0.id), protocols: $0.protocols,
        sshSettings: try sqlite?.sshConnectionSettings(hostID: $0.id),
        snippets: try sqlite?.exportedSnippets(hostID: $0.id, groupID: nil)
      )
    }

    return InventoryExportDocument(
      schemaVersion: 2,
      workspaces: expWorkspaces,
      groups: expGroups,
      hosts: expHosts,
      secretsIncluded: false
    )
  }

  // MARK: - Import Preview (Dry-Run)

  /// Generates a dry-run preview of JSON import data without mutating database.
  public static func previewJSON(data: Data, repository: HostRepository) throws -> InventoryImportPreview {
    let decoder = JSONDecoder()
    guard let doc = try? decoder.decode(InventoryExportDocument.self, from: data) else {
      throw InventoryImportExportError.invalidJSON
    }

    guard (1...2).contains(doc.schemaVersion) else {
      throw InventoryImportExportError.unsupportedSchemaVersion(doc.schemaVersion)
    }

    guard !doc.secretsIncluded else { throw InventoryImportExportError.secretsDetectedInExport }
    guard Set(doc.hosts.map(\.id)).count == doc.hosts.count else {
      throw InventoryImportExportError.duplicateIdentifier("host")
    }
    var wsMap: [String: String] = [:]
    for workspace in doc.workspaces {
      guard wsMap.updateValue(workspace.name, forKey: workspace.id) == nil else {
        throw InventoryImportExportError.duplicateIdentifier("workspace")
      }
    }
    var grpMap: [String: (String, String)] = [:]
    for group in doc.groups {
      guard grpMap.updateValue((group.name, wsMap[group.workspaceId] ?? "Local"), forKey: group.id) == nil else {
        throw InventoryImportExportError.duplicateIdentifier("group")
      }
    }

    let wsDrafts: [ImportedWorkspaceDraft] = doc.workspaces.map { ImportedWorkspaceDraft(name: $0.name) }
    let grpDrafts: [ImportedGroupDraft] = doc.groups.compactMap { grp in
      guard let wsName = wsMap[grp.workspaceId] else { return nil }
      return ImportedGroupDraft(workspaceName: wsName, name: grp.name, snippets: grp.snippets)
    }

    var hostDrafts: [ImportedHostDraft] = []
    var validationErrors: [String] = []

    for host in doc.hosts {
      guard let env = HostEnvironment(rawValue: host.environment.lowercased()) else {
        validationErrors.append("Host '\(host.displayName)' has unknown environment '\(host.environment)'.")
        continue
      }
      let wsName = wsMap[host.workspaceId] ?? "Local"
      let grpName = host.groupId.flatMap { grpMap[$0]?.0 }

      hostDrafts.append(ImportedHostDraft(
        workspaceName: wsName,
        groupName: grpName,
        displayName: host.displayName,
        address: host.address,
        environment: env, tags: host.tags, profiles: host.profiles, protocols: host.protocols, sshSettings: host.sshSettings.map { var s = $0; s.credentialID = nil; return s },  // credential IDs are per-machine
        snippets: host.snippets
      ))
    }

    return try computePreview(
      totalHostsInFile: doc.hosts.count,
      workspaces: wsDrafts,
      groups: grpDrafts,
      hosts: hostDrafts,
      validationErrors: validationErrors,
      repository: repository
    )
  }

  /// Generates a dry-run preview of CSV import text without mutating database.
  public static func previewCSV(text: String, repository: HostRepository) throws -> InventoryImportPreview {
    let rows = parseCSV(text)
    guard !rows.isEmpty else {
      throw InventoryImportExportError.invalidCSV("File is empty.")
    }

    // Expect header
    let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    guard header.contains("displayname") || header.contains("display_name") || header.contains("name"),
          header.contains("address") else {
      throw InventoryImportExportError.invalidCSV("Header must contain DisplayName and Address columns.")
    }

    let wsIdx = header.firstIndex(of: "workspace")
    let grpIdx = header.firstIndex(of: "group")
    let nameIdx = header.firstIndex(of: "displayname") ?? header.firstIndex(of: "display_name") ?? header.firstIndex(of: "name")!
    let addrIdx = header.firstIndex(of: "address")!
    let envIdx = header.firstIndex(of: "environment") ?? header.firstIndex(of: "env")

    var wsSet = Set<String>()
    var grpSet = Set<String>()
    var wsDrafts: [ImportedWorkspaceDraft] = []
    var grpDrafts: [ImportedGroupDraft] = []
    var hostDrafts: [ImportedHostDraft] = []
    var validationErrors: [String] = []

    for (lineIdx, row) in rows.dropFirst().enumerated() {
      // Skip blank rows
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }

      guard row.indices.contains(nameIdx), row.indices.contains(addrIdx) else {
        validationErrors.append("Line \(lineIdx + 2): Missing required columns.")
        continue
      }

      let displayName = row[nameIdx].trimmingCharacters(in: .whitespacesAndNewlines)
      let address = row[addrIdx].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !displayName.isEmpty, !address.isEmpty else {
        validationErrors.append("Line \(lineIdx + 2): DisplayName and Address cannot be empty.")
        continue
      }

      let wsName = wsIdx.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.flatMap { $0.isEmpty ? nil : $0 } ?? "Local"
      let grpName = grpIdx.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.flatMap { $0.isEmpty ? nil : $0 }

      let envStr = envIdx.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil } ?? "development"
      let env = HostEnvironment(rawValue: envStr) ?? .development

      if wsSet.insert(wsName.lowercased()).inserted {
        wsDrafts.append(ImportedWorkspaceDraft(name: wsName))
      }
      if let grp = grpName, grpSet.insert("\(wsName.lowercased()):\(grp.lowercased())").inserted {
        grpDrafts.append(ImportedGroupDraft(workspaceName: wsName, name: grp))
      }

      hostDrafts.append(ImportedHostDraft(
        workspaceName: wsName,
        groupName: grpName,
        displayName: displayName,
        address: address,
        environment: env
      ))
    }

    return try computePreview(
      totalHostsInFile: hostDrafts.count + validationErrors.count,
      workspaces: wsDrafts,
      groups: grpDrafts,
      hosts: hostDrafts,
      validationErrors: validationErrors,
      repository: repository
    )
  }

  static func computePreview(
    totalHostsInFile: Int,
    workspaces: [ImportedWorkspaceDraft],
    groups: [ImportedGroupDraft],
    hosts: [ImportedHostDraft],
    validationErrors: [String],
    repository: HostRepository
  ) throws -> InventoryImportPreview {
    let existingWorkspaces = try repository.listWorkspaces()
    let existingHosts = try repository.listHosts()

    var conflicts: [ImportConflict] = []

    for host in hosts {
      // Find matching workspace by name
      let wsMatch = existingWorkspaces.first { $0.name.caseInsensitiveCompare(host.workspaceName) == .orderedSame }
      if let ws = wsMatch {
        // Look for conflict in this workspace
        if let existing = existingHosts.first(where: {
          $0.workspaceID == ws.id && (
            (!host.matchAliasOnly && $0.address.caseInsensitiveCompare(host.address) == .orderedSame) ||
            $0.displayName.caseInsensitiveCompare(host.displayName) == .orderedSame
          )
        }) {
          conflicts.append(ImportConflict(
            workspaceName: host.workspaceName,
            displayName: host.displayName,
            address: host.address,
            existingDisplayName: existing.displayName,
            existingAddress: existing.address
          ))
        }
      }
    }

    return InventoryImportPreview(
      totalHostsInFile: totalHostsInFile,
      workspaces: workspaces,
      groups: groups,
      hosts: hosts,
      conflicts: conflicts,
      validationErrors: validationErrors
    )
  }

  // MARK: - CSV Helpers (RFC 4180)

  static func escapeCSVField(_ input: String) -> String {
    let value = input.first.map { "=+-@\t\r".contains($0) } == true ? "'" + input : input
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
      let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
      return "\"\(escaped)\""
    }
    return value
  }

  public static func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var currentRow: [String] = []
    var currentField = ""
    var inQuotes = false

    var index = text.startIndex
    while index < text.endIndex {
      let char = text[index]

      if inQuotes {
        if char == "\"" {
          let nextIndex = text.index(after: index)
          if nextIndex < text.endIndex && text[nextIndex] == "\"" {
            // Escaped quote
            currentField.append("\"")
            index = nextIndex
          } else {
            // Closing quote
            inQuotes = false
          }
        } else {
          currentField.append(char)
        }
      } else {
        if char == "\"" {
          inQuotes = true
        } else if char == "," {
          currentRow.append(currentField)
          currentField = ""
        } else if char.isNewline {
          currentRow.append(currentField)
          currentField = ""
          rows.append(currentRow)
          currentRow = []
        } else {
          currentField.append(char)
        }
      }
      index = text.index(after: index)
    }

    if !currentField.isEmpty || !currentRow.isEmpty {
      currentRow.append(currentField)
      rows.append(currentRow)
    }

    return rows
  }
}
