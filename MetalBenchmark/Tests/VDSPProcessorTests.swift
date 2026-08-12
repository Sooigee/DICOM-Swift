@testable import MetalBenchmark
import XCTest

final class VDSPProcessorTests: XCTestCase {
    func test_windowLevelWithBoundaryPixels_clampsIntoByteRange() throws {
        let data = try XCTUnwrap(
            VDSPProcessor.applyWindowLevel(
                pixels16: [0, 2, 4],
                center: 2.0,
                width: 4.0
            )
        )

        XCTAssertEqual(Array(data), [0, 127, 255])
    }
}
