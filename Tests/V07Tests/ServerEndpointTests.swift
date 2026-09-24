import Foundation
import XCTest
@testable import V07

final class ServerEndpointTests: XCTestCase {
    func testHTTPAllowsOnlyLoopbackAndLiteralTailscaleAddresses() throws {
        let hosts = ["localhost", "LOCALHOST", "127.0.0.1", "127.0.0.2", "[::1]",
                     "100.64.0.0", "100.127.255.255", "[fd7a:115c:a1e0::1]",
                     "[FD7A:115C:A1E0:ffff:ffff:ffff:ffff:ffff]"]
        for host in hosts {
            let address = "http://\(host):8391"
            XCTAssertEqual(try ServerEndpoint(address).address, address)
            XCTAssertNoThrow(try ServerClient(endpoint: address, token: "secret"))
        }
    }

    func testHTTPRejectsPublicLANAndUnverifiedNamesBeforeMakingRequests() {
        let hosts = ["example.com", "198.51.100.23", "192.168.1.1", "10.0.0.1", "172.16.0.1",
                     "100.63.255.255", "100.128.0.0", "[fd7a:115c:a1e1::1]", "[2001:db8::1]",
                     "my-mac", "my-mac.local", "my-mac.tail123.ts.net", "localhost.example.com",
                     "127.0.0.1.example.com", "127.1", "2130706433", "127.0.0.1%00.example.com"]
        for host in hosts {
            XCTAssertThrowsError(try ServerEndpoint("http://\(host):8391"), host)
            XCTAssertThrowsError(try ServerClient(endpoint: "http://\(host):8391", token: "secret"), host)
        }
    }

    func testHTTPSAcceptsProviderEndpointsAndRetainsBasePaths() throws {
        let client = try ServerClient(endpoint: " \nhttps://example.com/v07///\n", token: "secret")
        XCTAssertEqual(try client.request(path: "v1/health").url?.absoluteString,
                       "https://example.com/v07/v1/health")
    }

    func testRejectsCredentialsQueriesFragmentsAndInvalidPorts() {
        for address in ["https://user:secret@example.com", "https://example.com?key=secret",
                        "https://example.com#fragment", "https://example.com:0", "https://example.com:65536",
                        "file:///tmp/v07", "https://"] {
            XCTAssertThrowsError(try ServerEndpoint(address), address)
        }
    }

    @MainActor
    func testEnvironmentOverrideNormalizesBeforeCredentialLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var accounts = [String]()
        let store = ClientPreferencesStore(root: root, environment: ["V07_SERVER_URL": " \nhttps://EXAMPLE.com:443/v07/// \n"],
                                          readCredential: { accounts.append($0); return "saved-key" })
        XCTAssertEqual(store.endpoint, "https://EXAMPLE.com:443/v07")
        XCTAssertEqual(accounts, [root.standardizedFileURL.path + "|https://EXAMPLE.com:443/v07"])
        XCTAssertEqual(store.token, "saved-key")
        XCTAssertNil(store.errorMessage)
        let restored = ClientPreferencesStore(root: root, environment: [:], readCredential: { accounts.append($0); return "saved-key" })
        XCTAssertEqual(restored.endpoint, store.endpoint)
        XCTAssertEqual(accounts.first, accounts.last)
    }

    @MainActor
    func testInvalidOverrideNeverLoadsCredentialsAndSaveUsesTheSamePolicy() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let store = ClientPreferencesStore(root: root, environment: ["V07_SERVER_URL": "http://example.com"],
                                          readCredential: { _ in reads += 1; return "must-not-load" })
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(store.token, "")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.save(endpoint: "http://example.com", token: "must-not-save", deviceName: "Mac"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("client.json").path))
    }
}
