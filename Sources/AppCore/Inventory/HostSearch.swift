import Foundation

/// Pure host filtering (FR-003): case-insensitive, all criteria combine with AND.
/// `query` matches name/address/environment/workspace/group/tag/protocol; `tag` and `protocolName` are exact filters.
public enum HostSearch {
  public static func filter(
    _ hosts: [HostRecord],
    query: String = "",
    tag: String? = nil,
    protocolName: String? = nil,
    workspaceNames: [String: String] = [:],
    groupNames: [String: String] = [:]
  ) -> [HostRecord] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let tagKey = tag?.lowercased()
    let protoKey = protocolName?.lowercased()
    guard !q.isEmpty || tagKey != nil || protoKey != nil else { return hosts }
    let ci = { (s: String) in s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    return hosts.filter { h in
      if let tagKey, !h.tags.contains(where: { $0.lowercased() == tagKey }) { return false }
      if let protoKey, !h.protocols.contains(where: { $0.lowercased() == protoKey }) { return false }
      guard !q.isEmpty else { return true }
      return ci(h.displayName) || ci(h.address) || ci(h.environment.title) || ci(h.environment.rawValue)
        || ci(workspaceNames[h.workspaceID] ?? "") || ci(h.groupID.flatMap { groupNames[$0] } ?? "")
        || h.tags.contains(where: ci) || h.protocols.contains(where: ci)
    }
  }
}
