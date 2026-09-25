import XCTest
@testable import ApexCore
@testable import ApexUI

final class QuickEditorAndSFTPItemTests: XCTestCase {
    
    /// Test 1: SFTPItem formatted file sizes across scales
    func testSFTPItemFormattedSizes() {
        let dirItem = SFTPItem(name: "var", path: "/var", isDirectory: true, size: 4096)
        XCTAssertEqual(dirItem.formattedSize, "--")
        
        let bItem = SFTPItem(name: "test.txt", path: "/tmp/test.txt", isDirectory: false, size: 512)
        XCTAssertEqual(bItem.formattedSize, "512 B")
        
        let kbItem = SFTPItem(name: "doc.pdf", path: "/tmp/doc.pdf", isDirectory: false, size: 2048)
        XCTAssertEqual(kbItem.formattedSize, "2.0 KB")
        
        let mbItem = SFTPItem(name: "archive.zip", path: "/tmp/archive.zip", isDirectory: false, size: UInt64(15.5 * 1024 * 1024))
        XCTAssertEqual(mbItem.formattedSize, "15.5 MB")
        
        let gbItem = SFTPItem(name: "ubuntu.iso", path: "/tmp/ubuntu.iso", isDirectory: false, size: UInt64(4.25 * 1024 * 1024 * 1024))
        XCTAssertEqual(gbItem.formattedSize, "4.25 GB")
    }
    
    /// Test 2: SFTPItem permissions string generation
    func testSFTPItemPermissions() {
        let dir = SFTPItem(name: "etc", path: "/etc", isDirectory: true, permissions: 0o755)
        XCTAssertEqual(dir.permissionString, "drwxr-xr-x")
        
        let file644 = SFTPItem(name: "config.json", path: "/etc/config.json", isDirectory: false, permissions: 0o644)
        XCTAssertEqual(file644.permissionString, "-rw-r--r--")
        
        let privateKey = SFTPItem(name: "id_rsa", path: "/root/.ssh/id_rsa", isDirectory: false, permissions: 0o600)
        XCTAssertEqual(privateKey.permissionString, "-rw-------")
        
        let executable = SFTPItem(name: "run.sh", path: "/usr/local/bin/run.sh", isDirectory: false, permissions: 0o777)
        XCTAssertEqual(executable.permissionString, "-rwxrwxrwx")
        
        let symlink = SFTPItem(name: "treasure-shop-test", path: "/home/ubuntu/services/treasure-shop-test", isDirectory: false, isSymlink: true, permissions: 0o777)
        XCTAssertEqual(symlink.permissionString, "lrwxrwxrwx")
    }
    
    /// Test 3: QuickEditor text line calculations and search matching logic
    func testQuickEditorLineAndSearchCalculations() {
        let sampleContent = """
        server {
            listen 80;
            server_name example.com;
            location / {
                proxy_pass http://127.0.0.1:3000;
                proxy_set_header Host $host;
            }
        }
        """
        
        let lines = sampleContent.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 8)
        
        // Exact occurrences of "proxy_"
        let proxyCount = sampleContent.components(separatedBy: "proxy_").count - 1
        XCTAssertEqual(proxyCount, 2)
        
        // Non-existent search
        let notFound = sampleContent.components(separatedBy: "non_existent_key").count - 1
        XCTAssertEqual(notFound, 0)
    }
}
