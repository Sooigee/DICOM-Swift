import Foundation
import XCTest
@testable import DicomCore

final class DicomTLSSecurityProfileTests: XCTestCase {
    func test_currentProfile_usesTLS12Minimum() {
        XCTAssertEqual(
            DicomTLSOptionsFactory.minimumTLSProtocolVersionName(for: .bcp195RFC8996),
            "TLSv1.2"
        )
    }

    func test_legacyRawValues_decodeAsCurrentProfile() throws {
        let legacyRawValues = [
            "nonDowngradingBCP195",
            "bcp195",
            "extendedBCP195",
            "basicRetired",
            "aesRetired",
            "authenticatedUnencryptedRetired"
        ]

        for rawValue in legacyRawValues {
            let data = try XCTUnwrap("\"\(rawValue)\"".data(using: .utf8))
            let decoded = try JSONDecoder().decode(DicomTLSSecurityProfile.self, from: data)

            XCTAssertEqual(decoded, .bcp195RFC8996, rawValue)
        }
    }

    func test_currentProfile_encodesCanonicalRawValue() throws {
        let data = try JSONEncoder().encode(DicomTLSSecurityProfile.bcp195RFC8996)

        XCTAssertEqual(String(data: data, encoding: .utf8), "\"bcp195RFC8996\"")
    }

    func test_unknownRawValue_isRejected() throws {
        let data = try XCTUnwrap("\"unknown\"".data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(DicomTLSSecurityProfile.self, from: data))
    }
}
