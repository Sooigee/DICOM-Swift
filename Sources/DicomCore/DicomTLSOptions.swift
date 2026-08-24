import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Network)
enum DicomTLSRole: Sendable {
    case client
    case server
}

struct DicomPreparedNetworkParameters {
    let parameters: NWParameters
    let tlsContext: DicomAppliedTLSContext?
    /// Non-nil whenever a verify block is installed; holds the chain that was
    /// rejected, if one was.
    let tlsRejectionRecorder: DicomTLSRejectionRecorder?

    init(parameters: NWParameters,
         tlsContext: DicomAppliedTLSContext?,
         tlsRejectionRecorder: DicomTLSRejectionRecorder? = nil) {
        self.parameters = parameters
        self.tlsContext = tlsContext
        self.tlsRejectionRecorder = tlsRejectionRecorder
    }
}

/// Thread-safe slot holding the peer chain that most recently failed trust
/// evaluation on a connection, so the transport can turn an opaque handshake
/// failure into a chain the caller can show and pin.
final class DicomTLSRejectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: DicomTLSPeerIdentity?

    func record(_ identity: DicomTLSPeerIdentity) {
        lock.lock()
        self.identity = identity
        lock.unlock()
    }

    var recorded: DicomTLSPeerIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }
}

final class DicomAppliedTLSContext {
    let role: DicomTLSRole
    let serverName: String?
    let hasLocalIdentity: Bool
    let trustedCertificateCount: Int
    let securityProfile: DicomTLSSecurityProfile
    let minimumProtocolVersionName: String?
    let peerAuthenticationRequired: Bool

    #if canImport(Security)
    private let protocolIdentity: sec_identity_t?
    #endif
    #if canImport(Security) && os(macOS)
    private let temporaryKeychain: DicomTemporaryKeychain?
    #endif

    #if canImport(Security) && os(macOS)
    init(role: DicomTLSRole,
         serverName: String?,
         hasLocalIdentity: Bool,
         trustedCertificateCount: Int,
         securityProfile: DicomTLSSecurityProfile,
         minimumProtocolVersionName: String?,
         peerAuthenticationRequired: Bool,
         protocolIdentity: sec_identity_t?,
         temporaryKeychain: DicomTemporaryKeychain?) {
        self.role = role
        self.serverName = serverName
        self.hasLocalIdentity = hasLocalIdentity
        self.trustedCertificateCount = trustedCertificateCount
        self.securityProfile = securityProfile
        self.minimumProtocolVersionName = minimumProtocolVersionName
        self.peerAuthenticationRequired = peerAuthenticationRequired
        self.protocolIdentity = protocolIdentity
        self.temporaryKeychain = temporaryKeychain
    }
    #elseif canImport(Security)
    init(role: DicomTLSRole,
         serverName: String?,
         hasLocalIdentity: Bool,
         trustedCertificateCount: Int,
         securityProfile: DicomTLSSecurityProfile,
         minimumProtocolVersionName: String?,
         peerAuthenticationRequired: Bool,
         protocolIdentity: sec_identity_t? = nil) {
        self.role = role
        self.serverName = serverName
        self.hasLocalIdentity = hasLocalIdentity
        self.trustedCertificateCount = trustedCertificateCount
        self.securityProfile = securityProfile
        self.minimumProtocolVersionName = minimumProtocolVersionName
        self.peerAuthenticationRequired = peerAuthenticationRequired
        self.protocolIdentity = protocolIdentity
    }
    #else
    init(role: DicomTLSRole,
         serverName: String?,
         hasLocalIdentity: Bool,
         trustedCertificateCount: Int,
         securityProfile: DicomTLSSecurityProfile,
         minimumProtocolVersionName: String?,
         peerAuthenticationRequired: Bool) {
        self.role = role
        self.serverName = serverName
        self.hasLocalIdentity = hasLocalIdentity
        self.trustedCertificateCount = trustedCertificateCount
        self.securityProfile = securityProfile
        self.minimumProtocolVersionName = minimumProtocolVersionName
        self.peerAuthenticationRequired = peerAuthenticationRequired
    }
    #endif
}

#if canImport(Security)
/// DER-encoded peer certificates, leaf first.
///
/// `SecTrustCopyCertificateChain` only exists from macOS 12 / iOS 15, so the
/// deprecated index accessor stays as the fallback for the package's older
/// deployment targets.
func peerCertificateChain(from trust: SecTrust) -> [Data] {
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return chain.map { SecCertificateCopyData($0) as Data }
    }
    var chain: [Data] = []
    for index in 0..<SecTrustGetCertificateCount(trust) {
        guard let certificate = SecTrustGetCertificateAtIndex(trust, index) else { continue }
        chain.append(SecCertificateCopyData(certificate) as Data)
    }
    return chain
}

/// Lowercase hex SHA-256, the form `DicomTLSConfiguration.pinnedCertificateSHA256`
/// stores and `openssl x509 -fingerprint -sha256` prints.
func sha256Hex(of data: Data) -> String {
    #if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    return ""
    #endif
}
#endif

#if canImport(Security) && os(macOS)
/// A TLS client identity loaded from PEM files, for callers that have to hand
/// one to an API outside this package — `URLSession`'s authentication
/// challenge, say, which wants a `SecIdentity` rather than the file paths
/// `DicomTLSMaterial` takes.
///
/// The identity is only valid while the throwaway keychain backing it exists,
/// which is why the two are kept together: release this object and the
/// identity stops working.
public final class DicomTLSClientIdentity {

    public let identity: SecIdentity
    /// Any intermediates that came with the certificate, leaf excluded.
    public let certificates: [SecCertificate]
    private let keychain: DicomTemporaryKeychain

    fileprivate init(identity: SecIdentity, certificates: [SecCertificate], keychain: DicomTemporaryKeychain) {
        self.identity = identity
        self.certificates = certificates
        self.keychain = keychain
    }

    /// Loads a client identity from a PEM certificate and its PEM private key.
    ///
    /// Throws `DicomNetworkError.tlsConfigurationInvalid` when either file is
    /// unreadable, holds the wrong kind of material, or the key does not match
    /// the certificate.
    public static func load(certificatePath: String, privateKeyPath: String) throws -> DicomTLSClientIdentity {
        let material = DicomTLSMaterial(certificatePath: certificatePath, privateKeyPath: privateKeyPath)
        let loaded = try DicomTLSOptionsFactory.clientIdentity(from: material)
        guard let identity = loaded.identity, let keychain = loaded.keychain else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS client identity could not be created.")
        }
        return DicomTLSClientIdentity(identity: identity,
                                      certificates: loaded.certificates,
                                      keychain: keychain)
    }
}
#endif

enum DicomTLSOptionsFactory {
    static func preparedParameters(for tls: DicomTLSConfiguration, role: DicomTLSRole) throws -> DicomPreparedNetworkParameters {
        switch tls.mode {
        case .disabled:
            return DicomPreparedNetworkParameters(parameters: .tcp, tlsContext: nil)
        case .enabled:
            let prepared = try preparedTLSOptions(for: tls, role: role)
            return DicomPreparedNetworkParameters(
                parameters: NWParameters(tls: prepared.options, tcp: NWProtocolTCP.Options()),
                tlsContext: prepared.context,
                tlsRejectionRecorder: prepared.recorder
            )
        }
    }

    static func minimumTLSProtocolVersionName(for profile: DicomTLSSecurityProfile) -> String? {
        switch profile {
        case .none:
            return nil
        case .nonDowngradingBCP195, .bcp195, .extendedBCP195:
            return "TLSv1.2"
        case .basicRetired, .aesRetired, .authenticatedUnencryptedRetired:
            return "TLSv1.0"
        }
    }

    private static func preparedTLSOptions(
        for tls: DicomTLSConfiguration,
        role: DicomTLSRole
    ) throws -> (options: NWProtocolTLS.Options, context: DicomAppliedTLSContext, recorder: DicomTLSRejectionRecorder?) {
        #if canImport(Security)
        let options = NWProtocolTLS.Options()
        if role == .client, let serverName = tls.serverName {
            serverName.withCString {
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, $0)
            }
        }
        if let version = minimumTLSProtocolVersion(for: tls.securityProfile) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, version)
        }
        let trustedCertificates = try trustAnchors(from: tls.material)
        let peerAuthenticationRequired = role == .client || !trustedCertificates.isEmpty
        sec_protocol_options_set_peer_authentication_required(
            options.securityProtocolOptions,
            peerAuthenticationRequired
        )

        #if os(macOS)
        let localIdentity = try clientIdentity(from: tls.material)
        var protocolIdentity: sec_identity_t?
        if let identity = localIdentity.identity {
            if localIdentity.certificates.isEmpty {
                protocolIdentity = sec_identity_create(identity)
            } else {
                protocolIdentity = sec_identity_create_with_certificates(identity, localIdentity.certificates as CFArray)
            }
            guard let protocolIdentity else {
                throw DicomNetworkError.tlsConfigurationInvalid("Unable to create protocol TLS identity.")
            }
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, protocolIdentity)
        }
        #else
        let hasIdentityMaterial = tls.material?.certificatePath != nil || tls.material?.privateKeyPath != nil
        if hasIdentityMaterial {
            throw DicomNetworkError.tlsConfigurationInvalid(
                "Separate certificate and private key TLS identity loading is only supported on macOS."
            )
        }
        #endif

        // A client always gets a verify block, even with no anchors and no
        // pins: rejecting a peer is only half the job, the caller also needs
        // the chain that was rejected so it can put a trust decision to the
        // operator. Servers keep the original behaviour of verifying only when
        // anchors were supplied.
        let pins = tls.pinnedCertificateSHA256
        let recorder: DicomTLSRejectionRecorder?
        if role == .client || !trustedCertificates.isEmpty {
            let rejectionRecorder = DicomTLSRejectionRecorder()
            recorder = rejectionRecorder
            let queue = DispatchQueue(label: "DicomTLSOptionsFactory.trust")
            let serverName = tls.serverName
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let derChain = peerCertificateChain(from: trust)
                let leafDigest = derChain.first.map(sha256Hex(of:)) ?? ""

                // A pin is the whole trust decision. Chain building, anchors,
                // and the platform's server policy are all bypassed, which is
                // deliberate: the operator already confirmed this exact
                // certificate, and privately-issued PACS certificates
                // routinely fail that policy on validity period alone.
                if !pins.isEmpty {
                    if !leafDigest.isEmpty, pins.contains(leafDigest) {
                        complete(true)
                        return
                    }
                    rejectionRecorder.record(DicomTLSPeerIdentity(
                        certificateChain: derChain,
                        leafSHA256: leafDigest,
                        reason: "The server presented a certificate that does not match the one previously trusted for it."
                    ))
                    complete(false)
                    return
                }

                if !trustedCertificates.isEmpty {
                    let setAnchorsStatus = SecTrustSetAnchorCertificates(trust, trustedCertificates as CFArray)
                    let setOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
                    let policy = role == .client
                        ? SecPolicyCreateSSL(true, serverName as CFString?)
                        : SecPolicyCreateBasicX509()
                    let setPolicyStatus = SecTrustSetPolicies(trust, policy)
                    guard setAnchorsStatus == errSecSuccess,
                          setOnlyStatus == errSecSuccess,
                          setPolicyStatus == errSecSuccess else {
                        rejectionRecorder.record(DicomTLSPeerIdentity(
                            certificateChain: derChain,
                            leafSHA256: leafDigest,
                            reason: "The supplied trust anchors could not be applied to the server's certificate."
                        ))
                        complete(false)
                        return
                    }
                }

                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) {
                    complete(true)
                    return
                }
                let reason = (error as Error?).map { ($0 as NSError).localizedDescription }
                    ?? "The certificate could not be verified."
                rejectionRecorder.record(DicomTLSPeerIdentity(certificateChain: derChain,
                                                              leafSHA256: leafDigest,
                                                              reason: reason))
                complete(false)
            }, queue)
        } else {
            recorder = nil
        }

        #if os(macOS)
        let context = DicomAppliedTLSContext(
            role: role,
            serverName: tls.serverName,
            hasLocalIdentity: localIdentity.identity != nil,
            trustedCertificateCount: trustedCertificates.count,
            securityProfile: tls.securityProfile,
            minimumProtocolVersionName: minimumTLSProtocolVersionName(for: tls.securityProfile),
            peerAuthenticationRequired: peerAuthenticationRequired,
            protocolIdentity: protocolIdentity,
            temporaryKeychain: localIdentity.keychain
        )
        #else
        let context = DicomAppliedTLSContext(
            role: role,
            serverName: tls.serverName,
            hasLocalIdentity: false,
            trustedCertificateCount: trustedCertificates.count,
            securityProfile: tls.securityProfile,
            minimumProtocolVersionName: minimumTLSProtocolVersionName(for: tls.securityProfile),
            peerAuthenticationRequired: peerAuthenticationRequired,
            protocolIdentity: nil
        )
        #endif
        return (options, context, recorder)
        #else
        throw DicomNetworkError.tlsConfigurationInvalid(
            "Security.framework is not available for TLS configuration."
        )
        #endif
    }

    #if canImport(Security)
    private static func minimumTLSProtocolVersion(for profile: DicomTLSSecurityProfile) -> tls_protocol_version_t? {
        switch profile {
        case .none:
            return nil
        case .nonDowngradingBCP195, .bcp195, .extendedBCP195:
            return .TLSv12
        case .basicRetired, .aesRetired, .authenticatedUnencryptedRetired:
            return tls_protocol_version_t(rawValue: 0x0301)
        }
    }

    private static func trustAnchors(from material: DicomTLSMaterial?) throws -> [SecCertificate] {
        guard let material else { return [] }
        let paths = ([material.trustStorePath] + material.trustedCertificatePaths)
            .compactMap { $0 }
        var anchors: [SecCertificate] = []
        for path in paths {
            anchors.append(contentsOf: try certificates(at: path, purpose: "TLS trust store"))
        }
        return anchors
    }

    private static func certificates(at path: String, purpose: String) throws -> [SecCertificate] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is not readable: \(path)")
        }
        guard !data.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is empty: \(path)")
        }
        let derBlobs = try certificateDERBlobs(from: data, path: path)
        let certificates = derBlobs.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard certificates.count == derBlobs.count, !certificates.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) does not contain a valid certificate: \(path)")
        }
        return certificates
    }

    private static func certificateDERBlobs(from data: Data, path: String) throws -> [Data] {
        guard let pem = String(data: data, encoding: .utf8),
              pem.contains("-----BEGIN CERTIFICATE-----") else {
            return [data]
        }
        var blobs: [Data] = []
        var searchStart = pem.startIndex
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        while let begin = pem.range(of: beginMarker, range: searchStart..<pem.endIndex),
              let end = pem.range(of: endMarker, range: begin.upperBound..<pem.endIndex) {
            let encoded = pem[begin.upperBound..<end.lowerBound]
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(encoded)) else {
                throw DicomNetworkError.tlsConfigurationInvalid("Invalid PEM certificate block: \(path)")
            }
            blobs.append(der)
            searchStart = end.upperBound
        }
        guard !blobs.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("No PEM certificates found: \(path)")
        }
        return blobs
    }
    #endif

    #if canImport(Security) && os(macOS)
    static func clientIdentity(
        from material: DicomTLSMaterial?
    ) throws -> (identity: SecIdentity?, certificates: [SecCertificate], keychain: DicomTemporaryKeychain?) {
        guard let material else { return (nil, [], nil) }
        let hasCertificate = material.certificatePath != nil
        let hasPrivateKey = material.privateKeyPath != nil
        guard hasCertificate || hasPrivateKey else { return (nil, [], nil) }
        guard let certificatePath = material.certificatePath else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate path is missing.")
        }
        guard let privateKeyPath = material.privateKeyPath else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS private key path is missing.")
        }
        let keychain = try DicomTemporaryKeychain()
        let certificates = try keychain.importCertificates(path: certificatePath)
        guard let certificate = certificates.first else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate import did not produce a certificate: \(certificatePath)")
        }
        try keychain.importPrivateKey(path: privateKeyPath)
        return (try keychain.identity(for: certificate), Array(certificates.dropFirst()), keychain)
    }
    #endif
}

#if canImport(Security) && os(macOS)
/// Documented platform compatibility shim (issue #1221): the legacy
/// `SecKeychain*` file-based keychain API is deprecated since macOS 10.10,
/// but it remains the only supported way to mint a `SecIdentity` from PEM
/// certificate/key material in an isolated, throwaway store for DIMSE TLS —
/// the modern data-protection keychain (`SecItem*`) cannot host an imported
/// identity for this flow without app-level keychain entitlements that a
/// library cannot assume. The three deprecation warnings emitted by this
/// type (`SecKeychainCreate`/`SecKeychainUnlock`/`SecKeychainDelete`) are
/// intentional and confined to this shim.
final class DicomTemporaryKeychain {
    typealias UnlockKeychain = (SecKeychain, UInt32, UnsafeRawPointer?, Bool) -> OSStatus

    private let fileURL: URL
    private let keychain: SecKeychain
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        unlockKeychain: UnlockKeychain = { keychain, passwordLength, password, usePassword in
            SecKeychainUnlock(keychain, passwordLength, password, usePassword)
        }
    ) throws {
        let directory = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("DicomDecoderTLS-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychainURL = directory.appendingPathComponent("identity.keychain-db")

        var keychainRef: SecKeychain?
        let password = "dicom-swift-tls"
        let status = password.withCString {
            SecKeychainCreate(keychainURL.path, UInt32(strlen($0)), $0, false, nil, &keychainRef)
        }
        guard status == errSecSuccess, let keychainRef else {
            try? fileManager.removeItem(at: directory)
            throw DicomNetworkError.tlsConfigurationInvalid("Unable to create temporary TLS keychain: \(status).")
        }
        let unlockStatus = password.withCString {
            unlockKeychain(keychainRef, UInt32(strlen($0)), UnsafeRawPointer($0), true)
        }
        guard unlockStatus == errSecSuccess else {
            Self.cleanup(keychain: keychainRef, fileURL: keychainURL, fileManager: fileManager)
            throw DicomNetworkError.tlsConfigurationInvalid("Unable to unlock temporary TLS keychain: \(unlockStatus).")
        }
        fileURL = keychainURL
        keychain = keychainRef
        self.fileManager = fileManager
    }

    deinit {
        Self.cleanup(keychain: keychain, fileURL: fileURL, fileManager: fileManager)
    }

    private static func cleanup(keychain: SecKeychain?, fileURL: URL, fileManager: FileManager) {
        if let keychain {
            SecKeychainDelete(keychain)
        }
        try? fileManager.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func importCertificates(path: String) throws -> [SecCertificate] {
        let items: [AnyObject]
        if let importedItems = try importItem(
            path: path,
            purpose: "TLS certificate",
            inputFormat: .formatPEMSequence,
            itemType: .itemTypeAggregate
        ) {
            items = importedItems
        } else if let importedItems = try importItem(
            path: path,
            purpose: "TLS certificate",
            inputFormat: .formatUnknown,
            itemType: .itemTypeUnknown,
            flags: SecItemImportExportFlags()
        ) {
            items = importedItems
        } else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate import failed: \(path)")
        }
        let certificates = items.compactMap { item in
            CFGetTypeID(item) == SecCertificateGetTypeID() ? unsafeBitCast(item, to: SecCertificate.self) : nil
        }
        guard !certificates.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS certificate import did not produce a certificate: \(path)")
        }
        return certificates
    }

    func importPrivateKey(path: String) throws {
        guard let items = try importItem(
            path: path,
            purpose: "TLS private key",
            inputFormat: .formatUnknown,
            itemType: .itemTypeUnknown,
            flags: SecItemImportExportFlags()
        ) else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS private key import failed: \(path)")
        }
        guard firstItem(in: items, typeID: SecKeyGetTypeID(), as: SecKey.self) != nil else {
            throw DicomNetworkError.tlsConfigurationInvalid("TLS private key import did not produce a key: \(path)")
        }
    }

    func identity(for certificate: SecCertificate) throws -> SecIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw DicomNetworkError.tlsConfigurationInvalid(
                "TLS private key does not match certificate or identity could not be created: \(status)."
            )
        }
        return identity
    }

    private func importItem(
        path: String,
        purpose: String,
        inputFormat: SecExternalFormat,
        itemType: SecExternalItemType,
        flags: SecItemImportExportFlags = SecItemImportExportFlags(rawValue: 0x00000001)
    ) throws -> [AnyObject]? {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is not readable: \(path)")
        }
        guard !data.isEmpty else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) is empty: \(path)")
        }
        var format = inputFormat
        var importedItemType = itemType
        var items: CFArray?
        var keyParameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: SecKeyImportExportFlags(),
            passphrase: nil,
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )
        let status = withUnsafePointer(to: &keyParameters) {
            SecItemImport(
                data as CFData,
                (path as NSString).lastPathComponent as CFString,
                &format,
                &importedItemType,
                flags,
                $0,
                keychain,
                &items
            )
        }
        guard status == errSecSuccess else {
            return nil
        }
        guard let items else {
            throw DicomNetworkError.tlsConfigurationInvalid("\(purpose) import failed: \(status).")
        }
        return items as [AnyObject]
    }

    private func firstItem<T: AnyObject>(in items: [AnyObject], typeID: CFTypeID, as type: T.Type) -> T? {
        for item in items where CFGetTypeID(item) == typeID {
            return unsafeBitCast(item, to: T.self)
        }
        return nil
    }
}
#endif
#endif
