import Foundation

enum DicomDataValueDecoder {
    static func binaryValue(
        for vr: DicomVR,
        data: Data,
        littleEndian: Bool
    ) -> DicomDataValue? {
        switch vr {
        case .FD, .OD:
            return .floats(data.dicomFloat64Values(littleEndian: littleEndian))
        case .FL, .OF:
            return .floats(data.dicomFloat32Values(littleEndian: littleEndian).map(Double.init))
        case .SL:
            return .signedIntegers(
                data.dicomIntegerValues(as: UInt32.self, littleEndian: littleEndian)
                    .map { Int(Int32(bitPattern: $0)) }
            )
        case .SS:
            return .signedIntegers(
                data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian)
                    .map { Int(Int16(bitPattern: $0)) }
            )
        case .UL:
            return .unsignedIntegers(
                data.dicomIntegerValues(as: UInt32.self, littleEndian: littleEndian).map(UInt.init)
            )
        case .US:
            return .unsignedIntegers(
                data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian).map(UInt.init)
            )
        case .AT:
            let components = data.dicomIntegerValues(as: UInt16.self, littleEndian: littleEndian)
            guard components.count.isMultiple(of: 2) else { return .empty }
            return .unsignedIntegers(stride(from: 0, to: components.count, by: 2).map { index in
                UInt(components[index]) << 16 | UInt(components[index + 1])
            })
        case .OB, .OW, .OV, .UN:
            return .bytes(Data(data))
        default:
            return nil
        }
    }
}
