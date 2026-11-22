import CryptoKit
import Darwin
import Foundation
import Security

public enum CodeTrust {
    public static let expectedIdentifier = "io.github.jardondiego.hotkeyd"

    private static let statusValidMask: UInt32 = SecCodeStatus.valid.rawValue
    private static let statusDebuggedMask: UInt32 = SecCodeStatus.debugged.rawValue

    private static let forbiddenRelaxationEntitlements: [String] = [
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.debugger"
    ]

    public struct TrustReport: Sendable, Equatable {
        public let binaryPath: String
        public let identifier: String
        public let flags: UInt32
        public let isAdhoc: Bool
        public let hasHardenedRuntime: Bool
        public let designatedRequirement: String
        public let isLeafAnchored: Bool
        public let hasBoundInfoPlist: Bool

        public init(
            binaryPath: String,
            identifier: String,
            flags: UInt32,
            isAdhoc: Bool,
            hasHardenedRuntime: Bool,
            designatedRequirement: String,
            isLeafAnchored: Bool,
            hasBoundInfoPlist: Bool
        ) {
            self.binaryPath = binaryPath
            self.identifier = identifier
            self.flags = flags
            self.isAdhoc = isAdhoc
            self.hasHardenedRuntime = hasHardenedRuntime
            self.designatedRequirement = designatedRequirement
            self.isLeafAnchored = isLeafAnchored
            self.hasBoundInfoPlist = hasBoundInfoPlist
        }
    }

    public enum TrustError: LocalizedError, Equatable {
        case forbiddenBuildOrTempPath(String)
        case missingOrInvalidSignature(String, OSStatus)
        case unexpectedIdentifier(expected: String, actual: String)
        case debugGetTaskAllowEntitlement(String)
        case dangerousRelaxationEntitlement(String, String)
        case missingHardenedRuntime(String)
        case adhocSignatureDisallowed(String)
        case unanchoredDesignatedRequirement(String)
        case executableMismatch(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .forbiddenBuildOrTempPath(let path):
                return "refusing untrusted binary path '\(path)' inside a build or temporary directory (/.build, /tmp); install with `./scripts/build.sh`"
            case .missingOrInvalidSignature(let path, let status):
                return "code signature verification failed for '\(path)' (OSStatus \(status)); rebuild with `./scripts/build.sh`"
            case .unexpectedIdentifier(let expected, let actual):
                return "binary has code signing identifier '\(actual)'; expected '\(expected)'"
            case .debugGetTaskAllowEntitlement(let path):
                return "refusing debug binary '\(path)' carrying com.apple.security.get-task-allow (/.build debug build exposes task_for_pid); install a release build with `./scripts/build.sh`"
            case .dangerousRelaxationEntitlement(let path, let entitlement):
                return "refusing binary '\(path)' carrying dangerous Hardened Runtime relaxation entitlement '\(entitlement)'"
            case .missingHardenedRuntime(let path):
                return "refusing binary '\(path)' signed without Hardened Runtime (--options runtime / CS_RUNTIME); rebuild with `./scripts/build.sh`"
            case .adhocSignatureDisallowed(let path):
                return "refusing ad-hoc signed binary '\(path)'; run `./scripts/setup-signing.sh` and `./scripts/build.sh` (or pass --allow-adhoc for local dev)"
            case .unanchoredDesignatedRequirement(let requirement):
                return "designated requirement '\(requirement)' is not anchored to a certificate leaf (certificate leaf = H\"...\"); run `./scripts/setup-signing.sh` and `./scripts/build.sh`"
            case .executableMismatch(let expected, let actual):
                return "running executable inode ('\(actual)') does not match verified on-disk binary ('\(expected)')"
            }
        }
    }

    public static func isForbiddenInstallPath(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for candidate in [path, resolved] {
            if candidate.contains("/.build/")
                || candidate.hasPrefix("/tmp/")
                || candidate.hasPrefix("/private/tmp/")
                || candidate.hasPrefix("/var/tmp/")
                || candidate.hasPrefix("/private/var/tmp/") {
                return true
            }
        }
        return false
    }

    public static func verify(binaryPath: String, allowAdhoc: Bool = false) throws -> TrustReport {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: binaryPath) as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw TrustError.missingOrInvalidSignature(binaryPath, createStatus)
        }

        let validityFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validityFlags, nil)
        guard validityStatus == errSecSuccess else {
            throw TrustError.missingOrInvalidSignature(binaryPath, validityStatus)
        }

        return try inspectCode(
            staticCode,
            liveCode: nil,
            binaryPath: binaryPath,
            allowAdhoc: allowAdhoc,
            checkInstallPath: true,
            includeDynamic: false,
            expectedOnDiskPath: nil
        )
    }

    /// Verifies the currently executing Mach task in memory (`SecCodeCopySelf`) and optionally
    /// confirms its main executable `(st_dev, st_ino)` matches `expectedBinaryPath` on disk.
    public static func verifyCurrentProcess(
        expectedBinaryPath: String? = nil,
        allowAdhoc: Bool = false
    ) throws -> TrustReport {
        var selfCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &selfCode)
        guard selfStatus == errSecSuccess, let selfCode else {
            throw TrustError.missingOrInvalidSignature("self", selfStatus)
        }
        let validityStatus = SecCodeCheckValidity(selfCode, [], nil)
        guard validityStatus == errSecSuccess else {
            throw TrustError.missingOrInvalidSignature("self", validityStatus)
        }
        var staticCodeRef: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(selfCode, [], &staticCodeRef)
        guard copyStaticStatus == errSecSuccess, let staticView = staticCodeRef else {
            throw TrustError.missingOrInvalidSignature("self", copyStaticStatus)
        }
        let strictStaticFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        let staticValidityStatus = SecStaticCodeCheckValidity(staticView, strictStaticFlags, nil)
        guard staticValidityStatus == errSecSuccess else {
            throw TrustError.missingOrInvalidSignature("self", staticValidityStatus)
        }
        return try withExtendedLifetime(selfCode) {
            try inspectCode(
                staticView,
                liveCode: selfCode,
                binaryPath: expectedBinaryPath ?? "self",
                allowAdhoc: allowAdhoc,
                checkInstallPath: expectedBinaryPath != nil,
                includeDynamic: true,
                expectedOnDiskPath: expectedBinaryPath
            )
        }
    }

    public static func verifyRunningProcess(
        pid: pid_t,
        expectedBinaryPath: String? = nil,
        allowAdhoc: Bool = false
    ) throws -> TrustReport {
        guard pid > 1 else {
            throw TrustError.missingOrInvalidSignature("pid:\(pid)", errSecParam)
        }
        var guestCode: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attrs, [], &guestCode)
        guard guestStatus == errSecSuccess, let guestCode else {
            throw TrustError.missingOrInvalidSignature("pid:\(pid)", guestStatus)
        }
        let validityStatus = SecCodeCheckValidity(guestCode, [], nil)
        guard validityStatus == errSecSuccess else {
            throw TrustError.missingOrInvalidSignature("pid:\(pid)", validityStatus)
        }
        guard let dynamicCode = asSecStaticCode(guestCode) else {
            throw TrustError.missingOrInvalidSignature("pid:\(pid)", errSecCSInvalidObjectRef)
        }
        return try withExtendedLifetime(guestCode) {
            try inspectCode(
                dynamicCode,
                liveCode: guestCode,
                binaryPath: expectedBinaryPath ?? "pid:\(pid)",
                allowAdhoc: allowAdhoc,
                checkInstallPath: expectedBinaryPath != nil,
                includeDynamic: true,
                expectedOnDiskPath: expectedBinaryPath
            )
        }
    }

    private static func asSecStaticCode(_ code: SecCode) -> SecStaticCode? {
        let obj = code as AnyObject
        guard CFGetTypeID(obj) == SecCodeGetTypeID() || CFGetTypeID(obj) == SecStaticCodeGetTypeID() else {
            return nil
        }
        return Unmanaged<SecStaticCode>.fromOpaque(Unmanaged.passUnretained(obj).toOpaque()).takeUnretainedValue()
    }

    private static func asSecRequirement(_ obj: Any) -> SecRequirement? {
        let ref = obj as AnyObject
        guard CFGetTypeID(ref) == SecRequirementGetTypeID() else { return nil }
        return Unmanaged<SecRequirement>.fromOpaque(Unmanaged.passUnretained(ref).toOpaque()).takeUnretainedValue()
    }

    private static func asSecCertificate(_ obj: Any) -> SecCertificate? {
        let ref = obj as AnyObject
        guard CFGetTypeID(ref) == SecCertificateGetTypeID() else { return nil }
        return Unmanaged<SecCertificate>.fromOpaque(Unmanaged.passUnretained(ref).toOpaque()).takeUnretainedValue()
    }

    private static func inspectCode(
        _ staticCode: SecStaticCode,
        liveCode: SecCode?,
        binaryPath: String,
        allowAdhoc: Bool,
        checkInstallPath: Bool,
        includeDynamic: Bool = false,
        expectedOnDiskPath: String?
    ) throws -> TrustReport {
        var infoRef: CFDictionary?
        var rawFlags = UInt32(kSecCSSigningInformation | kSecCSRequirementInformation)
        if includeDynamic {
            rawFlags |= UInt32(kSecCSDynamicInformation)
        }
        let infoFlags = SecCSFlags(rawValue: rawFlags)
        let infoStatus = SecCodeCopySigningInformation(staticCode, infoFlags, &infoRef)
        guard infoStatus == errSecSuccess, let dict = infoRef as? [String: Any] else {
            throw TrustError.missingOrInvalidSignature(binaryPath, infoStatus)
        }

        if includeDynamic {
            // Note: SecCodeCopySigningInformation(kSecCSDynamicInformation) requires passing the
            // live SecCode object (cast as SecStaticCode) so kSecCodeInfoStatus is populated.
            let statusSource: SecStaticCode
            if let liveCode, let liveAsStatic = asSecStaticCode(liveCode) {
                statusSource = liveAsStatic
            } else {
                statusSource = staticCode
            }
            var dynRef: CFDictionary?
            let dynStatus = SecCodeCopySigningInformation(
                statusSource,
                SecCSFlags(rawValue: UInt32(kSecCSDynamicInformation)),
                &dynRef
            )
            guard dynStatus == errSecSuccess,
                  let dynDict = dynRef as? [String: Any],
                  let status = dynDict[kSecCodeInfoStatus as String] as? UInt32 else {
                throw TrustError.missingOrInvalidSignature(binaryPath, dynStatus == errSecSuccess ? errSecCSUnsigned : dynStatus)
            }
            if (status & statusValidMask) == 0 {
                throw TrustError.missingOrInvalidSignature(binaryPath, errSecCSGuestInvalid)
            }
            if (status & statusDebuggedMask) != 0 {
                throw TrustError.debugGetTaskAllowEntitlement(binaryPath)
            }
        }

        if let expectedOnDiskPath,
           let mainExecURL = dict[kSecCodeInfoMainExecutable as String] as? URL {
            var expectedStat = stat()
            var actualStat = stat()
            guard lstat(expectedOnDiskPath, &expectedStat) == 0,
                  stat(mainExecURL.path, &actualStat) == 0,
                  (expectedStat.st_mode & S_IFMT) == S_IFREG,
                  expectedStat.st_dev == actualStat.st_dev,
                  expectedStat.st_ino == actualStat.st_ino else {
                throw TrustError.executableMismatch(expected: expectedOnDiskPath, actual: mainExecURL.path)
            }
        }

        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if Self.entitlementIsTrue(entitlements["com.apple.security.get-task-allow"]) {
                throw TrustError.debugGetTaskAllowEntitlement(binaryPath)
            }
            for key in forbiddenRelaxationEntitlements {
                if Self.entitlementIsTrue(entitlements[key]) {
                    throw TrustError.dangerousRelaxationEntitlement(binaryPath, key)
                }
            }
            for key in entitlements.keys.sorted() {
                if key.hasPrefix("com.apple.private.") || Self.entitlementIsTrue(entitlements[key]) {
                    throw TrustError.dangerousRelaxationEntitlement(binaryPath, key)
                }
            }
        } else if let rawEntData = dict[kSecCodeInfoEntitlements as String] as? Data, !rawEntData.isEmpty {
            throw TrustError.dangerousRelaxationEntitlement(binaryPath, "unparsed-der-entitlements")
        }

        if checkInstallPath && isForbiddenInstallPath(binaryPath) {
            throw TrustError.forbiddenBuildOrTempPath(binaryPath)
        }

        let identifier = (dict[kSecCodeInfoIdentifier as String] as? String) ?? ""
        guard identifier == expectedIdentifier else {
            throw TrustError.unexpectedIdentifier(expected: expectedIdentifier, actual: identifier)
        }

        let plistDict = dict[kSecCodeInfoPList as String] as? [String: Any]
        if let boundBundleID = plistDict?["CFBundleIdentifier"] as? String,
           boundBundleID != expectedIdentifier {
            throw TrustError.unexpectedIdentifier(expected: expectedIdentifier, actual: boundBundleID)
        }
        let hasBoundInfoPlist = (plistDict?["CFBundleIdentifier"] as? String) == expectedIdentifier

        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhocMask = SecCodeSignatureFlags.adhoc.rawValue
        let runtimeMask = SecCodeSignatureFlags.runtime.rawValue
        let isAdhoc = (flags & adhocMask) != 0
        let hasHardenedRuntime = (flags & runtimeMask) != 0

        guard hasHardenedRuntime else {
            throw TrustError.missingHardenedRuntime(binaryPath)
        }

        var designatedString = ""
        if let reqObj = dict[kSecCodeInfoDesignatedRequirement as String],
           let requirement = asSecRequirement(reqObj) {
            var cfReqStr: CFString?
            if withExtendedLifetime(reqObj, { SecRequirementCopyString(requirement, [], &cfReqStr) }) == errSecSuccess,
               let str = cfReqStr as String? {
                designatedString = str
            }
        }

        var leafSHA1Hex: String?
        if let certs = dict[kSecCodeInfoCertificates as String] as? [Any],
           let firstCert = certs.first,
           let leafCert = asSecCertificate(firstCert) {
            let certData = withExtendedLifetime(firstCert) { SecCertificateCopyData(leafCert) as Data }
            leafSHA1Hex = Insecure.SHA1.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        }

        let hasConjunctiveAnchor = !designatedString.contains(" or ")
            && designatedString.contains("identifier \"\(expectedIdentifier)\"")
            && ((leafSHA1Hex != nil && designatedString.lowercased().contains("certificate leaf = h\"\(leafSHA1Hex!)\""))
                || designatedString.contains("anchor apple"))

        if !allowAdhoc {
            if isAdhoc {
                throw TrustError.adhocSignatureDisallowed(binaryPath)
            }
            guard hasConjunctiveAnchor else {
                throw TrustError.unanchoredDesignatedRequirement(designatedString)
            }
            let strictReqString: String
            if let leafSHA1Hex, designatedString.lowercased().contains("certificate leaf = h\"\(leafSHA1Hex)\"") {
                strictReqString = "identifier \"\(expectedIdentifier)\" and certificate leaf = H\"\(leafSHA1Hex)\""
            } else {
                strictReqString = "identifier \"\(expectedIdentifier)\" and anchor apple"
            }
            var compiledReq: SecRequirement?
            let reqCreateStatus = SecRequirementCreateWithString(strictReqString as CFString, [], &compiledReq)
            guard reqCreateStatus == errSecSuccess, let compiledReq else {
                throw TrustError.unanchoredDesignatedRequirement(designatedString)
            }
            let anchorStatus: OSStatus
            if let liveCode {
                anchorStatus = SecCodeCheckValidity(
                    liveCode,
                    [],
                    compiledReq
                )
            } else {
                anchorStatus = SecStaticCodeCheckValidity(
                    staticCode,
                    SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)),
                    compiledReq
                )
            }
            guard anchorStatus == errSecSuccess else {
                throw TrustError.missingOrInvalidSignature(binaryPath, anchorStatus)
            }
        }

        return TrustReport(
            binaryPath: binaryPath,
            identifier: identifier,
            flags: flags,
            isAdhoc: isAdhoc,
            hasHardenedRuntime: hasHardenedRuntime,
            designatedRequirement: designatedString,
            isLeafAnchored: hasConjunctiveAnchor,
            hasBoundInfoPlist: hasBoundInfoPlist
        )
    }

    private static func entitlementIsTrue(_ value: Any?) -> Bool {
        if let boolVal = value as? Bool {
            return boolVal
        }
        if let numVal = value as? NSNumber {
            return numVal.boolValue
        }
        return false
    }
}
