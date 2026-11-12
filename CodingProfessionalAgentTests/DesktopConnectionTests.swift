import XCTest
@testable import CodingProfessionalAgent

final class DesktopConnectionTests: XCTestCase {
    func testLegacyDirectJSONDecodesAsDirectMode() throws {
        let legacyJSON = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "name": "",
            "host": "192.168.1.10",
            "port": 18080,
            "icon": "laptop",
            "isEnabled": true
        }
        """
        let decoded = try JSONDecoder().decode(DesktopConnection.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.mode, .direct)
        XCTAssertEqual(decoded.displayName, "192.168.1.10")
        XCTAssertEqual(decoded.httpBaseURL?.absoluteString, "http://192.168.1.10:18080")
        XCTAssertEqual(decoded.webSocketURL?.absoluteString, "ws://192.168.1.10:18080/api/ws")
    }

    func testTunnelConnectionRoundTripAndEndpointComparison() throws {
        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "https://proxy.example.com",
            serverUUID: "srv-uuid-01",
            serverName: "Mac-Studio",
            icon: .display
        )
        let data = try JSONEncoder().encode(conn)
        let decoded = try JSONDecoder().decode(DesktopConnection.self, from: data)
        XCTAssertEqual(decoded.mode, .tunnel)
        XCTAssertEqual(decoded.displayName, "Mac-Studio")
        XCTAssertNil(decoded.httpBaseURL)
        XCTAssertNil(decoded.webSocketURL)

        var renamed = decoded
        renamed.name = "Work Mac"
        XCTAssertEqual(renamed.displayName, "Work Mac")
        XCTAssertTrue(decoded.hasSameEndpoint(as: renamed))

        var variantURL = decoded
        variantURL.tunnelBaseURL = "HTTPS://proxy.example.com/v1/"
        XCTAssertTrue(decoded.hasSameEndpoint(as: variantURL))

        var otherServer = decoded
        otherServer.tunnelServerUUID = "srv-uuid-02"
        XCTAssertFalse(decoded.hasSameEndpoint(as: otherServer))
    }

    func testKeychainSeparatesPasswordAndTunnelAPIKey() {
        let id = UUID()
        defer {
            KeychainStore.deletePassword(for: id)
            KeychainStore.deleteTunnelAPIKey(for: id)
        }
        KeychainStore.setPassword("web-pass-1", for: id)
        KeychainStore.setTunnelAPIKey("sk-tunnel-key-1", for: id)

        XCTAssertEqual(KeychainStore.password(for: id), "web-pass-1")
        XCTAssertEqual(KeychainStore.tunnelAPIKey(for: id), "sk-tunnel-key-1")

        KeychainStore.deletePassword(for: id)
        XCTAssertNil(KeychainStore.password(for: id))
        XCTAssertEqual(KeychainStore.tunnelAPIKey(for: id), "sk-tunnel-key-1")
    }
}
