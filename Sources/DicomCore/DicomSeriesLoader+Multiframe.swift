//
//  DicomSeriesLoader+Multiframe.swift
//  DicomCore
//
//  Enhanced CT/MR multiframe volume assembly (issue #1234): one
//  multiframe object becomes a volume using Shared and Per-Frame
//  Functional Groups for geometry, spacing, position, ordering, and
//  per-frame rescale. Frames decode one at a time through
//  `DicomDecodedFrameReader`, so compressed multiframe objects (RLE,
//  JPEG family, JPEG 2000, HTJ2K with an active backend) assemble through
//  exactly the same path as native ones — the frame reader resolves the
//  transfer syntax per frame and memory stays bounded to one decoded
//  frame at a time.
//

import Foundation
import simd

extension DicomSeriesLoaderError {
    /// Context for a rejected Enhanced multiframe volume input.
    public struct EnhancedMultiframeContext: Equatable, Sendable {
        public let sopClassUID: String
        public let frameCount: Int
        public let transferSyntaxUID: String
        public let reason: String

        public init(sopClassUID: String, frameCount: Int, transferSyntaxUID: String, reason: String) {
            self.sopClassUID = sopClassUID
            self.frameCount = frameCount
            self.transferSyntaxUID = transferSyntaxUID
            self.reason = reason
        }
    }
}

extension DicomSeriesLoader {
    /// Assembles a volume from a single Enhanced CT/MR (or compatible)
    /// multiframe object. Geometry comes from the Shared/Per-Frame
    /// Functional Groups: Plane Position orders the frames along the
    /// normal, Plane Orientation must be consistent, Pixel Measures give
    /// the in-plane spacing, and Pixel Value Transformation supplies the
    /// per-frame rescale (falling back to the top-level rescale tags). Frame
    /// VOI values remain associated with each spatially ordered slice. The
    /// volume default is the first valid Frame VOI window in spatial order,
    /// falling back to top-level Window Center/Width when none is available.
    public func loadEnhancedMultiframeVolume(at url: URL) throws -> DicomSeriesVolume {
        let anyDecoder = try decoderFactory(url.path)
        let format = enhancedPixelFormat(from: anyDecoder)
        guard let decoder = anyDecoder as? DCMDecoder else {
            throw enhancedError(format, sopClassUID: anyDecoder.info(for: .sopClassUID),
                                reason: "Enhanced multiframe assembly requires the package DCMDecoder.")
        }
        let sopClassUID = decoder.info(for: .sopClassUID)

        guard format.numberOfFrames > 1 else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "the object declares a single frame; use loadSeries(in:) for single-frame series.")
        }
        guard format.samplesPerPixel == 1,
              format.photometricInterpretation == "MONOCHROME1" || format.photometricInterpretation == "MONOCHROME2" else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "only single-sample MONOCHROME1/MONOCHROME2 frames are assembled "
                                    + "(Photometric Interpretation=\(format.photometricInterpretation), "
                                    + "Samples per Pixel=\(format.samplesPerPixel)).")
        }
        guard format.bitsAllocated == 8 || format.bitsAllocated == 16 else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "Bits Allocated \(format.bitsAllocated) is outside the 8/16-bit multiframe scope.")
        }

        guard let groups = decoder.enhancedMultiframeFunctionalGroups else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "the object carries no Shared or Per-Frame Functional Groups Sequence.")
        }
        guard groups.frameCount >= format.numberOfFrames else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "Per-Frame Functional Groups cover \(groups.frameCount) of "
                                    + "\(format.numberOfFrames) declared frames.")
        }

        let orderedFrames = try validatedSingleStackFrames(
            groups,
            format: format,
            sopClassUID: sopClassUID
        )
        var referenceOrientation: DicomPlaneOrientation?
        var positions = [Double]()

        for frame in orderedFrames {
            let functionalGroups = frame.functionalGroups
            guard let orientation = functionalGroups.planeOrientation else {
                throw enhancedError(format, sopClassUID: sopClassUID,
                                    reason: "frame \(frame.index) has no Plane Orientation Functional Group.")
            }
            guard let position = functionalGroups.planePosition else {
                throw enhancedError(format, sopClassUID: sopClassUID,
                                    reason: "frame \(frame.index) has no Plane Position Functional Group.")
            }
            guard functionalGroups.pixelMeasures?.pixelSpacing != nil else {
                throw enhancedError(format, sopClassUID: sopClassUID,
                                    reason: "frame \(frame.index) has no Pixel Measures Functional Group with Pixel Spacing.")
            }
            if let reference = referenceOrientation {
                guard simd_length(reference.row - orientation.row) < 1e-4,
                      simd_length(reference.column - orientation.column) < 1e-4 else {
                    throw DicomSeriesLoaderError.inconsistentOrientation
                }
            } else {
                referenceOrientation = orientation
            }
            positions.append(simd_dot(position.imagePositionPatient, orientation.normal))
        }

        guard let orientation = referenceOrientation,
              let firstFrame = orderedFrames.first,
              let firstPosition = firstFrame.functionalGroups.planePosition?.imagePositionPatient,
              let pixelSpacing = firstFrame.functionalGroups.pixelMeasures?.pixelSpacing else {
            throw enhancedError(format, sopClassUID: sopClassUID,
                                reason: "the functional groups do not provide usable geometry.")
        }

        // Slice spacing from adjacent position deltas (ordering already
        // validated the projections); duplicates are ambiguous.
        var zSpacing = firstFrame.functionalGroups.pixelMeasures?.spacingBetweenSlices
            ?? firstFrame.functionalGroups.pixelMeasures?.sliceThickness
            ?? 1.0
        if positions.count >= 2 {
            let deltas = zip(positions.dropFirst(), positions).map(-)
            guard deltas.allSatisfy({ $0 > 1e-9 }) else {
                throw DicomSeriesLoaderError.duplicateSlicePosition
            }
            let median = deltas.sorted()[deltas.count / 2]
            let maxDeviation = deltas.map { abs($0 - median) }.max() ?? 0
            guard maxDeviation <= max(0.01, median * 0.05) else {
                throw DicomSeriesLoaderError.variableSliceSpacing(median: median, maxDeviation: maxDeviation)
            }
            zSpacing = median
        }

        // Decode frames one at a time, in spatial order, into the volume.
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let width = decoder.width
        let height = decoder.height
        let pixelsPerFrame = width * height
        var voxels = Data(count: pixelsPerFrame * orderedFrames.count * MemoryLayout<Int16>.size)
        var sliceRescale = [DicomSliceRescaleParameters]()
        let fallbackRescale = decoder.rescaleParametersV2

        try voxels.withUnsafeMutableBytes { rawBuffer in
            let destination = rawBuffer.bindMemory(to: Int16.self)
            for (sliceIndex, frame) in orderedFrames.enumerated() {
                let decoded: DicomDecodedFrame
                do {
                    decoded = try frameReader.frame(at: frame.index)
                } catch let error as DicomDecodedFrameReader.ReadError {
                    if case .unsupportedTransferSyntax(_, let diagnostics) = error {
                        throw enhancedError(format, sopClassUID: sopClassUID,
                                            reason: "frame \(frame.index) cannot decode: \(diagnostics.joined(separator: " "))")
                    }
                    throw DicomSeriesLoaderError.failedToDecode(url)
                }

                let base = sliceIndex * pixelsPerFrame
                switch decoded.pixels {
                case .gray16(let pixels):
                    guard pixels.count == pixelsPerFrame else { throw DicomSeriesLoaderError.failedToDecode(url) }
                    if format.pixelRepresentation == 1 {
                        for index in 0..<pixelsPerFrame {
                            destination[base + index] = Int16(truncatingIfNeeded: Int32(pixels[index]) + Int32(Int16.min))
                        }
                    } else {
                        for index in 0..<pixelsPerFrame {
                            destination[base + index] = Int16(bitPattern: pixels[index])
                        }
                    }
                case .gray8(let pixels):
                    guard pixels.count == pixelsPerFrame else { throw DicomSeriesLoaderError.failedToDecode(url) }
                    if format.pixelRepresentation == 1 {
                        // The decoded surface offsets signed 8-bit samples by
                        // +128; undo to recover stored values.
                        for index in 0..<pixelsPerFrame {
                            destination[base + index] = Int16(Int(pixels[index]) - 128)
                        }
                    } else {
                        for index in 0..<pixelsPerFrame {
                            destination[base + index] = Int16(pixels[index])
                        }
                    }
                case .rgb8:
                    throw enhancedError(format, sopClassUID: sopClassUID,
                                        reason: "frame \(frame.index) decoded as color; multiframe assembly is grayscale-only.")
                }

                let transformation = frame.functionalGroups.pixelValueTransformation
                sliceRescale.append(DicomSliceRescaleParameters(
                    slope: transformation?.rescaleSlope ?? fallbackRescale.slope,
                    intercept: transformation?.rescaleIntercept ?? fallbackRescale.intercept
                ))
            }
        }

        let normal = simd_normalize(orientation.normal)
        let orientationMatrix = simd_double3x3(columns: (
            simd_normalize(orientation.row),
            simd_normalize(orientation.column),
            normal
        ))
        let sliceVOIs = orderedFrames.map { $0.functionalGroups.frameVOI }
        let frameDefaultWindow = sliceVOIs.compactMap { $0?.windows.first }.first
        let topLevelWindow = windowCenterWidth(from: decoder)

        return DicomSeriesVolume(
            voxels: voxels,
            width: width,
            height: height,
            depth: orderedFrames.count,
            spacing: SIMD3<Double>(pixelSpacing.y, pixelSpacing.x, zSpacing),
            orientation: orientationMatrix,
            origin: firstPosition,
            rescaleSlope: sliceRescale.first?.slope ?? fallbackRescale.slope,
            rescaleIntercept: sliceRescale.first?.intercept ?? fallbackRescale.intercept,
            bitsAllocated: format.bitsAllocated,
            isSignedPixel: format.pixelRepresentation == 1,
            patientName: decoder.info(for: .patientName),
            seriesDescription: decoder.info(for: .seriesDescription),
            studyDescription: nonEmptyValue(decoder.info(for: .studyDescription)),
            modality: decoder.info(for: .modality),
            windowCenter: frameDefaultWindow?.center ?? topLevelWindow?.center,
            windowWidth: frameDefaultWindow?.width ?? topLevelWindow?.width,
            studyInstanceUID: nonEmptyValue(decoder.info(for: .studyInstanceUID)),
            seriesInstanceUID: nonEmptyValue(decoder.info(for: .seriesInstanceUID)),
            frameOfReferenceUID: nonEmptyValue(decoder.info(for: .frameOfReferenceUID)),
            sliceRescaleParameters: sliceRescale,
            sliceVOIs: sliceVOIs
        )
    }

    private func enhancedPixelFormat(from decoder: any DicomDecoderProtocol) -> DicomSeriesLoaderPixelFormat {
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let transferSyntaxUID = decoder.info(for: .transferSyntaxUID)
        return DicomSeriesLoaderPixelFormat(
            bitsAllocated: decoder.bitDepth,
            bitsStored: bitsStored,
            highBit: decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1),
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation.isEmpty
                ? "MONOCHROME2"
                : decoder.photometricInterpretation,
            planarConfiguration: decoder.intValue(for: .planarConfiguration),
            numberOfFrames: decoder.nImages,
            transferSyntaxUID: transferSyntaxUID,
            isCompressed: DicomTransferSyntax(uid: transferSyntaxUID)?.isCompressed ?? false
        )
    }

    private func validatedSingleStackFrames(
        _ groups: DicomEnhancedMultiframeFunctionalGroups,
        format: DicomSeriesLoaderPixelFormat,
        sopClassUID: String
    ) throws -> [DicomEnhancedFrame] {
        guard let organization = groups.dimensionOrganization else {
            let hasUnresolvedDimensions = groups.frames.contains { frame in
                guard let content = frame.functionalGroups.frameContent else { return false }
                return nonEmptyValue(content.stackID ?? "") != nil
                    || content.inStackPositionNumber != nil
                    || !content.dimensionIndexValues.isEmpty
            }
            if hasUnresolvedDimensions {
                throw enhancedError(
                    format,
                    sopClassUID: sopClassUID,
                    reason: "frame dimensions are present without Dimension Organization definitions; "
                        + "the frames remain available in 2D."
                )
            }
            return groups.framesInSpatialOrder
        }

        let frameContentPointer = DicomTag.frameContentSequence.rawValue
        guard organization.organizationUIDs.count == 1,
              let organizationUID = nonEmptyValue(organization.organizationUIDs[0]),
              organization.indexes.count == 2,
              organization.indexes.allSatisfy({
                  $0.organizationUID == organizationUID
                      && $0.functionalGroupPointer == frameContentPointer
              }),
              let stackIndex = organization.indexes.firstIndex(where: {
                  $0.dimensionIndexPointer == DicomTag.stackID.rawValue
              }),
              let positionIndex = organization.indexes.firstIndex(where: {
                  $0.dimensionIndexPointer == DicomTag.inStackPositionNumber.rawValue
              }),
              stackIndex != positionIndex else {
            throw enhancedError(
                format,
                sopClassUID: sopClassUID,
                reason: "unsupported Dimension Index pattern; volume mode accepts only Stack ID plus "
                    + "In-Stack Position Number. The frames remain available in 2D."
            )
        }

        var logicalStacks = Set<String>()
        var dimensionPositions = Set<String>()
        for frame in groups.frames {
            guard let content = frame.functionalGroups.frameContent,
                  let stackID = nonEmptyValue(content.stackID ?? ""),
                  let inStackPositionNumber = content.inStackPositionNumber,
                  content.dimensionIndexValues.count == organization.indexes.count,
                  content.dimensionIndexValues.allSatisfy({ $0 > 0 }),
                  content.dimensionIndexValues[positionIndex] == inStackPositionNumber else {
                throw enhancedError(
                    format,
                    sopClassUID: sopClassUID,
                    reason: "a frame has incomplete Stack ID, In-Stack Position Number, or Dimension Index Values; "
                        + "the frames remain available in 2D."
                )
            }
            let stackKey = "\(content.dimensionIndexValues[stackIndex])|\(stackID)"
            logicalStacks.insert(stackKey)
            let positionKey = "\(stackKey)|\(content.dimensionIndexValues[positionIndex])"
            guard dimensionPositions.insert(positionKey).inserted else {
                throw enhancedError(
                    format,
                    sopClassUID: sopClassUID,
                    reason: "the selected stack has duplicate Dimension Index positions; "
                        + "the frames remain available in 2D."
                )
            }
        }

        guard logicalStacks.count == 1 else {
            throw enhancedError(
                format,
                sopClassUID: sopClassUID,
                reason: "multiple logical stacks are present; volume mode supports one stack only. "
                    + "The frames remain available in 2D."
            )
        }
        return groups.framesInSpatialOrder
    }

    private func enhancedError(
        _ format: DicomSeriesLoaderPixelFormat,
        sopClassUID: String,
        reason: String
    ) -> DicomSeriesLoaderError {
        .unsupportedEnhancedMultiframe(DicomSeriesLoaderError.EnhancedMultiframeContext(
            sopClassUID: sopClassUID.isEmpty ? "<unknown>" : sopClassUID,
            frameCount: format.numberOfFrames,
            transferSyntaxUID: format.transferSyntaxUID,
            reason: reason
        ))
    }
}

private func nonEmptyValue(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
