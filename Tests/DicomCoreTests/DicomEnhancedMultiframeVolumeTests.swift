//
//  DicomEnhancedMultiframeVolumeTests.swift
//  DicomCoreTests
//
//  Enhanced CT/MR multiframe volume assembly (issue #1234): synthetic
//  non-PHI Enhanced objects with Shared/Per-Frame Functional Groups
//  assemble into volumes with frame ordering by Plane Position, mixed
//  per-frame rescale, geometry metadata, and the same path for native
//  and compressed (RLE) frames; unsupported shapes fail typed with SOP
//  Class, frame count, transfer syntax, and the missing functional-group
//  context.
//

import Foundation
import XCTest
import simd
@testable import DicomCore

final class DicomEnhancedMultiframeVolumeTests: XCTestCase {
    private static let enhancedCTSOPClassUID = "1.2.840.10008.5.1.4.1.1.2.1"
    private static let enhancedMRSOPClassUID = "1.2.840.10008.5.1.4.1.1.4.1"

    // MARK: - Classic single-frame conversion

    func testEnhancedCTConversionProducesSpatiallyOrderedClassicInstances() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [5.0, 0.0, 2.5],
            frameIntercepts: ["-1024", "-1000", "-1012"],
            framePixelValues: [[10, 20, 30, 40], [50, 60, 70, 80], [90, 100, 110, 120]]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DicomEnhancedMultiframeConverter().convert(
            contentsOf: url,
            identifiers: DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760012", "2.25.17760013"]
            )
        )

        XCTAssertEqual(result.sourceSOPInstanceUID, "2.25.12340001")
        XCTAssertEqual(result.seriesInstanceUID, "2.25.17760001")
        XCTAssertEqual(result.instances.map(\.sourceFrameNumber), [2, 3, 1])
        XCTAssertEqual(result.instances.map(\.instanceNumber), [1, 2, 3])
        XCTAssertEqual(result.instances.map(\.sopInstanceUID),
                       ["2.25.17760011", "2.25.17760012", "2.25.17760013"])

        let expectedPixels: [[UInt16]] = [[50, 60, 70, 80], [90, 100, 110, 120], [10, 20, 30, 40]]
        let expectedZ = ["0", "2.5", "5"]
        let expectedIntercepts = ["-1000", "-1012", "-1024"]
        for (index, instance) in result.instances.enumerated() {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.info(for: .sopClassUID), "1.2.840.10008.5.1.4.1.1.2")
            XCTAssertEqual(decoder.info(for: .studyInstanceUID), "2.25.100")
            XCTAssertEqual(decoder.info(for: .seriesInstanceUID), "2.25.17760001")
            XCTAssertEqual(decoder.info(for: .frameOfReferenceUID), "2.25.300")
            XCTAssertEqual(decoder.info(for: .instanceNumber), "\(index + 1)")
            XCTAssertEqual(decoder.dataSet.strings(for: .imagePositionPatient).last, expectedZ[index])
            XCTAssertEqual(decoder.dataSet.decimalStrings(for: .imageOrientationPatient), [1, 0, 0, 0, 1, 0])
            XCTAssertEqual(decoder.dataSet.decimalStrings(for: .pixelSpacing), [0.5, 0.75])
            XCTAssertEqual(decoder.dataSet.decimalString(for: .sliceThickness), 2.5)
            XCTAssertEqual(decoder.dataSet.string(for: .rescaleIntercept), expectedIntercepts[index])
            XCTAssertEqual(decoder.dataSet.string(for: .rescaleSlope), "1")
            XCTAssertEqual(decoder.dataSet.strings(for: .imageType), ["DERIVED", "SECONDARY"])
            XCTAssertFalse(decoder.dataSet.contains(.numberOfFrames))
            XCTAssertFalse(decoder.dataSet.contains(.sharedFunctionalGroupsSequence))
            XCTAssertFalse(decoder.dataSet.contains(.perFrameFunctionalGroupsSequence))
            XCTAssertFalse(decoder.dataSet.contains(.dimensionOrganizationSequence))
            XCTAssertFalse(decoder.dataSet.contains(.dimensionIndexSequence))
            let source = try XCTUnwrap(decoder.dataSet.sequenceItems(for: .sourceImageSequence).first?.dataSet)
            XCTAssertEqual(source.string(for: .referencedSOPClassUID), Self.enhancedCTSOPClassUID)
            XCTAssertEqual(source.string(for: .referencedSOPInstanceUID), "2.25.12340001")
            XCTAssertEqual(source.int(for: .referencedFrameNumber), result.instances[index].sourceFrameNumber)
            XCTAssertTrue(try DicomEnhancedMultiframeConverter().containsReference(
                instance.part10Data,
                toSOPInstanceUID: "2.25.12340001"
            ))
            let frame = try DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
            guard case .gray16(let pixels) = frame.pixels else {
                return XCTFail("expected gray16 output")
            }
            XCTAssertEqual(pixels, expectedPixels[index])
        }
    }

    func testEnhancedCTIncrementalConversionEmitsValidatedInstancesInSpatialOrder() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [5.0, 0.0, 2.5],
            frameIntercepts: ["-1024", "-1000", "-1012"],
            framePixelValues: [[10, 20, 30, 40], [50, 60, 70, 80], [90, 100, 110, 120]]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        var instances: [DicomEnhancedMultiframeConverter.ValidatedInstance] = []
        let summary = try DicomEnhancedMultiframeConverter().convert(
            contentsOf: url,
            identifiers: DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760012", "2.25.17760013"]
            )
        ) { instance in
            instances.append(instance)
        }

        XCTAssertEqual(summary.sourceSOPInstanceUID, "2.25.12340001")
        XCTAssertEqual(summary.sourceSeriesInstanceUID, "2.25.200")
        XCTAssertEqual(summary.studyInstanceUID, "2.25.100")
        XCTAssertEqual(summary.frameOfReferenceUID, "2.25.300")
        XCTAssertEqual(summary.modality, "CT")
        XCTAssertNil(summary.seriesDescription)
        XCTAssertEqual(summary.seriesInstanceUID, "2.25.17760001")
        XCTAssertEqual(instances.map(\.instance.sourceFrameNumber), [2, 3, 1])
        XCTAssertEqual(instances.map(\.metadata.imagePositionPatient), [[0, 0, 0], [0, 0, 2.5], [0, 0, 5]])
        XCTAssertEqual(instances.map(\.metadata.rescaleIntercept), [-1_000, -1_012, -1_024])
        XCTAssertEqual(instances.map(\.metadata.sopClassUID), [
            "1.2.840.10008.5.1.4.1.1.2",
            "1.2.840.10008.5.1.4.1.1.2",
            "1.2.840.10008.5.1.4.1.1.2"
        ])
    }

    func testEnhancedConversionNormalizesMixedCaseMonochrome1() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[0, 1, 2, 3], [4, 5, 6, 7]],
            photometricInterpretation: "monochrome1"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: url)

        for (instance, expectedPixels) in zip(result.instances, [[0, 1, 2, 3], [4, 5, 6, 7]]) {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.info(for: .photometricInterpretation), "MONOCHROME1")
            XCTAssertEqual(
                try DicomDecodedFrameReader(decoder: decoder).frame(at: 0).pixels,
                .gray16(expectedPixels.map(UInt16.init))
            )
        }
    }

    func testEnhancedConversionLimitsDecimalStringsTo16Bytes() throws {
        let pixelSpacing = [0.0703125000000001, 0.000000123456789012345]
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            pixelSpacingValues: pixelSpacing.map { String($0) }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: url)
        let decoder = try DCMDecoder(data: result.instances[0].part10Data)
        let dataSet = decoder.dataSet
        let storedSpacing = dataSet.strings(for: DicomTag.pixelSpacing)

        XCTAssertEqual(storedSpacing.count, 2)
        XCTAssertTrue(storedSpacing.allSatisfy { $0.utf8.count <= 16 })
        XCTAssertEqual(Double(storedSpacing[0])!, pixelSpacing[0], accuracy: 1e-15)
        XCTAssertEqual(Double(storedSpacing[1])!, pixelSpacing[1], accuracy: 1e-17)
        for tag in [
            DicomTag.imagePositionPatient,
            .imageOrientationPatient,
            .pixelSpacing,
            .sliceThickness,
            .rescaleIntercept,
            .rescaleSlope
        ] {
            XCTAssertTrue(dataSet.strings(for: tag).allSatisfy { $0.utf8.count <= 16 })
        }
    }

    func testEnhancedMRConversionFlattensPerFrameRescaleAndVOI() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [2.5, 0.0],
            frameIntercepts: ["20", "10"],
            framePixelValues: [[20, 21, 22, 23], [10, 11, 12, 13]],
            sopClassUID: Self.enhancedMRSOPClassUID,
            modality: "MR",
            sharedWindowCenter: "80",
            sharedWindowWidth: "400",
            sharedWindowExplanation: "Shared MR",
            sharedVOILUTFunction: "LINEAR",
            frameWindowCenters: ["120", nil],
            frameWindowWidths: ["300", nil],
            frameWindowExplanations: ["Frame MR", nil],
            frameVOILUTFunctions: ["SIGMOID", nil]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: url)
        let first = try DCMDecoder(data: result.instances[0].part10Data)
        let second = try DCMDecoder(data: result.instances[1].part10Data)

        XCTAssertEqual(first.info(for: .sopClassUID), "1.2.840.10008.5.1.4.1.1.4")
        XCTAssertEqual(first.dataSet.string(for: .rescaleIntercept), "10")
        XCTAssertEqual(first.dataSet.string(for: .windowCenter), "80")
        XCTAssertEqual(first.dataSet.string(for: .windowWidth), "400")
        XCTAssertEqual(first.dataSet.string(for: .voiLUTFunction), "LINEAR")
        XCTAssertEqual(second.dataSet.string(for: .rescaleIntercept), "20")
        XCTAssertEqual(second.dataSet.string(for: .windowCenter), "120")
        XCTAssertEqual(second.dataSet.string(for: .windowWidth), "300")
        XCTAssertEqual(second.dataSet.string(for: .voiLUTFunction), "SIGMOID")
    }

    func testConversionOmitsPartialWindowExplanationsWithoutRejectingOutput() throws {
        let sourceURL = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            sharedWindowCenters: ["80", "120"],
            sharedWindowWidths: ["400", "300"],
            sharedWindowExplanations: ["Primary"],
            sharedVOILUTFunction: "LINEAR"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: sourceURL)

        XCTAssertEqual(result.instances.count, 2)
        for instance in result.instances {
            let converted = try DCMDecoder(data: instance.part10Data).dataSet
            XCTAssertEqual(converted.strings(for: .windowCenter), ["80", "120"])
            XCTAssertEqual(converted.strings(for: .windowWidth), ["400", "300"])
            XCTAssertTrue(converted.strings(for: .windowCenterWidthExplanation).isEmpty)
        }
    }

    func testConvertedClassicSeriesLoadsThroughTheStandardVolumePath() throws {
        let sourceURL = try Self.writeEnhancedObject(
            zPositions: [5.0, 0.0, 2.5],
            frameIntercepts: ["-1024", "-1000", "-1012"],
            framePixelValues: [[10, 20, 30, 40], [50, 60, 70, 80], [90, 100, 110, 120]]
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: sourceURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhanced-classic-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for instance in result.instances {
            try instance.part10Data.write(
                to: directory.appendingPathComponent("\(instance.instanceNumber).dcm")
            )
        }

        let volume = try DicomSeriesLoader().loadSeries(in: directory)

        XCTAssertEqual(volume.width, 2)
        XCTAssertEqual(volume.height, 2)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.spacing.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(volume.spacing.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(volume.spacing.z, 2.5, accuracy: 1e-9)
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [-1000, -1012, -1024])
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(voxels, [50, 60, 70, 80, 90, 100, 110, 120, 10, 20, 30, 40])
    }

    func testEnhancedConversionRejectsAdditionalDimensionsBeforeWriting() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
            stackIDs: ["STACK-1", "STACK-1"],
            additionalDimensionIndexPointer: DicomTag.temporalPositionIndex.rawValue
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedDimensionOrganization = error else {
                return XCTFail("expected unsupportedDimensionOrganization, got \(error)")
            }
        }
    }

    func test_temporalFrameContentWithoutDimensionOrganization_rejectsConversion() throws {
        let temporalContent: [(temporalPositionIndexes: [Int]?, frameAcquisitionNumbers: [Int]?)] = [
            (temporalPositionIndexes: [1, 2], frameAcquisitionNumbers: nil),
            (temporalPositionIndexes: nil, frameAcquisitionNumbers: [10, 20])
        ]

        for content in temporalContent {
            let url = try Self.writeEnhancedObject(
                zPositions: [0.0, 2.5],
                frameIntercepts: ["0", "0"],
                framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
                temporalPositionIndexes: content.temporalPositionIndexes,
                frameAcquisitionNumbers: content.frameAcquisitionNumbers
            )
            defer { try? FileManager.default.removeItem(at: url) }

            XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
                guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedDimensionOrganization = error else {
                    return XCTFail("expected unsupportedDimensionOrganization, got \(error)")
                }
            }
        }
    }

    func test_callerSuppliedInvalidOrReusedIdentifiers_rejectsConversion() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let invalidIdentifiers = [
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "not-a-uid",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.200",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760011"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["2.25.12340001", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["not-a-uid", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "2.25.17760001",
                sopInstanceUIDs: ["2.25.١٧٧٦٠٠١١", "2.25.17760012"]
            ),
            DicomEnhancedMultiframeConverter.Identifiers(
                seriesInstanceUID: "1.02.17760001",
                sopInstanceUIDs: ["2.25.17760011", "2.25.17760012"]
            )
        ]

        for identifiers in invalidIdentifiers {
            XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(
                contentsOf: url,
                identifiers: identifiers
            )) { error in
                guard case DicomEnhancedMultiframeConverter.ConversionError.invalidIdentifier = error else {
                    return XCTFail("expected invalidIdentifier, got \(error)")
                }
            }
        }
    }

    func test_invalidDirectionCosines_rejectConversion() throws {
        let invalidOrientations = [
            ["2", "0", "0", "0", "1", "0"],
            ["1", "0", "0", "0.6", "0.8", "0"],
            ["nan", "0", "0", "0", "1", "0"]
        ]

        for orientation in invalidOrientations {
            let url = try Self.writeEnhancedObject(
                zPositions: [0.0, 2.5],
                frameIntercepts: ["0", "0"],
                framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
                orientationValues: orientation
            )
            defer { try? FileManager.default.removeItem(at: url) }

            XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
                guard case DicomEnhancedMultiframeConverter.ConversionError.incompleteGeometry(frameNumber: 1) = error else {
                    return XCTFail("expected incompleteGeometry, got \(error)")
                }
            }
        }
    }

    func testEnhancedConversionRejectsMultiStackBeforeWriting() throws {
        let multiStack = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5, 5.0, 7.5],
            frameIntercepts: ["0", "0", "0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3], [4, 4, 4, 4]],
            stackIDs: ["STACK-1", "STACK-1", "STACK-2", "STACK-2"]
        )
        defer { try? FileManager.default.removeItem(at: multiStack) }
        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: multiStack)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedDimensionOrganization = error else {
                return XCTFail("expected unsupportedDimensionOrganization, got \(error)")
            }
        }
    }

    func testEnhancedConversionRejectsNonEnhancedSOPClassBeforeWriting() throws {
        let classicURL = try Self.writeEnhancedObject(
            zPositions: [0, 1],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
            sopClassUID: "1.2.840.10008.5.1.4.1.1.2"
        )
        defer { try? FileManager.default.removeItem(at: classicURL) }
        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: classicURL)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedSOPClassUID = error else {
                return XCTFail("expected unsupportedSOPClassUID, got \(error)")
            }
        }
    }

    func testEnhancedConversionRejectsDeflatedDataSetBeforeWriting() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0, 1],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
            transferSyntax: .deflatedExplicitVRLittleEndian
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedTransferSyntax = error else {
                return XCTFail("expected unsupportedTransferSyntax, got \(error)")
            }
        }
    }

    func testRLEEnhancedConversionProducesUncompressedClassicInstances() throws {
        let frameSamples: [[UInt8]] = [[10, 20, 30, 40], [50, 60, 70, 80]]
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: frameSamples.map(Self.rleSegment(samples:)),
            declaredFrames: 2,
            rows: 2,
            columns: 2
        )
        Self.appendFunctionalGroups(
            to: &dataSet,
            zPositions: [2.0, 0.0],
            frameIntercepts: ["-10", "-20"]
        )
        let url = try Self.write(
            dataSet: dataSet,
            transferSyntax: .rleLossless,
            mediaStorageSOPClassUID: Self.enhancedCTSOPClassUID
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try DicomEnhancedMultiframeConverter().convert(contentsOf: url)

        XCTAssertEqual(result.instances.map(\.sourceFrameNumber), [2, 1])
        for (instance, expected) in zip(result.instances, frameSamples.reversed()) {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
            XCTAssertFalse(decoder.compressedImage)
            XCTAssertFalse(decoder.dataSet.contains(.extendedOffsetTable))
            XCTAssertFalse(decoder.dataSet.contains(.extendedOffsetTableLengths))
            let frame = try DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
            XCTAssertEqual(frame.pixels, .gray8(expected))
        }
    }

    func testEnhancedConversionRejectsIncompleteGeometryBeforeWriting() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            omitPlanePositionForFrame: 1
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.incompleteGeometry(frameNumber: 2) = error else {
                return XCTFail("expected incompleteGeometry, got \(error)")
            }
        }
    }

    func testEnhancedConversionRejectsMissingFrameOfReferenceBeforeWriting() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            omitFrameOfReferenceUID: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
            guard case DicomEnhancedMultiframeConverter.ConversionError.missingRequiredUID(
                "Frame of Reference UID"
            ) = error else {
                return XCTFail("expected missingRequiredUID, got \(error)")
            }
        }
    }

    func testEnhancedConversionRejectsRGBAndGreaterThan16BitBeforeWriting() throws {
        for (samples, photometric, bitsAllocated) in [(3, "RGB", 8), (1, "MONOCHROME2", 32)] {
            var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                transferSyntax: .explicitVRLittleEndian,
                fragments: [],
                declaredFrames: 2,
                rows: 2,
                columns: 2,
                bitsAllocated: bitsAllocated,
                bitsStored: bitsAllocated,
                highBit: bitsAllocated - 1,
                samplesPerPixel: samples,
                photometricInterpretation: photometric
            )
            let byteCount = 2 * 2 * 2 * samples * (bitsAllocated / 8)
            dataSet.set(DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: bitsAllocated > 8 ? .OW : .OB,
                value: .bytes(Data(count: byteCount))
            ))
            Self.appendFunctionalGroups(
                to: &dataSet,
                zPositions: [0, 1],
                frameIntercepts: ["0", "0"]
            )
            let url = try Self.write(
                dataSet: dataSet,
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: Self.enhancedCTSOPClassUID
            )
            defer { try? FileManager.default.removeItem(at: url) }

            XCTAssertThrowsError(try DicomEnhancedMultiframeConverter().convert(contentsOf: url)) { error in
                guard case DicomEnhancedMultiframeConverter.ConversionError.unsupportedPixelFormat = error else {
                    return XCTFail("expected unsupportedPixelFormat, got \(error)")
                }
            }
        }
    }

    // MARK: - Native Enhanced CT assembly

    func testEnhancedCTVolumeAssemblesWithSpatialOrderingAndPerFrameRescale() throws {
        // Frames are stored out of spatial order: z positions 5.0, 0.0, 2.5.
        let url = try Self.writeEnhancedObject(
            zPositions: [5.0, 0.0, 2.5],
            frameIntercepts: ["-1024", "-1000", "-1012"],
            framePixelValues: [[10, 20, 30, 40], [50, 60, 70, 80], [90, 100, 110, 120]]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.width, 2)
        XCTAssertEqual(volume.height, 2)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.spacing.x, 0.75, accuracy: 1e-9, "row spacing maps to in-plane x")
        XCTAssertEqual(volume.spacing.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(volume.spacing.z, 2.5, accuracy: 1e-9, "z spacing from ordered position deltas")
        XCTAssertEqual(volume.origin, SIMD3<Double>(0, 0, 0), "origin is the spatially first frame")
        XCTAssertEqual(volume.modality, "CT")

        // Spatial order: frame 1 (z=0), frame 2 (z=2.5), frame 0 (z=5).
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(voxels, [50, 60, 70, 80, 90, 100, 110, 120, 10, 20, 30, 40])

        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [-1000, -1012, -1024],
                       "per-frame Pixel Value Transformation intercepts follow the spatial order")
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.slope), [1, 1, 1])
        XCTAssertEqual(volume.rescaleIntercept, -1000, accuracy: 1e-9, "volume rescale comes from the first spatial frame")
    }

    func testEnhancedMRVolumeUsesTheSameFunctionalGroupAssembly() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [3.0, 0.0, 1.5],
            frameIntercepts: ["30", "10", "20"],
            framePixelValues: [[30, 31, 32, 33], [10, 11, 12, 13], [20, 21, 22, 23]],
            sopClassUID: Self.enhancedMRSOPClassUID,
            modality: "MR"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.modality, "MR")
        XCTAssertEqual(volume.spacing.z, 1.5, accuracy: 1e-9)
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [10, 20, 30])
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(voxels, [10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33])
    }

    func testMultipleStacksWithOverlappingPositionsFailClosed() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5, 0.0, 2.5],
            frameIntercepts: ["0", "0", "0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3], [4, 4, 4, 4]],
            stackIDs: ["STACK-1", "STACK-1", "STACK-2", "STACK-2"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let groups = try XCTUnwrap(decoder.enhancedMultiframeFunctionalGroups)
        XCTAssertEqual(groups.frames.map { $0.functionalGroups.frameContent?.stackID },
                       ["STACK-1", "STACK-1", "STACK-2", "STACK-2"])
        XCTAssertEqual(groups.frames.map { $0.functionalGroups.frameContent?.dimensionIndexValues },
                       [[1, 1], [1, 2], [2, 1], [2, 2]])
        XCTAssertEqual(groups.dimensionOrganization?.indexes.map(\.dimensionIndexPointer),
                       [DicomTag.stackID.rawValue, DicomTag.inStackPositionNumber.rawValue])

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertTrue(context.reason.contains("multiple logical stacks"), context.reason)
        }
    }

    func testMultipleDisjointStacksFailClosedInsteadOfConcatenating() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5, 5.0, 7.5],
            frameIntercepts: ["0", "0", "0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3], [4, 4, 4, 4]],
            stackIDs: ["STACK-1", "STACK-1", "STACK-2", "STACK-2"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertTrue(context.reason.contains("multiple logical stacks"), context.reason)
        }
    }

    func testSingleDeclaredStackPreservesSpatialAssembly() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [5.0, 0.0, 2.5],
            frameIntercepts: ["30", "10", "20"],
            framePixelValues: [[30, 31, 32, 33], [10, 11, 12, 13], [20, 21, 22, 23]],
            stackIDs: ["STACK-1", "STACK-1", "STACK-1"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.spacing.z, 2.5, accuracy: 1e-9)
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual([voxels[0], voxels[4], voxels[8]], [10, 20, 30])
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [10, 20, 30])
    }

    func testAdditionalTemporalDimensionFailsTyped() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 1, 1, 1], [2, 2, 2, 2]],
            stackIDs: ["STACK-1", "STACK-1"],
            additionalDimensionIndexPointer: DicomTag.temporalPositionIndex.rawValue
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertTrue(context.reason.contains("unsupported Dimension Index pattern"), context.reason)
        }
    }

    func testEnhancedCTPreservesPerFrameVOIInSpatialOrder() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [2.5, 0.0],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            frameWindowCenters: ["200", "100"],
            frameWindowWidths: ["60", "50"],
            frameWindowExplanations: ["Follow-up", "Baseline"],
            frameVOILUTFunctions: ["SIGMOID", "LINEAR_EXACT"]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let groups = try XCTUnwrap(decoder.enhancedMultiframeFunctionalGroups)
        XCTAssertEqual(groups.frames[0].functionalGroups.frameVOI?.windows.first?.center, 200)
        XCTAssertEqual(groups.frames[0].functionalGroups.frameVOI?.windows.first?.explanation, "Follow-up")
        XCTAssertEqual(groups.frames[0].functionalGroups.frameVOI?.lutFunction, "SIGMOID")

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.sliceVOIs.map { $0?.windows.first?.center }, [100, 200])
        XCTAssertEqual(volume.sliceVOIs.map { $0?.windows.first?.width }, [50, 60])
        XCTAssertEqual(volume.sliceVOIs.map { $0?.lutFunction }, ["LINEAR_EXACT", "SIGMOID"])
        XCTAssertEqual(volume.windowCenter, 100, "the first valid window in spatial order is the volume default")
        XCTAssertEqual(volume.windowWidth, 50)

        let decodedSeries = try DicomDecodedSeries(volume: volume, sourceURL: url)
        XCTAssertEqual(decodedSeries.sliceVOIs, volume.sliceVOIs)
    }

    func testEnhancedMRResolvesPerFrameVOIOverSharedVOI() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [2.5, 0.0],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            sopClassUID: Self.enhancedMRSOPClassUID,
            modality: "MR",
            sharedWindowCenter: "80",
            sharedWindowWidth: "400",
            sharedWindowExplanation: "Shared MR",
            sharedVOILUTFunction: "LINEAR",
            frameWindowCenters: ["120", nil],
            frameWindowWidths: ["300", nil],
            frameWindowExplanations: ["Frame MR", nil],
            frameVOILUTFunctions: ["SIGMOID", nil]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let groups = try XCTUnwrap(decoder.enhancedMultiframeFunctionalGroups)
        XCTAssertEqual(groups.frames[0].functionalGroups.frameVOI?.windows.first?.center, 120)
        XCTAssertEqual(groups.frames[0].functionalGroups.frameVOI?.lutFunction, "SIGMOID")
        XCTAssertEqual(groups.frames[1].functionalGroups.frameVOI?.windows.first?.center, 80)
        XCTAssertEqual(groups.frames[1].functionalGroups.frameVOI?.windows.first?.explanation, "Shared MR")

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.sliceVOIs.map { $0?.windows.first?.center }, [80, 120])
        XCTAssertEqual(volume.windowCenter, 80)
        XCTAssertEqual(volume.windowWidth, 400)
    }

    func testMalformedPerFrameVOIFallsBackToSharedWithoutChangingPixels() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["0", "0"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            sharedWindowCenter: "40",
            sharedWindowWidth: "400",
            frameWindowCenters: ["not-a-number", nil],
            frameWindowWidths: ["-1", nil]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.sliceVOIs.map { $0?.windows.first?.center }, [40, 40])
        XCTAssertEqual(volume.windowCenter, 40)
        XCTAssertEqual(volume.windowWidth, 400)
        XCTAssertEqual(volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) },
                       [1, 2, 3, 4, 5, 6, 7, 8])
    }

    /// Compressed multiframe objects assemble through exactly the same
    /// decoded-frame path: per-frame RLE fragments decode one at a time.
    func testCompressedRLEEnhancedObjectAssemblesThroughTheSamePath() throws {
        let frameSamples: [[UInt8]] = [[10, 20, 30, 40], [50, 60, 70, 80]]
        let fragments = frameSamples.map { Self.rleSegment(samples: $0) }
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: fragments,
            declaredFrames: 2,
            rows: 2,
            columns: 2
        )
        Self.appendFunctionalGroups(
            to: &dataSet,
            zPositions: [2.0, 0.0],
            frameIntercepts: ["-10", "-20"]
        )
        let url = try Self.write(dataSet: dataSet, transferSyntax: .rleLossless)
        defer { try? FileManager.default.removeItem(at: url) }

        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)

        XCTAssertEqual(volume.depth, 2)
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        // Spatial order: frame 1 (z=0) before frame 0 (z=2).
        XCTAssertEqual(voxels, [50, 60, 70, 80, 10, 20, 30, 40])
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [-20, -10])
    }

    // MARK: - Typed rejections with full context

    func testMissingPlanePositionFailsTypedWithFunctionalGroupContext() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0, 2.5],
            frameIntercepts: ["-1024", "-1024"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]],
            omitPlanePositionForFrame: 1
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertEqual(context.sopClassUID, Self.enhancedCTSOPClassUID)
            XCTAssertEqual(context.frameCount, 2)
            XCTAssertEqual(context.transferSyntaxUID, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
            XCTAssertTrue(context.reason.contains("Plane Position"), context.reason)
        }
    }

    func testObjectWithoutFunctionalGroupsFailsTyped() throws {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: 2,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        dataSet.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                                     value: .strings([Self.enhancedCTSOPClassUID])))
        dataSet.set(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["2"])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW,
                                     value: .bytes(Data(count: 16))))
        let url = try Self.write(dataSet: dataSet, transferSyntax: .explicitVRLittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertTrue(context.reason.contains("Functional Groups"), context.reason)
        }
    }

    func testSingleFrameObjectIsRedirectedTyped() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [0.0],
            frameIntercepts: ["-1024"],
            framePixelValues: [[1, 2, 3, 4]]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.unsupportedEnhancedMultiframe(let context) = error else {
                return XCTFail("expected unsupportedEnhancedMultiframe, got \(error)")
            }
            XCTAssertEqual(context.frameCount, 1)
            XCTAssertTrue(context.reason.contains("single frame"), context.reason)
        }
    }

    func testDuplicateFramePositionsFailTyped() throws {
        let url = try Self.writeEnhancedObject(
            zPositions: [1.0, 1.0],
            frameIntercepts: ["-1024", "-1024"],
            framePixelValues: [[1, 2, 3, 4], [5, 6, 7, 8]]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)) { error in
            guard case DicomSeriesLoaderError.duplicateSlicePosition = error else {
                return XCTFail("expected duplicateSlicePosition, got \(error)")
            }
        }
    }

    // MARK: - Builders (deterministic, non-PHI)

    private static func writeEnhancedObject(
        zPositions: [Double],
        frameIntercepts: [String],
        framePixelValues: [[Int16]],
        omitPlanePositionForFrame: Int? = nil,
        sopClassUID: String = enhancedCTSOPClassUID,
        modality: String = "CT",
        stackIDs: [String]? = nil,
        temporalPositionIndexes: [Int]? = nil,
        frameAcquisitionNumbers: [Int]? = nil,
        additionalDimensionIndexPointer: Int? = nil,
        orientationValues: [String] = ["1", "0", "0", "0", "1", "0"],
        photometricInterpretation: String = "MONOCHROME2",
        pixelSpacingValues: [String] = ["0.5", "0.75"],
        sharedWindowCenter: String? = nil,
        sharedWindowWidth: String? = nil,
        sharedWindowExplanation: String? = nil,
        sharedWindowCenters: [String]? = nil,
        sharedWindowWidths: [String]? = nil,
        sharedWindowExplanations: [String]? = nil,
        sharedVOILUTFunction: String? = nil,
        frameWindowCenters: [String?]? = nil,
        frameWindowWidths: [String?]? = nil,
        frameWindowExplanations: [String?]? = nil,
        frameVOILUTFunctions: [String?]? = nil,
        omitFrameOfReferenceUID: Bool = false,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> URL {
        var pixelData = Data()
        for frame in framePixelValues {
            for value in frame {
                let pattern = UInt16(bitPattern: value)
                pixelData.append(UInt8(pattern & 0xFF))
                pixelData.append(UInt8(pattern >> 8))
            }
        }

        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: zPositions.count,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            photometricInterpretation: photometricInterpretation
        )
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
        appendFunctionalGroups(
            to: &dataSet,
            zPositions: zPositions,
            frameIntercepts: frameIntercepts,
            omitPlanePositionForFrame: omitPlanePositionForFrame,
            sopClassUID: sopClassUID,
            modality: modality,
            stackIDs: stackIDs,
            temporalPositionIndexes: temporalPositionIndexes,
            frameAcquisitionNumbers: frameAcquisitionNumbers,
            additionalDimensionIndexPointer: additionalDimensionIndexPointer,
            orientationValues: orientationValues,
            pixelSpacingValues: pixelSpacingValues,
            sharedWindowCenter: sharedWindowCenter,
            sharedWindowWidth: sharedWindowWidth,
            sharedWindowExplanation: sharedWindowExplanation,
            sharedWindowCenters: sharedWindowCenters,
            sharedWindowWidths: sharedWindowWidths,
            sharedWindowExplanations: sharedWindowExplanations,
            sharedVOILUTFunction: sharedVOILUTFunction,
            frameWindowCenters: frameWindowCenters,
            frameWindowWidths: frameWindowWidths,
            frameWindowExplanations: frameWindowExplanations,
            frameVOILUTFunctions: frameVOILUTFunctions,
            omitFrameOfReferenceUID: omitFrameOfReferenceUID
        )
        return try write(
            dataSet: dataSet,
            transferSyntax: transferSyntax,
            mediaStorageSOPClassUID: sopClassUID
        )
    }

    private static func appendFunctionalGroups(
        to dataSet: inout DicomDataSet,
        zPositions: [Double],
        frameIntercepts: [String],
        omitPlanePositionForFrame: Int? = nil,
        sopClassUID: String = enhancedCTSOPClassUID,
        modality: String = "CT",
        stackIDs: [String]? = nil,
        temporalPositionIndexes: [Int]? = nil,
        frameAcquisitionNumbers: [Int]? = nil,
        additionalDimensionIndexPointer: Int? = nil,
        orientationValues: [String] = ["1", "0", "0", "0", "1", "0"],
        pixelSpacingValues: [String] = ["0.5", "0.75"],
        sharedWindowCenter: String? = nil,
        sharedWindowWidth: String? = nil,
        sharedWindowExplanation: String? = nil,
        sharedWindowCenters: [String]? = nil,
        sharedWindowWidths: [String]? = nil,
        sharedWindowExplanations: [String]? = nil,
        sharedVOILUTFunction: String? = nil,
        frameWindowCenters: [String?]? = nil,
        frameWindowWidths: [String?]? = nil,
        frameWindowExplanations: [String?]? = nil,
        frameVOILUTFunctions: [String?]? = nil,
        omitFrameOfReferenceUID: Bool = false
    ) {
        dataSet.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                                     value: .strings([sopClassUID])))
        dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.12340001"])))
        dataSet.set(DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.100"])))
        dataSet.set(DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.200"])))
        if !omitFrameOfReferenceUID {
            dataSet.set(DicomDataElement(tag: DicomTag.frameOfReferenceUID.rawValue, vr: .UI,
                                         value: .strings(["2.25.300"])))
        }
        dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings([modality])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^ENHANCED"])))
        dataSet.set(DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1234"])))
        dataSet.set(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS,
                                     value: .strings(["\(zPositions.count)"])))
        if stackIDs != nil {
            appendDimensionOrganization(
                to: &dataSet,
                additionalDimensionIndexPointer: additionalDimensionIndexPointer
            )
        }

        var sharedElements = [
            sequence(.pixelMeasuresSequence, [
                DicomDataSet(elements: [
                    ds(.pixelSpacing, pixelSpacingValues),
                    ds(.sliceThickness, ["2.5"])
                ])
            ]),
            sequence(.planeOrientationSequence, [
                DicomDataSet(elements: [
                    ds(.imageOrientationPatient, orientationValues)
                ])
            ])
        ]
        if let sharedWindowCenters, let sharedWindowWidths {
            sharedElements.append(frameVOISequence(
                centers: sharedWindowCenters,
                widths: sharedWindowWidths,
                explanations: sharedWindowExplanations ?? [],
                function: sharedVOILUTFunction
            ))
        } else if let sharedWindowCenter, let sharedWindowWidth {
            sharedElements.append(frameVOISequence(
                center: sharedWindowCenter,
                width: sharedWindowWidth,
                explanation: sharedWindowExplanation,
                function: sharedVOILUTFunction
            ))
        }
        let shared = DicomDataSet(elements: sharedElements)
        dataSet.set(sequence(.sharedFunctionalGroupsSequence, [shared]))

        let perFrame = zPositions.enumerated().map { index, z -> DicomDataSet in
            var elements = [DicomDataElement]()
            if stackIDs != nil || temporalPositionIndexes != nil || frameAcquisitionNumbers != nil {
                var frameContentElements = [DicomDataElement]()
                if let stackIDs {
                    let orderedStackIDs = stackIDs.reduce(into: [String]()) { result, stackID in
                        if !result.contains(stackID) { result.append(stackID) }
                    }
                    let stackNumber = (orderedStackIDs.firstIndex(of: stackIDs[index]) ?? 0) + 1
                    let inStackPosition = stackIDs[...index].filter { $0 == stackIDs[index] }.count
                    var dimensionIndexValues = [UInt(stackNumber), UInt(inStackPosition)]
                    if additionalDimensionIndexPointer != nil {
                        dimensionIndexValues.append(1)
                    }
                    frameContentElements.append(contentsOf: [
                        DicomDataElement(tag: DicomTag.stackID.rawValue, vr: .SH,
                                         value: .strings([stackIDs[index]])),
                        DicomDataElement(tag: DicomTag.inStackPositionNumber.rawValue, vr: .UL,
                                         value: .unsignedIntegers([UInt(inStackPosition)])),
                        DicomDataElement(tag: DicomTag.dimensionIndexValues.rawValue, vr: .UL,
                                         value: .unsignedIntegers(dimensionIndexValues))
                    ])
                }
                if let temporalPositionIndexes {
                    frameContentElements.append(DicomDataElement(
                        tag: DicomTag.temporalPositionIndex.rawValue,
                        vr: .UL,
                        value: .unsignedIntegers([UInt(temporalPositionIndexes[index])])
                    ))
                }
                if let frameAcquisitionNumbers {
                    frameContentElements.append(DicomDataElement(
                        tag: DicomTag.frameAcquisitionNumber.rawValue,
                        vr: .UL,
                        value: .unsignedIntegers([UInt(frameAcquisitionNumbers[index])])
                    ))
                }
                elements.append(sequence(.frameContentSequence, [
                    DicomDataSet(elements: frameContentElements)
                ]))
            }
            if index != omitPlanePositionForFrame {
                elements.append(sequence(.planePositionSequence, [
                    DicomDataSet(elements: [
                        ds(.imagePositionPatient, ["0", "0", String(z)])
                    ])
                ]))
            }
            elements.append(sequence(.pixelValueTransformationSequence, [
                DicomDataSet(elements: [
                    ds(.rescaleIntercept, [frameIntercepts[index]]),
                    ds(.rescaleSlope, ["1"])
                ])
            ]))
            if let center = value(at: index, in: frameWindowCenters),
               let width = value(at: index, in: frameWindowWidths) {
                elements.append(frameVOISequence(
                    center: center,
                    width: width,
                    explanation: value(at: index, in: frameWindowExplanations),
                    function: value(at: index, in: frameVOILUTFunctions)
                ))
            }
            return DicomDataSet(elements: elements)
        }
        dataSet.set(sequence(.perFrameFunctionalGroupsSequence, perFrame))
    }

    private static func appendDimensionOrganization(
        to dataSet: inout DicomDataSet,
        additionalDimensionIndexPointer: Int?
    ) {
        let organizationUID = "2.25.12340002"
        dataSet.set(rawSequence(0x0020_9221, [
            DicomDataSet(elements: [
                DicomDataElement(tag: 0x0020_9164, vr: .UI, value: .strings([organizationUID]))
            ])
        ]))

        var indexes = [
            dimensionIndex(
                organizationUID: organizationUID,
                pointer: DicomTag.stackID.rawValue
            ),
            dimensionIndex(
                organizationUID: organizationUID,
                pointer: DicomTag.inStackPositionNumber.rawValue
            )
        ]
        if let additionalDimensionIndexPointer {
            indexes.append(dimensionIndex(
                organizationUID: organizationUID,
                pointer: additionalDimensionIndexPointer
            ))
        }
        dataSet.set(rawSequence(0x0020_9222, indexes))
    }

    private static func dimensionIndex(organizationUID: String, pointer: Int) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: 0x0020_9164, vr: .UI, value: .strings([organizationUID])),
            DicomDataElement(tag: 0x0020_9165, vr: .AT, value: .unsignedIntegers([UInt(pointer)])),
            DicomDataElement(
                tag: 0x0020_9167,
                vr: .AT,
                value: .unsignedIntegers([UInt(DicomTag.frameContentSequence.rawValue)])
            )
        ])
    }

    private static func frameVOISequence(
        center: String,
        width: String,
        explanation: String?,
        function: String?
    ) -> DicomDataElement {
        frameVOISequence(
            centers: [center],
            widths: [width],
            explanations: explanation.map { [$0] } ?? [],
            function: function
        )
    }

    private static func frameVOISequence(
        centers: [String],
        widths: [String],
        explanations: [String],
        function: String?
    ) -> DicomDataElement {
        var elements = [
            ds(.windowCenter, centers),
            ds(.windowWidth, widths)
        ]
        if !explanations.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.windowCenterWidthExplanation.rawValue,
                vr: .LO,
                value: .strings(explanations)
            ))
        }
        if let function {
            elements.append(DicomDataElement(
                tag: 0x0028_1056,
                vr: .CS,
                value: .strings([function])
            ))
        }
        return rawSequence(0x0028_9132, [DicomDataSet(elements: elements)])
    }

    private static func value<T>(at index: Int, in values: [T?]?) -> T? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func write(
        dataSet: DicomDataSet,
        transferSyntax: DicomTransferSyntax,
        mediaStorageSOPClassUID: String = enhancedCTSOPClassUID
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhanced_volume_\(UUID().uuidString).dcm")
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: mediaStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12340001"
            )
        )
        try data.write(to: url)
        return url
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        rawSequence(tag.rawValue, dataSets)
    }

    private static func rawSequence(_ tag: Int, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private static func rleSegment(samples: [UInt8]) -> Data {
        var rle = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { rle.append(contentsOf: $0) }
        }
        rle.append(UInt8(samples.count - 1))
        rle.append(contentsOf: samples)
        if rle.count % 2 != 0 {
            rle.append(0x00)
        }
        return rle
    }
}
