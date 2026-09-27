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
}
