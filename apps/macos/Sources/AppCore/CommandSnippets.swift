import Foundation

public enum CommandSnippetScope: Equatable, Sendable {
  case host(String)
  case group(String)

  public var ownerID: String {
    switch self {
    case .host(let id), .group(let id): id
    }
  }

  public func includes(hostID: String, groupID: String?) -> Bool {
    switch self {
    case .host(let scopedHostID): scopedHostID == hostID
    case .group(let scopedGroupID): scopedGroupID == groupID
    }
  }
}

public struct CommandSnippetDraft: Equatable, Sendable {
  public let title: String
  public let commandText: String
  public let scope: CommandSnippetScope

  public init(title: String, commandText: String, scope: CommandSnippetScope) {
    self.title = title
    self.commandText = commandText
    self.scope = scope
  }

  public func validated() throws -> Self {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw CommandSnippetValidationError.emptyTitle }
    guard title.unicodeScalars.count <= 80 else { throw CommandSnippetValidationError.titleTooLong }
    guard !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw CommandSnippetValidationError.invalidTitle
    }

    guard !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommandSnippetValidationError.emptyCommand
    }
    guard commandText.utf8.count <= 8_192 else { throw CommandSnippetValidationError.commandTooLong }
    guard commandText.unicodeScalars.allSatisfy({ scalar in
      !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
    }) else {
      throw CommandSnippetValidationError.invalidCommand
    }
    guard !Self.containsLikelyCredentialLiteral(commandText) else {
      throw CommandSnippetValidationError.possibleSecret
    }

    let ownerID = scope.ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ownerID.isEmpty else { throw CommandSnippetValidationError.invalidScope }
    let normalizedScope: CommandSnippetScope
    switch scope {
    case .host: normalizedScope = .host(ownerID)
    case .group: normalizedScope = .group(ownerID)
    }

    return Self(
      title: title,
      commandText: commandText,
      scope: normalizedScope
    )
  }

  private static func containsLikelyCredentialLiteral(_ commandText: String) -> Bool {
    let patterns = [
      #"(?i)\b(?:password|passwd|(?:api[_-]?)?token|api[_-]?key|secret|client[_-]?secret|access[_-]?key)\s*[:=]\s*['\"]?([^\s'\"]+)"#,
      #"(?i)\b(?:proxy-)?authorization\s*:\s*(?:bearer|basic)\s+([^\s'\"]+)"#,
      #"(?i)--(?:password|passwd|token|secret|api-key)(?:=|\s+)([^\s]+)"#,
      #"(?:https?|ssh)://[^/\s:@]+:[^@\s/]+@"#,
      #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#,
      #"(?i)\b(?:sk_live_|sk_test_|ghp_|gho_|github_pat_|AKIA)[A-Za-z0-9_./+-]{12,}"#,
    ]
    let source = commandText as NSString
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = expression.matches(in: commandText, range: NSRange(location: 0, length: source.length))
      for match in matches {
        guard match.numberOfRanges > 1 else { return true }
        let value = source.substring(with: match.range(at: 1))
        if !value.hasPrefix("$") { return true }
      }
    }
    return false
  }
}

public struct CommandSnippetRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let commandText: String
  public let scope: CommandSnippetScope
  public let version: Int64

  public init(id: String, title: String, commandText: String, scope: CommandSnippetScope, version: Int64) {
    self.id = id
    self.title = title
    self.commandText = commandText
    self.scope = scope
    self.version = version
  }
}

public protocol CommandSnippetRepository: AnyObject {
  func listCommandSnippets(hostID: String, groupID: String?) throws -> [CommandSnippetRecord]
  func createCommandSnippet(_ draft: CommandSnippetDraft) throws -> CommandSnippetRecord
  func updateCommandSnippet(
    id: String, expectedVersion: Int64, draft: CommandSnippetDraft
  ) throws -> CommandSnippetRecord
  func deleteCommandSnippet(id: String, expectedVersion: Int64) throws
}

public enum CommandSnippetValidationError: Error, Equatable, AppCoreLocalizedError {
  case emptyTitle
  case titleTooLong
  case invalidTitle
  case emptyCommand
  case commandTooLong
  case invalidCommand
  case possibleSecret
  case invalidScope

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .emptyTitle: AppCoreLocalization.string("Enter a snippet name.", locale: locale)
    case .titleTooLong: AppCoreLocalization.string("Snippet names must be 80 characters or fewer.", locale: locale)
    case .invalidTitle: AppCoreLocalization.string("Snippet names cannot contain control characters.", locale: locale)
    case .emptyCommand: AppCoreLocalization.string("Enter command text.", locale: locale)
    case .commandTooLong: AppCoreLocalization.string("Snippet commands must be 8 KB or smaller.", locale: locale)
    case .invalidCommand: AppCoreLocalization.string("Command text contains an unsupported control character.", locale: locale)
    case .possibleSecret: AppCoreLocalization.string("Remove password, token, or key material before saving this snippet.", locale: locale)
    case .invalidScope: AppCoreLocalization.string("Choose a valid host or group scope.", locale: locale)
    }
  }
}

public struct CommandSnippetExecutionTarget: Equatable, Sendable {
  public let hostID: String
  public let groupID: String?
  public let displayName: String
  public let address: String
  public let environment: HostEnvironment

  public init(
    hostID: String, groupID: String?, displayName: String, address: String,
    environment: HostEnvironment
  ) {
    self.hostID = hostID
    self.groupID = groupID
    self.displayName = displayName
    self.address = address
    self.environment = environment
  }

  public var displayLabel: String {
    displayLabel(locale: nil)
  }

  public func displayLabel(locale: Locale?) -> String {
    AppCoreLocalization.format(
      "%1$@ (%2$@) — %3$@", displayName, address, environment.localizedTitle(locale: locale), locale: locale)
  }
}

public struct CommandSnippetReview: Equatable, Identifiable, Sendable {
  public let snippet: CommandSnippetRecord
  public let target: CommandSnippetExecutionTarget
  public let commandPayload: String

  public var id: String { "\(snippet.id):\(target.hostID):\(snippet.version)" }

  public init(snippet: CommandSnippetRecord, target: CommandSnippetExecutionTarget) {
    self.snippet = snippet
    self.target = target
    commandPayload = snippet.commandText.hasSuffix("\n") ? snippet.commandText : snippet.commandText + "\n"
  }
}

public enum CommandSnippetSendError: Error, Equatable, AppCoreLocalizedError {
  case scopeDoesNotMatchTarget
  case noPendingReview
  case reviewIsStale
  case targetChanged
  case sessionNotActive
  case invalidSnippet

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .scopeDoesNotMatchTarget: AppCoreLocalization.string("This snippet is not scoped to the selected host or group.", locale: locale)
    case .noPendingReview: AppCoreLocalization.string("Review the snippet before sending it.", locale: locale)
    case .reviewIsStale: AppCoreLocalization.string("The snippet changed after it was reviewed. Review it again before sending.", locale: locale)
    case .targetChanged: AppCoreLocalization.string("The active host changed after review. Review the snippet again.", locale: locale)
    case .sessionNotActive: AppCoreLocalization.string("Connect to the reviewed host before sending this snippet.", locale: locale)
    case .invalidSnippet: AppCoreLocalization.string("This snippet contains invalid text and cannot be sent.", locale: locale)
    }
  }
}

/// Stores a previewed command and permits one send only after an explicit confirmation.
public struct CommandSnippetSendGate: Sendable {
  private var pendingReview: CommandSnippetReview?

  public init() {}

  @discardableResult
  public mutating func preview(
    snippet: CommandSnippetRecord, target: CommandSnippetExecutionTarget
  ) throws -> CommandSnippetReview {
    guard let validated = try? CommandSnippetDraft(
      title: snippet.title, commandText: snippet.commandText, scope: snippet.scope
    ).validated(), validated.title == snippet.title, validated.commandText == snippet.commandText else {
      pendingReview = nil
      throw CommandSnippetSendError.invalidSnippet
    }
    guard snippet.scope.includes(hostID: target.hostID, groupID: target.groupID) else {
      pendingReview = nil
      throw CommandSnippetSendError.scopeDoesNotMatchTarget
    }
    let review = CommandSnippetReview(snippet: snippet, target: target)
    pendingReview = review
    return review
  }

  public mutating func confirm(
    snippet: CommandSnippetRecord,
    target: CommandSnippetExecutionTarget,
    sessionIsActive: Bool,
    send: (String) -> Void
  ) throws {
    guard let pendingReview else { throw CommandSnippetSendError.noPendingReview }
    guard pendingReview.snippet == snippet else {
      self.pendingReview = nil
      throw CommandSnippetSendError.reviewIsStale
    }
    guard pendingReview.target == target else {
      self.pendingReview = nil
      throw CommandSnippetSendError.targetChanged
    }
    guard sessionIsActive else { throw CommandSnippetSendError.sessionNotActive }

    self.pendingReview = nil
    send(pendingReview.commandPayload)
  }

  public mutating func cancel() {
    pendingReview = nil
  }
}
