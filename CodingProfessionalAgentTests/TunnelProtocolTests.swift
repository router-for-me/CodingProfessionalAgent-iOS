import XCTest
@testable import CodingProfessionalAgent

final class TunnelProtocolTests: XCTestCase {
    func testEndpointNormalizationUnifiesVariantsAndRejectsMissingScheme() throws {
        let a = try TunnelProtocol.parseEndpoint("HTTPS://Proxy.Example.COM/v1/").get()
        let b = try TunnelProtocol.parseEndpoint("https://proxy.example.com/v1/tunnel").get()
        let c = try TunnelProtocol.parseEndpoint("wss://proxy.example.com/").get()

        XCTAssertEqual(a.normalizedBaseURL, "https://proxy.example.com")
        XCTAssertEqual(a.webSocketBaseURL, "wss://proxy.example.com/v1/tunnel")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)

        let subpath = try TunnelProtocol.parseEndpoint("http://192.168.1.5:8317/gateway/v1").get()
        XCTAssertEqual(subpath.normalizedBaseURL, "http://192.168.1.5:8317/gateway")
        XCTAssertEqual(subpath.webSocketBaseURL, "ws://192.168.1.5:8317/gateway/v1/tunnel")

        let ipv6 = try TunnelProtocol.parseEndpoint("http://[::1]:8317").get()
        XCTAssertEqual(ipv6.webSocketBaseURL, "ws://[::1]:8317/v1/tunnel")

        let handshake = try a.handshakeURL(clientUUID: "client-01", clientName: "Luis iPhone")
        let comps = try XCTUnwrap(URLComponents(url: handshake, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["role"], "client")
        XCTAssertEqual(items["uuid"], "client-01")
        XCTAssertEqual(items["name"], "Luis iPhone")

        for invalid in [
            "",
            "proxy.example.com:8317",
            "ftp://proxy.example.com",
            "https://user:pass@proxy.example.com",
            "https://proxy.example.com?key=abc",
            "https://proxy.example.com#section",
            "https://proxy.example.com:0",
            "https://proxy.example.com:70000",
            "https://proxy.example.com:999999999999999999999999999",
            "https://proxy.example.com:/v1",
            "http://[::1]:999999999999999999999",
        ] {
            if case .success(let parsed) = TunnelProtocol.parseEndpoint(invalid) {
                XCTFail("Expected failure for \(invalid), got \(parsed)")
            }
        }
    }

    func testClientNameSanitizationTruncatesCleanlyAtUTF8Boundary() {
        XCTAssertEqual(TunnelProtocol.sanitizeClientName("  \n\t\u{7f}  "), "CPA-iOS")
        XCTAssertEqual(TunnelProtocol.sanitizeClientName("Luis\nMac\tiPhone"), "LuisMaciPhone")

        // Each "📱" is 4 UTF-8 bytes and each "测" is 3 UTF-8 bytes.
        let longName = "Luis的iPhone-" + String(repeating: "测📱", count: 50)
        let sanitized = TunnelProtocol.sanitizeClientName(longName)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 256)
        XCTAssertGreaterThan(sanitized.utf8.count, 249)
        XCTAssertEqual(String(decoding: Data(sanitized.utf8), as: UTF8.self), sanitized)
    }

    func testOuterTunnelFrameEncodeDecodeAndBounds() throws {
        let body = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let encoded = try TunnelProtocol.encodeTunnelFrame(
            payloadType: TunnelProtocol.muxPayloadType,
            srcUUID: "client-uuid-123",
            dstUUID: "server-uuid-456",
            payload: body
        )
        let decoded = try TunnelProtocol.decodeTunnelFrame(encoded)
        XCTAssertEqual(decoded.version, TunnelProtocol.protocolVersion)
        XCTAssertEqual(decoded.payloadType, TunnelProtocol.muxPayloadType)
        XCTAssertEqual(decoded.srcUUID, "client-uuid-123")
        XCTAssertEqual(decoded.dstUUID, "server-uuid-456")
        XCTAssertEqual(decoded.payload, body)

        XCTAssertThrowsError(try TunnelProtocol.decodeTunnelFrame(Data([0x01, 0x02, 0x01])))
        XCTAssertThrowsError(try TunnelProtocol.decodeTunnelFrame(Data([0x02, 0x02, 0x01, 0x01, 0x61, 0x62])))
        XCTAssertThrowsError(try TunnelProtocol.encodeTunnelFrame(
            payloadType: 0x02,
            srcUUID: "bad uuid",
            dstUUID: "server-1",
            payload: Data()
        ))
    }

    func testInnerMuxFrameAndArraySetCookieHeaderExtraction() throws {
        let headers: [String: JSONValue] = [
            "set-cookie": .array([.string("cpa_sid=abc123; Path=/; HttpOnly"), .string("other=1")]),
            "content-type": .string("application/json"),
        ]
        let responseBody = Data("{\"ok\":true}".utf8)
        let encoded = try TunnelProtocol.encodeMuxFrame(
            meta: .httpResponse(id: "req-1", status: 200, headers: headers),
            body: responseBody
        )
        let decoded = try TunnelProtocol.decodeMuxFrame(encoded)
        guard case .httpResponse(let id, let status, let decodedHeaders) = decoded.meta else {
            return XCTFail("Expected httpResponse meta")
        }
        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(decoded.body, responseBody)
        XCTAssertEqual(
            TunnelProtocol.headerValue(for: "Set-Cookie", in: decodedHeaders),
            "cpa_sid=abc123; Path=/; HttpOnly"
        )
        XCTAssertEqual(
            TunnelProtocol.headerValue(for: "CONTENT-TYPE", in: decodedHeaders),
            "application/json"
        )

        let wsOpenFrame = try TunnelProtocol.encodeMuxFrame(
            meta: .wsOpen(connId: "ws-1", path: "/api/ws", headers: ["Cookie": .string("cpa_sid=abc123")])
        )
        let wsOpenDecoded = try TunnelProtocol.decodeMuxFrame(wsOpenFrame)
        XCTAssertEqual(
            wsOpenDecoded.meta,
            .wsOpen(connId: "ws-1", path: "/api/ws", headers: ["Cookie": .string("cpa_sid=abc123")])
        )
    }

    func testControlFramesAndSecretRedaction() throws {
        let listJSON = """
        {"type":"server_list","request_id":"sync-1","servers":[{"uuid":"srv-1","name":"MacBook-Pro","type":"CodingProfessionalAgent"}]}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(listJSON.utf8)),
            .serverList(requestId: "sync-1", servers: [DiscoveredTunnelServer(uuid: "srv-1", name: "MacBook-Pro", type: "CodingProfessionalAgent")])
        )

        let onlineJSON = """
        {"type":"server_online","server":{"uuid":"srv-2","name":"Linux-Dev","type":"CodingProfessionalAgent"}}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(onlineJSON.utf8)),
            .serverOnline(DiscoveredTunnelServer(uuid: "srv-2", name: "Linux-Dev", type: "CodingProfessionalAgent"))
        )

        let offlineJSON = """
        {"type":"server_offline","server":{"uuid":"srv-2","name":"Linux-Dev","type":"CodingProfessionalAgent"}}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(offlineJSON.utf8)),
            .serverOffline(DiscoveredTunnelServer(uuid: "srv-2", name: "Linux-Dev", type: "CodingProfessionalAgent"))
        )

        let errJSON = """
        {"type":"error","code":"target_not_found","target_uuid":"srv-9","message":"offline"}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(errJSON.utf8)),
            .error(code: "target_not_found", targetUUID: "srv-9", message: "offline")
        )

        let queryText = try TunnelProtocol.encodeListServersFrame(requestId: "req-42")
        XCTAssertLessThanOrEqual(queryText.utf8.count, TunnelProtocol.maxControlFrameBytes)

        XCTAssertNoThrow(try TunnelProtocol.validateAPIKey("  sk-test+key/1  ").get())
        if case .success = TunnelProtocol.validateAPIKey("sk-bad\r\nheader") {
            XCTFail("Expected CRLF API key to be rejected")
        }

        let secret = "sk-test+key/1"
        let leaked = "Failed with key=sk-test+key/1 and encoded=sk-test%2Bkey%2F1"
        let redacted = TunnelProtocol.redactSecret(leaked, secret: secret)
        XCTAssertFalse(redacted.contains("sk-test"))
        XCTAssertEqual(redacted, "Failed with key=[REDACTED] and encoded=[REDACTED]")
    }

    func testLargeServerListControlFrameOver4KiBIsAccepted() {
        let items = (0..<120).map { index in
            #"{"uuid":"server-uuid-\#(String(format: "%04d", index))","name":"Remote-Build-Machine-\#(index)","type":"CodingProfessionalAgent"}"#
        }.joined(separator: ",")
        let largeJSON = #"{"type":"server_list","servers":[\#(items)]}"#
        let data = Data(largeJSON.utf8)
        XCTAssertGreaterThan(data.count, 4096)

        guard case .serverList(_, let servers) = TunnelProtocol.decodeControlFrame(data) else {
            return XCTFail("Expected server_list over 4 KiB to decode")
        }
        XCTAssertEqual(servers.count, 120)
    }

    func testNonCPAServersAreFilteredOutOfDiscovery() {
        // Mixed list: only type == CodingProfessionalAgent survives; other and missing types are dropped.
        let mixedListJSON = """
        {"type":"server_list","servers":[\
        {"uuid":"srv-cpa","name":"Studio-Mac","type":"CodingProfessionalAgent"},\
        {"uuid":"srv-build","name":"Build-Node","type":"build-agent"},\
        {"uuid":"srv-legacy","name":"Legacy-Node"}]}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(mixedListJSON.utf8)),
            .serverList(requestId: nil, servers: [
                DiscoveredTunnelServer(uuid: "srv-cpa", name: "Studio-Mac", type: "CodingProfessionalAgent"),
            ])
        )

        // server_online for a non-CPA server is ignored entirely.
        let foreignOnlineJSON = """
        {"type":"server_online","server":{"uuid":"srv-build","name":"Build-Node","type":"build-agent"}}
        """
        XCTAssertNil(TunnelProtocol.decodeControlFrame(Data(foreignOnlineJSON.utf8)))

        let missingTypeOnlineJSON = """
        {"type":"server_online","server":{"uuid":"srv-legacy","name":"Legacy-Node"}}
        """
        XCTAssertNil(TunnelProtocol.decodeControlFrame(Data(missingTypeOnlineJSON.utf8)))

        // server_offline is keyed by uuid and still decoded without a type field.
        let offlineWithoutTypeJSON = """
        {"type":"server_offline","server":{"uuid":"srv-cpa","name":"Studio-Mac"}}
        """
        XCTAssertEqual(
            TunnelProtocol.decodeControlFrame(Data(offlineWithoutTypeJSON.utf8)),
            .serverOffline(DiscoveredTunnelServer(uuid: "srv-cpa", name: "Studio-Mac", type: ""))
        )
    }

    func testOutOfRangeOrFractionalStatusAndCloseCodeAreRejectedWithoutCrashing() throws {
        func rawMuxFrame(_ metaText: String) -> Data {
            let metaBytes = Data(metaText.utf8)
            var out = Data()
            var lenBE = UInt32(metaBytes.count).bigEndian
            withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
            out.append(metaBytes)
            return out
        }

        for malformed in [
            #"{"type":"http_response","id":"r1","status":1e100}"#,
            #"{"type":"http_response","id":"r1","status":200.5}"#,
            #"{"type":"http_response","id":"r1","status":-1}"#,
            #"{"type":"ws_open_result","connId":"c1","ok":false,"status":9e99}"#,
            #"{"type":"ws_close","connId":"c1","code":1e100}"#,
            #"{"type":"ws_close","connId":"c1","code":70000}"#,
        ] {
            XCTAssertThrowsError(try TunnelProtocol.decodeMuxFrame(rawMuxFrame(malformed)))
        }
    }

    func testParseEndpointIsStrictlyIdempotentAcrossNestedV1Paths() throws {
        let inputs = [
            "https://proxy.example.com",
            "https://proxy.example.com/v1/",
            "https://proxy.example.com/gateway/v1",
            "https://proxy.example.com/gateway/v1/v1/tunnel",
            "https://proxy.example.com/a/v1/tunnel/v1/tunnel",
        ]
        for raw in inputs {
            let first = try TunnelProtocol.parseEndpoint(raw).get()
            let fromNormalized = try TunnelProtocol.parseEndpoint(first.normalizedBaseURL).get()
            let fromWS = try TunnelProtocol.parseEndpoint(first.webSocketBaseURL).get()
            XCTAssertEqual(fromNormalized, first, "Non-idempotent normalizedBaseURL for \(raw)")
            XCTAssertEqual(fromWS, first, "Non-idempotent webSocketBaseURL for \(raw)")
        }

        let nested = try TunnelProtocol.parseEndpoint("https://proxy.example.com/gateway/v1/v1/tunnel").get()
        XCTAssertEqual(nested.webSocketBaseURL, "wss://proxy.example.com/gateway/v1/v1/tunnel")
    }
}
