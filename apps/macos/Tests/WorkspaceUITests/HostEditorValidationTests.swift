import AppCore
import AppKit
import SwiftUI
import XCTest
@testable import MacRemoteWorkspace

final class HostEditorValidationTests: XCTestCase {
  func testUsernameIsRequiredOnlyWhenSSHEnabledAndInvalidFieldsAreIdentified() {
    let base = HostEditorValidation.errors(name: "Host", address: "example.test", tags: "prod, web",
      sshEnabled: false, username: "", sshPort: "bad", proxyJump: "bad;input",
      rdpEnabled: true, rdpUsername: "", rdpPort: "3389", hasRdpCredential: false)
    XCTAssertTrue(base.isEmpty)
    let errors = HostEditorValidation.errors(name: "", address: "bad host", tags: "prod",
      sshEnabled: true, username: "", sshPort: "0", proxyJump: "bad;input",
      rdpEnabled: false, rdpUsername: "", rdpPort: "bad", hasRdpCredential: false)
    XCTAssertEqual(Set(errors.keys), Set([.name, .address, .sshUsername, .sshPort, .proxyJump]))
    XCTAssertEqual(HostEditorValidation.tags(" prod, web, , db "), ["prod", "web", "db"])
  }

  func testSSHConfigSelectionExcludesExistingAndUncheckedAliases() {
    let existing = ImportedHostDraft(workspaceName: "Local", groupName: nil, displayName: "old", address: "old.test", environment: .development)
    let first = ImportedHostDraft(workspaceName: "Local", groupName: nil, displayName: "first", address: "one.test", environment: .development)
    let second = ImportedHostDraft(workspaceName: "Local", groupName: nil, displayName: "second", address: "two.test", environment: .development)
    let conflict = ImportConflict(workspaceName: "Local", displayName: "old", address: "old.test", existingDisplayName: "old", existingAddress: "old.test")
    let preview = InventoryImportPreview(totalHostsInFile: 3, workspaces: [], groups: [], hosts: [existing, first, second], conflicts: [conflict], validationErrors: [])
    let selection = SSHConfigImportSelection(preview: preview)
    XCTAssertEqual(selection.initialSelection, ["first", "second"])
    XCTAssertEqual(selection.selected(["old", "second"]).map(\.displayName), ["second"])
    let acrossWorkspaces = SSHConfigImportSelection(preview: preview, existingNames: ["SECOND"])
    XCTAssertEqual(acrossWorkspaces.initialSelection, ["first"])
  }

  @MainActor
  func testEmptyInventoryFitsWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let store = WorkspaceStore(repository: repository)
    let content = NativeInventoryView(store: store, selectedScope: .all, activeSheet: .constant(nil),
      deleteTarget: .constant(nil), operationError: .constant(nil)).frame(width: 900, height: 600)
    let view = NSHostingView(rootView: content)
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    XCTAssertEqual(view.fittingSize.width, 900, accuracy: 1)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: "/tmp/mrw-empty-inventory.png"))
  }
}
