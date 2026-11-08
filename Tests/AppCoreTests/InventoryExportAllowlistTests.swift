import XCTest
@testable import AppCore

final class InventoryExportAllowlistTests: XCTestCase {
  func testExportRejectsUnknownAndSecretFields() throws {
    let base: [String: Any] = ["schema_version": 1, "generated_at": "now", "workspaces": [], "groups": [], "hosts": [], "secrets_included": false]
    try InventoryImportExportService.validateExportFields(JSONSerialization.data(withJSONObject: base))
    let allowed: [String: Any] = ["id": "1", "ssh_settings": ["username": "user", "port": 22, "auth": "sshAgent", "keyFilePath": ""],
      "profiles": [["protocol": "rdp", "port": 3389, "username": "user", "auth_method": "external"]],
      "snippets": [["title": "Status", "command": "uptime"]], "tags": ["prod"], "protocols": ["ssh", "rdp"]]
    var v2 = base
    v2["schema_version"] = 2
    v2["hosts"] = [allowed]
    try InventoryImportExportService.validateExportFields(JSONSerialization.data(withJSONObject: v2))
    for nested in ["ssh_settings", "profiles", "snippets"] {
      var modified = allowed
      modified[nested] = nested == "ssh_settings" ? ["password": "secret"] : [["password": "secret"]]
      v2["hosts"] = [modified]
      XCTAssertThrowsError(try InventoryImportExportService.validateExportFields(JSONSerialization.data(withJSONObject: v2)))
    }
    for key in ["password", "unknown"] {
      var modified = base
      modified["hosts"] = [["id": "1", key: "value"]]
      XCTAssertThrowsError(try InventoryImportExportService.validateExportFields(JSONSerialization.data(withJSONObject: modified)))
    }
  }
}
