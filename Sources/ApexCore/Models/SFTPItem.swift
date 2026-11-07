import Foundation

/// Represents a remote file or directory in SFTP
public struct SFTPItem: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: UInt64
    public var permissions: UInt32
    public var modificationDate: Date
    
    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: UInt64 = 0,
        permissions: UInt32 = 0o644,
        modificationDate: Date = Date()
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
    
    public var formattedSize: String {
        if isDirectory { return "--" }
        let b = Double(size)
        if b < 1024 { return "\(size) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024.0) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024.0 * 1024.0)) }
        return String(format: "%.2f GB", b / (1024.0 * 1024.0 * 1024.0))
    }
    
    public var permissionString: String {
        let typeChar = isDirectory ? "d" : (isSymlink ? "l" : "-")
        func rwx(_ octal: UInt32, special: Bool, sticky: Bool = false) -> String {
            let r = (octal & 4) != 0 ? "r" : "-"
            let w = (octal & 2) != 0 ? "w" : "-"
            let executable = (octal & 1) != 0
            let x = special ? (sticky ? (executable ? "t" : "T") : (executable ? "s" : "S")) : (executable ? "x" : "-")
            return "\(r)\(w)\(x)"
        }
        let user = rwx((permissions >> 6) & 7, special: permissions & 0o4000 != 0)
        let group = rwx((permissions >> 3) & 7, special: permissions & 0o2000 != 0)
        let others = rwx(permissions & 7, special: permissions & 0o1000 != 0, sticky: true)
        return "\(typeChar)\(user)\(group)\(others)"
    }

    /// Standard 4-digit octal permission representation (e.g. `"0755"`, `"0644"`, `"1777"`).
    public var octalPermissionString: String {
        String(format: "%04o", permissions & 0o7777)
    }

    /// True when this item represents the virtual `".."` parent directory navigation row.
    public var isParentNavigationEntry: Bool {
        name == ".."
    }

    /// True when this item can be safely downloaded, renamed, chmodded, or deleted.
    /// Excludes the virtual `".."` entry and the filesystem root `"/"`.
    public var isModifiableRemoteItem: Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isParentNavigationEntry && !trimmedPath.isEmpty && trimmedPath != "/"
    }

    /// Filters a selection of SFTP items to only those safe for batch download or deletion.
    public static func modifiableSelection(from items: [SFTPItem], selectedPaths: Set<String>) -> [SFTPItem] {
        items.filter { selectedPaths.contains($0.path) && $0.isModifiableRemoteItem }
    }
}

/// Supported cryptographic hash algorithms for remote SFTP file verification
public enum SFTPChecksumAlgorithm: String, CaseIterable, Sendable, Identifiable {
    case sha256 = "SHA-256"
    case md5 = "MD5"

    public var id: String { rawValue }

    public var expectedHexLength: Int {
        switch self {
        case .sha256: return 64
        case .md5: return 32
        }
    }
}

/// Utilities for remote file checksum calculation, hash verification, symbolic link creation, and server-side cloning.
public enum SFTPInspectorHelper: Sendable {

    /// Builds a multi-OS shell command to compute the SHA-256 or MD5 digest of `remotePath`.
    public static func buildChecksumCommand(remotePath: String, algorithm: SFTPChecksumAlgorithm) -> String {
        let quoted = SessionStartupHelper.shellQuotedWorkingDirectory(remotePath)
        switch algorithm {
        case .sha256:
            return "if command -v sha256sum >/dev/null 2>&1; then sha256sum \(quoted); elif command -v shasum >/dev/null 2>&1; then shasum -a 256 \(quoted); else openssl dgst -sha256 \(quoted); fi 2>/dev/null"
        case .md5:
            return "if command -v md5sum >/dev/null 2>&1; then md5sum \(quoted); elif command -v md5 >/dev/null 2>&1; then md5 -q \(quoted); else openssl dgst -md5 \(quoted); fi 2>/dev/null"
        }
    }

    /// Extracts and validates the lowercase hex digest from `sha256sum`, `shasum`, `md5sum`, `md5 -q`, or `openssl dgst` output.
    public static func parseChecksumOutput(_ raw: String, algorithm: SFTPChecksumAlgorithm) -> String? {
        let expectedLen = algorithm.expectedHexLength
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 1. OpenSSL format: `SHA2-256(/path)= <hex>` or `MD5(/path)= <hex>`
            if let eqIdx = trimmed.lastIndex(of: "=") {
                let candidate = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidHexDigest(candidate, length: expectedLen) {
                    return candidate.lowercased()
                }
            }

            // 2. GNU / BSD format: `<hex>  /path` or `<hex> */path` or raw `<hex>`
            if let firstToken = trimmed.components(separatedBy: .whitespaces).first,
               isValidHexDigest(firstToken, length: expectedLen) {
                return firstToken.lowercased()
            }
        }
        return nil
    }

    /// Compares a computed hex digest against user-pasted input (supports either raw hex or a full `SHA256SUMS.txt` line).
    /// Returns `nil` when `expectedInput` is empty/whitespace.
    public static func verifyChecksum(computed: String, expectedInput: String) -> Bool? {
        let trimmedInput = expectedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        let normalizedComputed = computed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedComputed.isEmpty else { return false }

        let candidateToken = trimmedInput.components(separatedBy: .whitespaces).first ?? trimmedInput
        return candidateToken.lowercased() == normalizedComputed
    }

    /// Builds a shell command to create a symbolic link (`ln -s targetPath linkPath`).
    public static func buildSymlinkCommand(targetPath: String, linkPath: String) -> String {
        let quotedTarget = SessionStartupHelper.shellQuotedWorkingDirectory(targetPath)
        let quotedLink = SessionStartupHelper.shellQuotedWorkingDirectory(linkPath)
        return "ln -s \(quotedTarget) \(quotedLink)"
    }

    /// Builds a shell command to duplicate a file or directory directly on the remote server (`cp -p` / `cp -pR`).
    public static func buildServerSideDuplicateCommand(sourcePath: String, destinationPath: String, isDirectory: Bool) -> String {
        let quotedSource = SessionStartupHelper.shellQuotedWorkingDirectory(sourcePath)
        let quotedDest = SessionStartupHelper.shellQuotedWorkingDirectory(destinationPath)
        let flags = isDirectory ? "-pR" : "-p"
        return "cp \(flags) \(quotedSource) \(quotedDest)"
    }

    /// Generates a collision-free duplicate name in the same directory (e.g. `config copy.yaml`, `bundle copy.tar.gz`).
    public static func defaultDuplicateName(
        for originalName: String,
        isDirectory: Bool,
        existingNames: Set<String>
    ) -> String {
        let (stem, ext) = splitStemAndExtension(originalName, isDirectory: isDirectory)
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let candidate = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            if !existingNames.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private static func splitStemAndExtension(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory, !name.hasPrefix(".") else {
            return (name, "")
        }
        let compoundSuffixes = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]
        let lower = name.lowercased()
        for compound in compoundSuffixes {
            if lower.hasSuffix("." + compound), name.count > compound.count + 1 {
                let cutIndex = name.index(name.endIndex, offsetBy: -(compound.count + 1))
                return (String(name[..<cutIndex]), compound)
            }
        }
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            let stem = String(name[..<dot])
            let ext = String(name[name.index(after: dot)...])
            return (stem, ext)
        }
        return (name, "")
    }

    private static func isValidHexDigest(_ text: String, length: Int) -> Bool {
        guard text.count == length else { return false }
        return text.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F")
        }
    }
}
