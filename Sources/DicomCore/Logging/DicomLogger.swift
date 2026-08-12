//
//  DicomLogger.swift
//
//  Concrete implementation of LoggerProtocol using OSLog when the module is
//  available and an NSLog fallback on other platforms.
//
//  Thread Safety: All methods are thread-safe. OSLog and NSLog both handle
//  concurrent access internally without requiring external synchronization.
//

import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Concrete logger implementation using OSLog when the module is available
/// and falling back to NSLog on other platforms.
///
/// **Thread Safety:** All logging methods are thread-safe. Both OSLog and NSLog
/// handle concurrent access internally without data races.
///
/// **Platform Compatibility:** Uses OSLog with structured logging when the
/// module is available and NSLog otherwise.
///
/// **Usage:**
/// ```swift
/// let logger = DicomLogger.make(subsystem: "com.example.dicom", category: "decoder")
/// logger.info("Starting DICOM file processing")
/// logger.error("Failed to read pixel data")
/// ```
public struct DicomLogger: LoggerProtocol {

    // MARK: - Private Properties

    private let _debug: (String) -> Void
    private let _info: (String) -> Void
    private let _warning: (String) -> Void
    private let _error: (String) -> Void

    // MARK: - Initialization

    /// Private initializer. Use `make(subsystem:category:)` factory method instead.
    private init(
        debug: @escaping (String) -> Void,
        info: @escaping (String) -> Void,
        warning: @escaping (String) -> Void,
        error: @escaping (String) -> Void
    ) {
        self._debug = debug
        self._info = info
        self._warning = warning
        self._error = error
    }

    // MARK: - Factory Method

    /// Creates a logger instance with OSLog or an NSLog fallback when the module is unavailable.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (typically reverse DNS, e.g., "com.example.dicom")
    ///   - category: The category for log messages (e.g., "decoder", "networking")
    /// - Returns: A configured logger instance conforming to LoggerProtocol
    public static func make(subsystem: String, category: String) -> LoggerProtocol {
        #if canImport(OSLog)
        let logger = Logger(subsystem: subsystem, category: category)
        return DicomLogger(
            debug: { logger.debug("\($0, privacy: .public)") },
            info: { logger.info("\($0, privacy: .public)") },
            warning: { logger.warning("\($0, privacy: .public)") },
            error: { logger.error("\($0, privacy: .public)") }
        )
        #else
        // Fallback for platforms without OSLog.
        return DicomLogger(
            debug: { NSLog("[DEBUG] %@", $0) },
            info: { NSLog("[INFO] %@", $0) },
            warning: { NSLog("[WARN] %@", $0) },
            error: { NSLog("[ERROR] %@", $0) }
        )
        #endif
    }

    // MARK: - LoggerProtocol Implementation

    /// Logs a debug-level message.
    /// Use for detailed diagnostic information useful during development.
    ///
    /// - Parameter message: The message to log
    public func debug(_ message: String) {
        _debug(message)
    }

    /// Logs an informational message.
    /// Use for general informational messages about normal operation.
    ///
    /// - Parameter message: The message to log
    public func info(_ message: String) {
        _info(message)
    }

    /// Logs a warning message.
    /// Use for potentially problematic situations that don't prevent operation.
    ///
    /// - Parameter message: The message to log
    public func warning(_ message: String) {
        _warning(message)
    }

    /// Logs an error message.
    /// Use for error conditions that may require attention but allow recovery.
    ///
    /// - Parameter message: The message to log
    public func error(_ message: String) {
        _error(message)
    }
}
