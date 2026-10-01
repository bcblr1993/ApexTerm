import XCTest
@testable import ApexSSH

final class SFTPListingRegressionTests: XCTestCase {
    func testGNUAndBSDTimestampAndFilenameWhitespace() throws {
        for permission in ["-rw-r--r--", "-rw-r--r--@"] {
            let listing = "\(permission) 1 qa staff 42 946684800 中文  two spaces.txt\n"
            let entry = try XCTUnwrap(NativeSSHSession.parseDirectoryListing(listing, path: "/tmp").first)
            XCTAssertEqual(entry.name, "中文  two spaces.txt")
            XCTAssertEqual(entry.path, "/tmp/中文  two spaces.txt")
            XCTAssertEqual(entry.modificationDate.timeIntervalSince1970, 946684800)
            XCTAssertEqual(entry.size, 42)
            XCTAssertEqual(entry.permissions, 0o644)
        }
    }
}
