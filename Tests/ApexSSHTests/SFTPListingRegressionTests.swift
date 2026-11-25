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

    func testCRLFISODatesSmallEpochsAndSymlinksWithSpaces() throws {
        let listing = [
            "-rw-r--r-- 1 qa staff 12 0 epoch_zero.txt\r",
            "drwxr-xr-x 2 qa staff 4096 2026-11-25 14:30 my folder 中文\r",
            "lrwxrwxrwx 1 qa staff 15 1700000000 link name -> /target/path -> v2\r"
        ].joined(separator: "\n")

        let items = NativeSSHSession.parseDirectoryListing(listing, path: "/srv")
        XCTAssertEqual(items.count, 3)

        XCTAssertEqual(items[0].name, "epoch_zero.txt")
        XCTAssertEqual(items[0].modificationDate.timeIntervalSince1970, 0)

        XCTAssertEqual(items[1].name, "my folder 中文")
        XCTAssertTrue(items[1].isDirectory)
        XCTAssertEqual(items[1].path, "/srv/my folder 中文")

        XCTAssertEqual(items[2].name, "link name")
        XCTAssertTrue(items[2].isSymlink)
        XCTAssertEqual(items[2].path, "/srv/link name")
    }
}
