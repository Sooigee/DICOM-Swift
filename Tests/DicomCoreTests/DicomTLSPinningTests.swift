import XCTest
@testable import DicomCore

final class DicomTLSPinningTests: XCTestCase {

    func testPinsAreNormalisedToLowercaseHex() {
        // `openssl x509 -fingerprint -sha256` prints uppercase, so a digest
        // pasted straight from it has to match one captured from a handshake.
        let configuration = DicomTLSConfiguration(
            mode: .enabled,
            pinnedCertificateSHA256: ["8403D7253D1C8C65E15A6A003D80CF95A90DFC00E36B9B9A8438DD71CB51C2FB"]
        )
        XCTAssertEqual(configuration.pinnedCertificateSHA256,
                       ["8403d7253d1c8c65e15a6a003d80cf95a90dfc00e36b9b9a8438dd71cb51c2fb"])
    }

    func testConfigurationEncodedBeforePinningStillDecodes() throws {
        let legacy = Data("""
        {"mode":"enabled","serverName":"pacs.example.org","securityProfile":"none"}
        """.utf8)
        let configuration = try JSONDecoder().decode(DicomTLSConfiguration.self, from: legacy)
        XCTAssertEqual(configuration.mode, .enabled)
        XCTAssertEqual(configuration.serverName, "pacs.example.org")
        XCTAssertTrue(configuration.pinnedCertificateSHA256.isEmpty)
    }

    func testConfigurationRoundTripsPins() throws {
        let configuration = DicomTLSConfiguration(mode: .enabled,
                                                  pinnedCertificateSHA256: ["abc123"])
        let decoded = try JSONDecoder().decode(DicomTLSConfiguration.self,
                                               from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
    }

    func testDisabledConfigurationHasNoPins() {
        XCTAssertTrue(DicomTLSConfiguration.disabled.pinnedCertificateSHA256.isEmpty)
    }

    func testPeerIdentityRoundTrips() throws {
        let identity = DicomTLSPeerIdentity(certificateChain: [Data([0x30, 0x82]), Data([0x30, 0x81])],
                                            leafSHA256: "deadbeef",
                                            reason: "certificate is not trusted")
        let decoded = try JSONDecoder().decode(DicomTLSPeerIdentity.self,
                                               from: JSONEncoder().encode(identity))
        XCTAssertEqual(decoded, identity)
    }

    func testNotTrustedErrorDescribesTheReason() {
        let identity = DicomTLSPeerIdentity(certificateChain: [],
                                            leafSHA256: "deadbeef",
                                            reason: "“Example CA” certificate is not trusted")
        let description = DicomNetworkError.tlsPeerNotTrusted(identity).errorDescription
        XCTAssertEqual(description,
                       "The DICOM server's certificate is not trusted: “Example CA” certificate is not trusted")
    }

#if canImport(Network) && canImport(Security)
    func testSHA256HexMatchesKnownDigest() {
        // Digest of the empty input, so the encoding is pinned without a fixture.
        XCTAssertEqual(sha256Hex(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testRejectionRecorderKeepsTheFirstRejection() {
        let recorder = DicomTLSRejectionRecorder()
        XCTAssertNil(recorder.recorded)
        recorder.record(DicomTLSPeerIdentity(certificateChain: [], leafSHA256: "a", reason: "first"))
        XCTAssertEqual(recorder.recorded?.reason, "first")
    }

    func testClientAlwaysGetsAVerifyBlockSoRejectionsCanBeReported() throws {
        // With neither anchors nor pins the client still needs the chain the
        // peer offered, otherwise a failure cannot be turned into a trust
        // prompt.
        let prepared = try DicomTLSOptionsFactory.preparedParameters(
            for: DicomTLSConfiguration(mode: .enabled, serverName: "pacs.example.org"),
            role: .client
        )
        XCTAssertNotNil(prepared.tlsRejectionRecorder)
    }

    func testDisabledTLSPreparesNoRecorder() throws {
        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: .disabled, role: .client)
        XCTAssertNil(prepared.tlsRejectionRecorder)
        XCTAssertNil(prepared.tlsContext)
    }
#endif
}
