import Foundation
import CFreeRDP
import XCTest

@testable import AppCore

final class RdpSessionTransportTests: XCTestCase {
  func testHostnameMismatchIsNotAChangedCertificate() {
    XCTAssertFalse(FreeRdpClient.isChangedCertificate(flags: UInt32(VERIFY_CERT_FLAG_MISMATCH)))
    XCTAssertTrue(FreeRdpClient.isChangedCertificate(flags: UInt32(VERIFY_CERT_FLAG_CHANGED)))
    XCTAssertTrue(FreeRdpClient.isChangedCertificate(flags: UInt32(VERIFY_CERT_FLAG_CHANGED | VERIFY_CERT_FLAG_MISMATCH)))
  }
  func testInvalidEndpointFailsBeforeAnyNetworkOrSecretAccess() async throws {
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "", username: "Administrator", credentialRefID: "credential"),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver()
    )
    do {
      try await session.connect()
      XCTFail("Empty host must not connect")
    } catch {
      guard case .invalidEndpoint = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
  }

  /// Connection to a closed loopback port fails without ever reaching trust or credentials.
  func testConnectionFailureNeverVerifiesCertificateOrResolvesCredentials() async throws {
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "127.0.0.1", port: 1, username: "Administrator", credentialRefID: "credential"),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver()
    )
    do {
      try await session.connect()
      XCTFail("Closed port must not connect")
    } catch {
      XCTAssertTrue(error is RdpSessionError, "\(error)")
    }
    guard case .failed = session.state else { return XCTFail("state \(session.state)") }
  }

  func testRejectCertificateWithoutChallengeIsTerminal() async throws {
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "windows.example", username: "u", credentialRefID: nil),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver()
    )
    session.rejectCertificate()
    XCTAssertEqual(session.state, .disconnected(reason: .certificateRejected))
    do {
      try await session.confirmTrustAndAuthenticate()
      XCTFail("No challenge to confirm")
    } catch {
      guard case .protocolViolation = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
  }

  func testFingerprintFromPEMIsSHA256OfDER() throws {
    let der = Data([0x30, 0x03, 0x02, 0x01, 0x05])
    let pem = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n-----END CERTIFICATE-----\n"
    let expected = RdpCertificateFingerprint.sha256Hex(ofDER: der)
    XCTAssertEqual(expected.count, 64)
    XCTAssertEqual(RdpCertificateFingerprint.fingerprint(from: pem, isPEM: true), expected)
    XCTAssertNil(RdpCertificateFingerprint.fingerprint(from: "garbage", isPEM: true))
    // Known vector: SHA-256 of empty input.
    XCTAssertEqual(
      RdpCertificateFingerprint.sha256Hex(ofDER: Data()),
      "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
  }

  func testLegacyFingerprintNormalizationAndFormatting() throws {
    let hex = String(repeating: "ab", count: 32)
    let colon = (0..<32).map { _ in "ab" }.joined(separator: ":")
    XCTAssertEqual(RdpCertificateFingerprint.normalizedHex("sha256:" + colon), hex.uppercased())
    XCTAssertEqual(RdpCertificateFingerprint.normalizedHex(hex), hex.uppercased())
    XCTAssertNil(RdpCertificateFingerprint.normalizedHex("sha1:" + String(repeating: "ab", count: 20)))
    XCTAssertNil(RdpCertificateFingerprint.normalizedHex(String(repeating: "zz", count: 32)))
    let record = RdpCertificateRecord(host: "h", port: 3389, sha256Fingerprint: hex, subjectCN: "s", issuerCN: "i")
    XCTAssertEqual(record.formattedFingerprint, colon.uppercased())
  }

  func testPointerFlagMappingAndErrorMapping() {
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x01), 0x9000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x02), 0x1000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x04), 0xA000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x08), 0x2000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x09), 0xC000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x0A), 0x4000)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x00), 0x0800)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x10), 0x0278)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x20), 0x0388)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x40), 0x0478)
    XCTAssertEqual(RdpPointerFlags.rdpFlags(forButtonFlags: 0x80), 0x0588)
    XCTAssertEqual(mapFreeRdpError(code: 0x0002_0015, message: "m").1, .authenticationFailed)
    XCTAssertEqual(mapFreeRdpError(code: 0x0002_0004, message: "m").0, .dnsResolutionFailed("m"))
  }

  func testGracefulDisconnect() async throws {
    let repo = InMemoryRdpHostTrustRepository()
    let verifier = NativeRdpCertificateTrustService(repository: repo)
    let resolver = RdpCredentialResolver { _ in nil }

    let config = RdpSessionConfiguration(
      host: "desktop.internal",
      port: 3389,
      username: "Administrator",
      credentialRefID: nil
    )

    let session = NativeRdpSession(
      configuration: config,
      certificateVerifier: verifier,
      credentialResolver: resolver
    )

    session.onFrameReady = { _ in XCTFail("Closed session must not forward stale frames") }
    await session.disconnect()
    XCTAssertEqual(session.state, .disconnected(reason: .userInitiated))
    XCTAssertNil(session.onFrameReady)
  }
}

struct UnusedCertificateVerifier: RdpHostCertificateVerifier {
  func evaluateTrust(host: String, port: Int, presented: RdpCertificateRecord) async throws -> RdpHostTrustStatus {
    XCTFail("Transport must not touch this before trust")
    throw RdpSessionError.unavailable
  }
  func approveChallenge(_ challenge: RdpCertificateTrustChallenge) async throws {
    XCTFail("Transport must not touch this before trust")
  }
  func revokeTrust(host: String, port: Int) async throws { XCTFail("Unexpected trust mutation") }
  func listTrustedCertificates() async throws -> [RdpCertificateRecord] {
    XCTFail("Unexpected trust lookup")
    return []
  }
}

struct UnusedCredentialResolver: RdpCredentialResolving {
  func resolveCredentials(rawUsername: String, credentialRefID: String?) throws -> RdpResolvedCredentials {
    XCTFail("Transport must not touch this before trust")
    throw RdpSessionError.unavailable
  }
  func parseUsernameAndDomain(from raw: String) -> (username: String, domain: String?) {
    XCTFail("Transport must not touch this before trust")
    return (raw, nil)
  }
}
