import Foundation
import XCTest

@testable import AppCore

final class RdpHostCertificateTrustTests: XCTestCase {
  func testHostAndPortValidation() throws {
    XCTAssertEqual(try NativeRdpCertificateTrustService.validateHost("win-server.local"), "win-server.local")
    XCTAssertEqual(try NativeRdpCertificateTrustService.validateHost("  192.168.1.100  "), "192.168.1.100")
    XCTAssertEqual(try NativeRdpCertificateTrustService.validatePort(3389), 3389)
    XCTAssertEqual(try NativeRdpCertificateTrustService.validatePort(1), 1)
    XCTAssertEqual(try NativeRdpCertificateTrustService.validatePort(65535), 65535)

    // Negative cases
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateHost(""))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateHost("   "))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateHost("-invalid"))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateHost("host;rm -rf /"))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateHost("host*pattern"))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validatePort(0))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validatePort(65536))
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validatePort(-1))
  }

  func testFingerprintValidationAndFormatting() throws {
    let validHex = "A1B2C3D4E5F67890123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0"
    let validated = try NativeRdpCertificateTrustService.validateFingerprint(validHex)
    XCTAssertEqual(validated, validHex)

    // With colons and lowercase
    let colonFormatted = "a1:b2:c3:d4:e5:f6:78:90:12:34:56:78:9a:bc:de:f0:12:34:56:78:9a:bc:de:f0:12:34:56:78:9a:bc:de:f0"
    let clean = try NativeRdpCertificateTrustService.validateFingerprint(colonFormatted)
    XCTAssertEqual(clean, validHex)

    // Invalid length
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateFingerprint("A1B2C3"))
    // Non-hex characters
    XCTAssertThrowsError(try NativeRdpCertificateTrustService.validateFingerprint(
      "Z1B2C3D4E5F67890123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0"
    ))

    let record = RdpCertificateRecord(
      host: "win-01.corp",
      port: 3389,
      sha256Fingerprint: validHex,
      subjectCN: "win-01.corp",
      issuerCN: "Corp CA"
    )
    XCTAssertTrue(record.formattedFingerprint.contains(":"))
    XCTAssertEqual(record.formattedFingerprint.filter { $0 != ":" }, validHex)
  }

  func testTOFUWorkflowAndApproval() async throws {
    let repo = InMemoryRdpHostTrustRepository()
    let service = NativeRdpCertificateTrustService(repository: repo)

    let cert = RdpCertificateRecord(
      host: "10.0.0.5",
      port: 3389,
      sha256Fingerprint: "1122334455667788990011223344556677889900112233445566778899001122",
      subjectCN: "Windows-Desktop",
      issuerCN: "Windows-Desktop"
    )

    // Step 1: First connect -> unknown (TOFU challenge)
    let status1 = try await service.evaluateTrust(host: "10.0.0.5", port: 3389, presented: cert)
    guard case .unknown(let challenge) = status1 else {
      XCTFail("Expected .unknown challenge on first connect")
      return
    }
    XCTAssertEqual(challenge.host, "10.0.0.5")
    XCTAssertEqual(challenge.presentedCertificate.sha256Fingerprint, cert.sha256Fingerprint)

    // Step 2: Approve challenge -> persisted
    try await service.approveChallenge(challenge)

    // Step 3: Second connect -> trusted
    let status2 = try await service.evaluateTrust(host: "10.0.0.5", port: 3389, presented: cert)
    guard case .trusted(let matched) = status2 else {
      XCTFail("Expected .trusted after approval")
      return
    }
    XCTAssertEqual(matched.sha256Fingerprint, cert.sha256Fingerprint)

    // Step 4: List trusted certificates
    let trustedList = try await service.listTrustedCertificates()
    XCTAssertEqual(trustedList.count, 1)
    XCTAssertEqual(trustedList.first?.host, "10.0.0.5")

    // Step 5: Revoke trust
    try await service.revokeTrust(host: "10.0.0.5", port: 3389)
    let trustedAfterRevoke = try await service.listTrustedCertificates()
    XCTAssertTrue(trustedAfterRevoke.isEmpty)
  }

  func testCertificateMismatchHardBlock() async throws {
    let repo = InMemoryRdpHostTrustRepository()
    let service = NativeRdpCertificateTrustService(repository: repo)

    let originalCert = RdpCertificateRecord(
      host: "secure-server.internal",
      port: 3389,
      sha256Fingerprint: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      subjectCN: "secure-server",
      issuerCN: "Internal CA"
    )

    // Pre-record trust
    let status = try await service.evaluateTrust(host: "secure-server.internal", port: 3389, presented: originalCert)
    if case .unknown(let challenge) = status {
      try await service.approveChallenge(challenge)
    }

    // Now adversary or changed cert presents different fingerprint
    let rogueCert = RdpCertificateRecord(
      host: "secure-server.internal",
      port: 3389,
      sha256Fingerprint: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
      subjectCN: "secure-server",
      issuerCN: "Untrusted CA"
    )

    let mismatchStatus = try await service.evaluateTrust(
      host: "secure-server.internal",
      port: 3389,
      presented: rogueCert
    )

    guard case .mismatch(let recorded, let presented) = mismatchStatus else {
      XCTFail("Expected .mismatch hard block on changed certificate fingerprint")
      return
    }
    XCTAssertEqual(recorded.sha256Fingerprint, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    XCTAssertEqual(presented.sha256Fingerprint, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
  }
}
