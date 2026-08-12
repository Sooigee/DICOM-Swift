/// Resolved Frame VOI LUT Functional Group values for one frame.
public struct DicomFrameVOI: Equatable, Sendable {
    public let windows: [DicomFrameVOIWindow]
    public let lutFunction: String?

    public init(windows: [DicomFrameVOIWindow], lutFunction: String? = nil) {
        self.windows = windows
        self.lutFunction = lutFunction
    }
}
