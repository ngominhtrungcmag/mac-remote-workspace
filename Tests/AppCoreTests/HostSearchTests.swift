import XCTest
@testable import AppCore

final class HostSearchTests: XCTestCase {
  private func host(_ i: Int, name: String, addr: String = "10.0.0.1", env: HostEnvironment = .development,
                    tags: [String] = [], protocols: [String] = ["ssh"]) -> HostRecord {
    HostRecord(id: "h\(i)", workspaceID: "w", displayName: name, address: addr, environment: env,
               version: 1, tags: tags, protocols: protocols)
  }

  func testCorrectness() {
    let hosts = [
      host(1, name: "Web-Prod", addr: "web.example.com", env: .production, tags: ["Frontend"]),
      host(2, name: "db-dev", env: .development, tags: ["database", "frontend"], protocols: ["ssh", "rdp"]),
      host(3, name: "Win Box", env: .staging, protocols: ["rdp"]),
    ]
    func ids(_ r: [HostRecord]) -> [String] { r.map(\.id) }
    XCTAssertEqual(ids(HostSearch.filter(hosts, query: "  WEB ")), ["h1"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, query: "example.COM")), ["h1"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, query: "staging")), ["h3"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, query: "DATABASE")), ["h2"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, tag: "FRONTEND")), ["h1", "h2"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, protocolName: "RDP")), ["h2", "h3"])
    XCTAssertEqual(ids(HostSearch.filter(hosts, query: "db", tag: "frontend", protocolName: "rdp")), ["h2"])
    XCTAssertTrue(HostSearch.filter(hosts, query: "web", protocolName: "rdp").isEmpty)
    XCTAssertEqual(HostSearch.filter(hosts, query: " ").count, 3)
  }

  func testWorkspaceAndGroupNamesMatch() {
    let h = HostRecord(id: "h", workspaceID: "w", groupID: "g", displayName: "x", address: "y",
                       environment: .development, version: 1)
    XCTAssertEqual(HostSearch.filter([h], query: "alpha", workspaceNames: ["w": "Alpha"]).count, 1)
    XCTAssertEqual(HostSearch.filter([h], query: "ops", groupNames: ["g": "Ops"]).count, 1)
  }

  func testPerformance10kHosts() {
    let envs = HostEnvironment.allCases
    let hosts = (0..<10_000).map {
      host($0, name: "server-\($0)", addr: "10.\($0 / 256).\($0 % 256).1", env: envs[$0 % 3],
           tags: ["tag\($0 % 50)"], protocols: $0 % 2 == 0 ? ["ssh"] : ["ssh", "rdp"])
    }
    let start = Date()
    let r = HostSearch.filter(hosts, query: "SERVER-99", tag: "tag49", protocolName: "ssh")
    let r2 = HostSearch.filter(hosts, query: "zzz-no-match")
    let elapsed = Date().timeIntervalSince(start)
    print("HostSearch 10k filter x2: \(elapsed * 1000) ms")
    XCTAssertEqual(r.count, 4)
    XCTAssertTrue(r2.isEmpty)
    XCTAssertLessThan(elapsed, 1.0)
    measure { _ = HostSearch.filter(hosts, query: "server-99") }
  }
}
