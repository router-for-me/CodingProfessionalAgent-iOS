import CryptoKit
import Foundation
import Network
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class TunnelClientIntegrationTests: XCTestCase {
    func testSharedSessionMultiplexesDiscoveryAndMultipleDesktopClientsWithoutConflict() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "secret-pw")
        server.setDesktopServer(uuid: "srv-2", name: "Mini-Server", password: "")

        let suiteName = "TunnelTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )

        let conn1 = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        let conn2 = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-2",
            serverName: "Mini-Server",
            icon: .laptop
        )
        defer {
            KeychainStore.deletePassword(for: conn1.id)
            KeychainStore.deleteTunnelAPIKey(for: conn1.id)
            KeychainStore.deletePassword(for: conn2.id)
            KeychainStore.deleteTunnelAPIKey(for: conn2.id)
        }
        KeychainStore.setPassword("secret-pw", for: conn1.id)
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn1.id)
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn2.id)

        let client1 = DesktopClient(connection: conn1, tunnelManager: manager)
        let client2 = DesktopClient(connection: conn2, tunnelManager: manager)
        defer {
            client1.stop()
            client2.stop()
        }

        client1.start()
        try await waitUntil("client1 connected and synced") {
            client1.state == .connected && client1.hasSynced
        }
        XCTAssertEqual(client1.projects.map(\.name), ["Alpha"])
        XCTAssertEqual(client1.sessions.map(\.title), ["Hello Tunnel"])

        // Acquire discovery session with a path variant (/v1/) while client1 is already online.
        let (session, searchLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)/v1/",
            apiKey: "sk-live-key"
        )
        XCTAssertEqual(session.phase, .connected)
        XCTAssertEqual(server.upgradeCount, 1)
        XCTAssertEqual(server.lastAuthHeader, "Bearer sk-live-key")
        XCTAssertEqual(server.lastQuery["role"], "client")
        XCTAssertFalse((server.lastQuery["uuid"] ?? "").isEmpty)
        XCTAssertFalse((server.lastQuery["name"] ?? "").isEmpty)
        XCTAssertEqual(Set(session.servers.map(\.uuid)), ["srv-1", "srv-2"])

        // Start second DesktopClient on the same gateway + API key.
        client2.start()
        try await waitUntil("client2 connected and synced") {
            client2.state == .connected && client2.hasSynced
        }
        XCTAssertEqual(server.upgradeCount, 1)

        // Verify live server_online, manual list_servers refresh, and server_offline.
        server.broadcastText(#"{"type":"server_online","server":{"uuid":"srv-3","name":"Linux-Box","type":"CodingProfessionalAgent"}}"#)
        try await waitUntil("srv-3 online") {
            session.servers.contains(where: { $0.uuid == "srv-3" })
        }

        let previousListQueries = server.listServersCount
        session.refreshServers()
        try await waitUntil("list_servers received") {
            server.listServersCount > previousListQueries
        }

        server.broadcastText(#"{"type":"server_offline","server":{"uuid":"srv-3","name":"Linux-Box","type":"CodingProfessionalAgent"}}"#)
        try await waitUntil("srv-3 offline") {
            !session.servers.contains(where: { $0.uuid == "srv-3" })
        }

        // Releasing search lease must keep active DesktopClients connected.
        manager.releaseLease(searchLease)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(client1.state, .connected)
        XCTAssertEqual(client2.state, .connected)
        let rpcSessions = try await client1.call("session:listSessions")
        XCTAssertEqual(rpcSessions.arrayValue?.count, 1)
    }

    func testVirtualWebSocket4401ClearsCookieAndStopsOnWrongPassword() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "old-password")

        let suiteName = "TunnelTest-4401-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let (session, lease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        defer { manager.releaseLease(lease) }

        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setPassword("old-password", for: conn.id)
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()
        try await waitUntil("client connected") {
            client.state == .connected
        }

        // Rotate desktop Web password and kick active virtual WS stream with 4401.
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "new-password")
        server.closeAllVirtualWebSockets(serverUUID: "srv-1", code: 4401, reason: "password changed")

        try await waitUntil("client fails with wrong password") {
            client.state == .failed("密码错误")
        }
        XCTAssertEqual(session.phase, .connected)
    }

    func testOfflineDesktopAutoConnectsImmediatelyWhenServerOnlineBroadcastArrives() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"

        let suiteName = "TunnelTest-OfflineWake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 5.0,
            conflictBackoff: 5.0,
            maxBackoff: 20.0
        )

        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-late",
            serverName: "Late-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("client reports server offline") {
            client.state == .failed("远程桌面端不在线")
        }

        // Bring srv-late online; client must connect immediately without waiting for the 5s backoff.
        server.setDesktopServer(uuid: "srv-late", name: "Late-Mac", password: "")
        server.broadcastText(#"{"type":"server_online","server":{"uuid":"srv-late","name":"Late-Mac","type":"CodingProfessionalAgent"}}"#)

        try await waitUntil("client auto-connects on server_online", timeout: 1.5) {
            client.state == .connected && client.hasSynced
        }
    }

    func testImmediateStartThenStopDoesNotLeakTunnelLease() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "")

        let suiteName = "TunnelTest-StopRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        // Call start() and stop() synchronously in the same @MainActor turn.
        client.start()
        client.stop()

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(server.handshakeAttempts, 0)
        XCTAssertEqual(manager.activeSessionCount, 0)
    }

    func testWsOpenTimeoutAndLateOpenResultSendWsCloseToServer() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.delayWsOpenAckMilliseconds = 300
        server.setDesktopServer(uuid: "srv-slow", name: "Slow-Mac", password: "")

        let suiteName = "TunnelTest-WsTimeout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let (session, lease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        defer { manager.releaseLease(lease) }

        try await waitUntil("session connected") {
            session.phase == .connected
        }

        do {
            _ = try await session.openWebSocket(serverUUID: "srv-slow", path: "/api/ws", timeout: 0.08)
            XCTFail("Expected ws_open timeout")
        } catch {
            // Expected timeout
        }

        // Wait past the server's 300ms delayed ws_open_result and verify the server received ws_close
        // so zero virtual streams remain leaked on the server.
        try await waitUntil("server cleans up timed-out virtual stream") {
            server.receivedWsCloseCount >= 1 && server.openVirtualStreamCount == 0
        }
    }

    func testWsOpen401ClearsStaleCookieReauthenticatesAndConnects() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.fakeAuthenticatedStatusResponses = 1
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "valid-password")

        let suiteName = "TunnelTest-WsOpen401-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setPassword("valid-password", for: conn.id)
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("client recovers from ws_open 401 and connects") {
            client.state == .connected && client.hasSynced
        }
    }

    func testSavingFirstServerHandsOffSearchSessionWithoutSecondHandshake() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "")

        let suiteName = "TunnelTest-Handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )

        // Step 1: Discovery sheet opens the tunnel session.
        let (searchSession, searchLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        try await waitUntil("search session connected") {
            searchSession.phase == .connected
        }
        XCTAssertEqual(server.handshakeAttempts, 1)

        // Step 2: Save action starts DesktopClient and immediately releases searchLease in the same turn.
        let conn = DesktopConnection.tunnel(
            name: "Studio-Mac",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()
        manager.releaseLease(searchLease)

        try await waitUntil("client connected over handed-off session") {
            client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.handshakeAttempts, 1)
        XCTAssertEqual(server.upgradeCount, 1)
    }

    func testCrossServerBinaryFrameInjectionIsIgnored() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.injectSpoofedPeerBeforeAuthenticReply = true
        server.setDesktopServer(uuid: "srv-1", name: "Trusted-Mac", password: "")
        server.setDesktopServer(uuid: "srv-evil", name: "Untrusted-Peer", password: "")

        let suiteName = "TunnelTest-PeerIsolation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let (session, lease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        defer { manager.releaseLease(lease) }

        try await waitUntil("session connected") {
            session.phase == .connected
        }

        // Mock server sends a forged 418 response from "srv-evil" with the exact same reqId BEFORE
        // sending the real 200 response from "srv-1".
        let httpRes = try await session.performHTTP(
            serverUUID: "srv-1",
            method: "GET",
            path: "/api/auth/status",
            timeout: 2.0
        )
        XCTAssertEqual(httpRes.status, 200)

        // Open virtual WS to srv-1; mock server injects forged ws_close from "srv-evil" with same connId.
        let stream = try await session.openWebSocket(serverUUID: "srv-1", path: "/api/ws", timeout: 2.0)
        defer { stream.close() }
        let greeting = try await stream.receive()
        XCTAssertEqual(JSONValue.parse(greeting)?["type"]?.stringValue, "hello")

        server.sendSpoofedWsCloseForAllStreams(spoofedSrcUUID: "srv-evil")
        try await Task.sleep(for: .milliseconds(60))

        // Stream must still be alive and pass authentic RPC traffic on srv-1.
        try await stream.sendText(#"{"type":"rpc","id":"c1","method":"session:listSessions","args":[]}"#)
        let reply = try await stream.receive()
        XCTAssertEqual(JSONValue.parse(reply)?["id"]?.stringValue, "c1")
    }

    func testPerformHTTPSharesSingleTimeoutBudgetAcrossReadinessAndResponse() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.delayInitialServerListMilliseconds = 140
        server.delayHttpStatusMilliseconds = 150
        server.setDesktopServer(uuid: "srv-1", name: "Slow-Mac", password: "")

        let suiteName = "TunnelTest-Budget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let (session, lease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        defer { manager.releaseLease(lease) }

        // Readiness takes ~140ms and HTTP takes ~150ms (total ~290ms > 220ms budget).
        // With a shared timeout budget of 220ms, performHTTP must time out rather than waiting 220ms + 220ms.
        do {
            _ = try await session.performHTTP(
                serverUUID: "srv-1",
                method: "GET",
                path: "/api/auth/status",
                timeout: 0.22
            )
            XCTFail("Expected performHTTP to exceed shared 220ms timeout budget")
        } catch DesktopClientError.timeout {
            // Expected timeout within single shared budget
        }
    }

    func testRepeatedTargetBufferFullDoesNotLeakOrGrowRemoteVirtualStreams() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "")

        let suiteName = "TunnelTest-BufferFull-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let conn = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("client connected") {
            client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.openVirtualStreamCount, 1)

        // Drop the next 2 binary frames targeting srv-1 with target_buffer_full (dropping both the
        // in-flight RPC ws_data frame AND the immediate ws_close frame while congested).
        // The 10s RPC must fail immediately (< 1.5s) instead of waiting 10s, and upon reconnect the
        // deferred ws_close must clean up the old stream so openVirtualStreamCount returns to 1.
        server.dropNextBinaryFramesWithBufferFull = 2
        let startTime = Date()
        do {
            _ = try await client.call("slow:neverReplies", timeout: 10.0)
            XCTFail("Expected dropped RPC to fail immediately on target_buffer_full")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(startTime), 1.5)
        }

        try await waitUntil("client reconnects after target_buffer_full and cleans up old stream") {
            client.state == .connected && client.hasSynced && server.openVirtualStreamCount == 1
        }
        let sessions = try await client.call("session:listSessions")
        XCTAssertEqual(sessions.arrayValue?.count, 1)
    }

    func testUpdatingCredentialsAndStoppingSoleClientCleanUpRemoteVirtualStreams() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-key-1"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "pw-1")

        let suiteName = "TunnelTest-UpdateCleanup-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let conn = DesktopConnection.tunnel(
            name: "Studio-Mac",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setPassword("pw-1", for: conn.id)
        KeychainStore.setTunnelAPIKey("sk-key-1", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("initial connect") {
            client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.openVirtualStreamCount, 1)
        XCTAssertEqual(server.handshakeAttempts, 1)

        // Repeatedly rotate desktop Web password on the sole lease: outer tunnel must stay at 1 handshake
        // and remote virtual stream count must stay at 1 (no leaked streams).
        for round in 2...4 {
            let nextPw = "pw-\(round)"
            server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: nextPw)
            KeychainStore.setPassword(nextPw, for: conn.id)
            client.update(connection: conn, credentialsChanged: true)

            try await waitUntil("reconnected after password update \(round)") {
                client.state == .connected && client.hasSynced
            }
            XCTAssertEqual(server.handshakeAttempts, 1)
            XCTAssertEqual(server.openVirtualStreamCount, 1)
        }

        // Rotate tunnel API key as well: old session must flush ws_close before closing so remote count stays 1.
        server.expectedAPIKey = "sk-key-2"
        KeychainStore.setTunnelAPIKey("sk-key-2", for: conn.id)
        client.update(connection: conn, credentialsChanged: true)

        try await waitUntil("reconnected after API key rotation") {
            client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.openVirtualStreamCount, 1)

        // Stopping sole client must leave zero open virtual streams on remote desktop.
        client.stop()
        try await waitUntil("remote virtual stream closed on stop") {
            server.openVirtualStreamCount == 0
        }
    }

    func testAbruptTunnelReconnectsCleanUpPreviousRemoteVirtualStreams() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "")

        let suiteName = "TunnelTest-ReconnectCleanup-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.04,
            conflictBackoff: 0.04,
            maxBackoff: 0.15
        )
        let conn = DesktopConnection.tunnel(
            name: "Studio-Mac",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("initial connect") {
            client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.openVirtualStreamCount, 1)

        for cycle in 1...3 {
            let previousUpgrades = server.upgradeCount
            server.dropActiveConnectionAbruptly()
            try await waitUntil("reconnected cycle \(cycle)") {
                server.upgradeCount > previousUpgrades && client.state == .connected && client.hasSynced
            }
            XCTAssertEqual(server.openVirtualStreamCount, 1)
        }
    }

    func testSendWSDataFailureBeforeDisconnectRecordsStreamForCleanupOnReconnect() async throws {
        let server = try MockTunnelServer()
        defer { server.stop() }
        server.expectedAPIKey = "sk-live-key"
        server.setDesktopServer(uuid: "srv-1", name: "Studio-Mac", password: "")

        let suiteName = "TunnelTest-SendFailRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.04,
            conflictBackoff: 0.04,
            maxBackoff: 0.15
        )
        let (session, searchLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "sk-live-key"
        )
        defer { manager.releaseLease(searchLease) }

        let conn = DesktopConnection.tunnel(
            name: "Studio-Mac",
            tunnelBaseURL: "http://127.0.0.1:\(server.port)",
            serverUUID: "srv-1",
            serverName: "Studio-Mac",
            icon: .display
        )
        defer {
            KeychainStore.deletePassword(for: conn.id)
            KeychainStore.deleteTunnelAPIKey(for: conn.id)
        }
        KeychainStore.setTunnelAPIKey("sk-live-key", for: conn.id)

        let client = DesktopClient(connection: conn, tunnelManager: manager)
        defer { client.stop() }
        client.start()

        try await waitUntil("initial connect") {
            client.state == .connected && client.hasSynced
        }
        let firstConnId = try XCTUnwrap(server.activeVirtualStreamIDs.first)
        XCTAssertEqual(server.openVirtualStreamCount, 1)

        // Simulate socket.send error callback firing BEFORE receiveLoop observes the broken socket.
        let previousUpgrades = server.upgradeCount
        session.handleSendWSDataError(connId: firstConnId, error: URLError(.networkConnectionLost))
        server.dropActiveConnectionAbruptly()

        try await waitUntil("reconnected after send error + disconnect") {
            server.upgradeCount > previousUpgrades && client.state == .connected && client.hasSynced
        }
        XCTAssertEqual(server.openVirtualStreamCount, 1)
    }

    func testTerminalAuth401And1008RevokedStopReconnectingAnd409RotatesClientUUID() async throws {
        // 1. Handshake 401 stops reconnecting.
        let authServer = try MockTunnelServer()
        defer { authServer.stop() }
        authServer.expectedAPIKey = "sk-correct"

        let suiteName = "TunnelTest-Errors-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TunnelClientManager(
            userDefaults: defaults,
            initialBackoff: 0.05,
            conflictBackoff: 0.05,
            maxBackoff: 0.2
        )
        let (badSession, badLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(authServer.port)",
            apiKey: "sk-wrong"
        )
        try await waitUntil("401 session fails") {
            if case .failed = badSession.phase { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(authServer.handshakeAttempts, 1)
        manager.releaseLease(badLease)

        // 2. WebSocket Close 1008 ("api key revoked") stops reconnecting.
        let revokeServer = try MockTunnelServer()
        defer { revokeServer.stop() }
        revokeServer.expectedAPIKey = "sk-revocable"

        let (revSession, revLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(revokeServer.port)",
            apiKey: "sk-revocable"
        )
        try await waitUntil("revocable session connected") {
            revSession.phase == .connected
        }
        revokeServer.closeTunnelWebSocket(code: 1008, reason: "api key revoked")
        try await waitUntil("revoked session failed") {
            if case .failed(let msg) = revSession.phase {
                return msg.contains("吊销") || msg.contains("API Key")
            }
            return false
        }
        let attemptsAfterRevoke = revokeServer.handshakeAttempts
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(revokeServer.handshakeAttempts, attemptsAfterRevoke)
        manager.releaseLease(revLease)

        // 3. Three consecutive 409 Conflict responses rotate clientUUID and self-heal.
        let conflictServer = try MockTunnelServer()
        defer { conflictServer.stop() }
        conflictServer.expectedAPIKey = "sk-conflict"
        conflictServer.remaining409Responses = 3

        let initialUUID = defaults.string(forKey: PreferenceKey.tunnelClientUUID)
        let (conflictSession, conflictLease) = try manager.acquireSession(
            baseURL: "http://127.0.0.1:\(conflictServer.port)",
            apiKey: "sk-conflict"
        )
        defer { manager.releaseLease(conflictLease) }
        try await waitUntil("conflict session self-heals") {
            conflictSession.phase == .connected
        }
        XCTAssertGreaterThanOrEqual(conflictServer.handshakeAttempts, 4)
        XCTAssertNotEqual(conflictServer.lastQuery["uuid"], initialUUID)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for: \(description)")
    }
}

// MARK: - Local RFC 6455 Mock CLIProxyAPI Tunnel + CPA Desktop Server

private final class MockTunnelServer: @unchecked Sendable {
    private struct DesktopMock {
        var uuid: String
        var name: String
        var password: String
    }

    private let queue = DispatchQueue(label: "MockTunnelServer")
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    var expectedAPIKey = "sk-test"
    var remaining409Responses = 0
    var delayWsOpenAckMilliseconds = 0
    var delayInitialServerListMilliseconds = 0
    var delayHttpStatusMilliseconds = 0
    var fakeAuthenticatedStatusResponses = 0
    var injectSpoofedPeerBeforeAuthenticReply = false
    var dropNextBinaryFramesWithBufferFull = 0
    private(set) var handshakeAttempts = 0
    private(set) var upgradeCount = 0
    private(set) var listServersCount = 0
    private(set) var receivedWsCloseCount = 0

    var openVirtualStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openVirtualStreams.count
    }

    var activeVirtualStreamIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(openVirtualStreams.keys)
    }
    private(set) var lastAuthHeader = ""
    private(set) var lastQuery: [String: String] = [:]
    private var desktops: [String: DesktopMock] = [:]
    private var activeConn: NWConnection?
    private var activeClientUUID = ""
    private var openVirtualStreams: [String: String] = [:] // connId -> serverUUID

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let assigned = listener.port?.rawValue
        else {
            throw NSError(domain: "MockTunnelServer", code: 1)
        }
        port = assigned
    }

    func stop() {
        lock.lock()
        let conn = activeConn
        activeConn = nil
        lock.unlock()
        conn?.cancel()
        listener.cancel()
    }

    func setDesktopServer(uuid: String, name: String, password: String) {
        lock.lock()
        desktops[uuid] = DesktopMock(uuid: uuid, name: name, password: password)
        lock.unlock()
    }

    func broadcastText(_ json: String) {
        lock.lock()
        guard let conn = activeConn else {
            lock.unlock()
            return
        }
        lock.unlock()
        sendWSFrame(on: conn, opcode: 0x01, payload: Data(json.utf8))
    }

    func dropActiveConnectionAbruptly() {
        lock.lock()
        let conn = activeConn
        activeConn = nil
        lock.unlock()
        conn?.forceCancel()
    }

    func closeTunnelWebSocket(code: UInt16, reason: String) {
        lock.lock()
        guard let conn = activeConn else {
            lock.unlock()
            return
        }
        activeConn = nil
        lock.unlock()
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        payload.append(Data(reason.utf8))
        sendWSFrame(on: conn, opcode: 0x08, payload: payload) {
            conn.cancel()
        }
    }

    func sendSpoofedWsCloseForAllStreams(spoofedSrcUUID: String) {
        lock.lock()
        guard let conn = activeConn else {
            lock.unlock()
            return
        }
        let clientUUID = activeClientUUID
        let streamIDs = Array(openVirtualStreams.keys)
        lock.unlock()
        for connId in streamIDs {
            sendMux(
                on: conn,
                serverUUID: spoofedSrcUUID,
                clientUUID: clientUUID,
                meta: .wsClose(connId: connId, code: 4401, reason: "forged close")
            )
        }
    }

    func closeAllVirtualWebSockets(serverUUID: String, code: Int, reason: String) {
        lock.lock()
        guard let conn = activeConn else {
            lock.unlock()
            return
        }
        let clientUUID = activeClientUUID
        let matching = openVirtualStreams.filter { $0.value == serverUUID }.map(\.key)
        for id in matching {
            openVirtualStreams.removeValue(forKey: id)
        }
        lock.unlock()

        for connId in matching {
            sendMux(on: conn, serverUUID: serverUUID, clientUUID: clientUUID, meta: .wsClose(connId: connId, code: code, reason: reason))
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHTTPHeader(conn: conn, buffer: Data())
    }

    private func readHTTPHeader(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else {
                if isComplete || error != nil { conn.cancel() }
                return
            }
            let accumulated = buffer + data
            let separator = Data("\r\n\r\n".utf8)
            guard let range = accumulated.range(of: separator) else {
                self.readHTTPHeader(conn: conn, buffer: accumulated)
                return
            }
            let headerData = accumulated[..<range.lowerBound]
            let leftover = Data(accumulated[range.upperBound...])
            self.processHandshake(conn: conn, headerData: Data(headerData), leftover: leftover)
        }
    }

    private func processHandshake(conn: NWConnection, headerData: Data, leftover: Data) {
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        let comps = URLComponents(string: "http://localhost\(target)")
        let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let auth = headers["authorization"] ?? ""

        lock.lock()
        handshakeAttempts += 1
        lastAuthHeader = auth
        lastQuery = query
        let expectedAuth = "Bearer \(expectedAPIKey)"
        let should409: Bool
        if auth == expectedAuth, remaining409Responses > 0 {
            remaining409Responses -= 1
            should409 = true
        } else {
            should409 = false
        }
        lock.unlock()

        if auth != expectedAuth {
            sendHTTPRejection(conn: conn, status: "401 Unauthorized", body: #"{"error":"invalid or missing api key"}"#)
            return
        }
        if should409 {
            sendHTTPRejection(conn: conn, status: "409 Conflict", body: #"{"error":"device uuid already connected"}"#)
            return
        }
        guard let wsKey = headers["sec-websocket-key"], let clientUUID = query["uuid"], !clientUUID.isEmpty else {
            sendHTTPRejection(conn: conn, status: "400 Bad Request", body: #"{"error":"invalid parameters"}"#)
            return
        }

        let acceptInput = wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(acceptInput.utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"

        lock.lock()
        upgradeCount += 1
        activeConn = conn
        activeClientUUID = clientUUID
        let currentDesktops = desktops.values.sorted { $0.uuid < $1.uuid }
        lock.unlock()

        lock.lock()
        let listDelay = delayInitialServerListMilliseconds
        lock.unlock()

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let serverItems = currentDesktops.map { #"{"uuid":"\#($0.uuid)","name":"\#($0.name)","type":"CodingProfessionalAgent"}"# }.joined(separator: ",")
            let sendList: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.sendWSFrame(on: conn, opcode: 0x01, payload: Data(#"{"type":"server_list","servers":[\#(serverItems)]}"#.utf8))
            }
            if listDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(listDelay), execute: sendList)
            } else {
                sendList()
            }
            self.readWSFrames(conn: conn, clientUUID: clientUUID, buffer: leftover)
        })
    }

    private func sendHTTPRejection(conn: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func readWSFrames(conn: NWConnection, clientUUID: String, buffer: Data) {
        var buf = buffer
        while let parsed = parseOneClientFrame(&buf) {
            handleClientFrame(conn: conn, clientUUID: clientUUID, opcode: parsed.opcode, payload: parsed.payload)
        }
        let remaining = buf
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readWSFrames(conn: conn, clientUUID: clientUUID, buffer: remaining + data)
            } else if isComplete || error != nil {
                conn.cancel()
            }
        }
    }

    private func parseOneClientFrame(_ buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var offset = 2
        var length = Int(bytes[1] & 0x7F)
        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            length = 0
            for i in 0..<8 {
                length = (length << 8) | Int(bytes[offset + i])
            }
            offset += 8
        }
        var maskKey: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            payload[i] = masked ? (bytes[offset + i] ^ maskKey[i % 4]) : bytes[offset + i]
        }
        buffer.removeFirst(offset + length)
        return (opcode, Data(payload))
    }

    private func handleClientFrame(conn: NWConnection, clientUUID: String, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x09: // Ping -> Pong
            sendWSFrame(on: conn, opcode: 0x0A, payload: payload)
        case 0x08: // Close
            conn.cancel()
        case 0x01: // Control JSON
            if let json = JSONValue.parse(payload), json["type"]?.stringValue == "list_servers" {
                lock.lock()
                listServersCount += 1
                let currentDesktops = desktops.values.sorted { $0.uuid < $1.uuid }
                lock.unlock()
                let reqId = json["request_id"]?.stringValue ?? ""
                let serverItems = currentDesktops.map { #"{"uuid":"\#($0.uuid)","name":"\#($0.name)","type":"CodingProfessionalAgent"}"# }.joined(separator: ",")
                sendWSFrame(
                    on: conn,
                    opcode: 0x01,
                    payload: Data(#"{"type":"server_list","request_id":"\#(reqId)","servers":[\#(serverItems)]}"#.utf8)
                )
            }
        case 0x02: // Binary Tunnel packet
            guard let outer = try? TunnelProtocol.decodeTunnelFrame(payload),
                  outer.payloadType == TunnelProtocol.muxPayloadType,
                  let mux = try? TunnelProtocol.decodeMuxFrame(outer.payload)
            else {
                return
            }
            lock.lock()
            let shouldDropBufferFull: Bool
            if dropNextBinaryFramesWithBufferFull > 0 {
                dropNextBinaryFramesWithBufferFull -= 1
                shouldDropBufferFull = true
            } else {
                shouldDropBufferFull = false
            }
            lock.unlock()
            if shouldDropBufferFull {
                let err = #"{"type":"error","code":"target_buffer_full","target_uuid":"\#(outer.dstUUID)","message":"peer send queue is full"}"#
                sendWSFrame(on: conn, opcode: 0x01, payload: Data(err.utf8))
                return
            }
            handleMuxFromClient(conn: conn, clientUUID: clientUUID, serverUUID: outer.dstUUID, mux: mux)
        default:
            break
        }
    }

    private func handleMuxFromClient(conn: NWConnection, clientUUID: String, serverUUID: String, mux: DecodedMuxFrame) {
        lock.lock()
        let desktop = desktops[serverUUID]
        lock.unlock()

        guard let desktop else {
            let err = #"{"type":"error","code":"target_not_found","target_uuid":"\#(serverUUID)","message":"target peer is not connected"}"#
            sendWSFrame(on: conn, opcode: 0x01, payload: Data(err.utf8))
            return
        }

        let expectedCookie = "cpa_sid=valid-\(desktop.password)"
        switch mux.meta {
        case .httpRequest(let id, _, let path, let headers):
            let cookie = TunnelProtocol.headerValue(for: "Cookie", in: headers) ?? ""
            if path == "/api/auth/status" {
                let required = !desktop.password.isEmpty
                lock.lock()
                let forceAuthed: Bool
                if fakeAuthenticatedStatusResponses > 0 {
                    fakeAuthenticatedStatusResponses -= 1
                    forceAuthed = true
                } else {
                    forceAuthed = false
                }
                lock.unlock()
                lock.lock()
                let spoofFirst = injectSpoofedPeerBeforeAuthenticReply
                let statusDelay = delayHttpStatusMilliseconds
                lock.unlock()

                if spoofFirst {
                    sendMux(
                        on: conn,
                        serverUUID: "srv-evil",
                        clientUUID: clientUUID,
                        meta: .httpResponse(id: id, status: 418, headers: ["content-type": .string("application/json")]),
                        body: Data(#"{"spoofed":true}"#.utf8)
                    )
                }

                let authed = !required || forceAuthed || cookie.contains(expectedCookie)
                let body = Data(#"{"required":\#(required),"authenticated":\#(authed)}"#.utf8)
                let sendAuthentic: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.sendMux(
                        on: conn,
                        serverUUID: serverUUID,
                        clientUUID: clientUUID,
                        meta: .httpResponse(id: id, status: 200, headers: ["content-type": .string("application/json")]),
                        body: body
                    )
                }
                if statusDelay > 0 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(statusDelay), execute: sendAuthentic)
                } else {
                    sendAuthentic()
                }
            } else if path == "/api/auth/login" {
                let submitted = JSONValue.parse(mux.body)?["password"]?.stringValue ?? ""
                if submitted == desktop.password {
                    sendMux(
                        on: conn,
                        serverUUID: serverUUID,
                        clientUUID: clientUUID,
                        meta: .httpResponse(
                            id: id,
                            status: 200,
                            headers: [
                                "set-cookie": .array([.string("\(expectedCookie); Path=/; HttpOnly")]),
                                "content-type": .string("application/json"),
                            ]
                        ),
                        body: Data(#"{"ok":true}"#.utf8)
                    )
                } else {
                    sendMux(
                        on: conn,
                        serverUUID: serverUUID,
                        clientUUID: clientUUID,
                        meta: .httpResponse(id: id, status: 401, headers: ["content-type": .string("application/json")]),
                        body: Data(#"{"error":"unauthorized"}"#.utf8)
                    )
                }
            }
        case .wsOpen(let connId, _, let headers):
            let cookie = TunnelProtocol.headerValue(for: "Cookie", in: headers) ?? ""
            if !desktop.password.isEmpty, !cookie.contains(expectedCookie) {
                sendMux(
                    on: conn,
                    serverUUID: serverUUID,
                    clientUUID: clientUUID,
                    meta: .wsOpenResult(connId: connId, ok: false, status: 401, error: "Unauthorized", headers: nil)
                )
                return
            }
            lock.lock()
            openVirtualStreams[connId] = serverUUID
            let ackDelay = delayWsOpenAckMilliseconds
            lock.unlock()
            let sendAck = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillOpen = self.openVirtualStreams[connId] != nil
                self.lock.unlock()
                guard stillOpen else { return }
                self.sendMux(
                    on: conn,
                    serverUUID: serverUUID,
                    clientUUID: clientUUID,
                    meta: .wsOpenResult(connId: connId, ok: true, status: nil, error: nil, headers: nil)
                )
                let hello = Data(#"{"type":"hello","clientId":"mock-cid-1"}"#.utf8)
                self.sendMux(on: conn, serverUUID: serverUUID, clientUUID: clientUUID, meta: .wsData(connId: connId, opcode: "text"), body: hello)
            }
            if ackDelay > 0 {
                queue.asyncAfter(deadline: .now() + .milliseconds(ackDelay), execute: sendAck)
            } else {
                sendAck()
            }
        case .wsData(let connId, _):
            guard let rpc = JSONValue.parse(mux.body),
                  rpc["type"]?.stringValue == "rpc",
                  let callId = rpc["id"]?.stringValue,
                  let method = rpc["method"]?.stringValue
            else {
                return
            }
            let result: JSONValue
            switch method {
            case "session:getActiveRuns":
                result = .array([])
            case "kvstore:get":
                let key = rpc["args"]?.arrayValue?.first?.stringValue ?? ""
                if key == "projects" {
                    result = .array([
                        ["id": "p1", "name": "Alpha", "path": "/tmp/alpha", "paths": ["/tmp/alpha"], "pinned": false],
                    ])
                } else if key == "cachedModels" {
                    result = .array([])
                } else {
                    result = .null
                }
            case "session:listSessions":
                result = .array([
                    ["id": "s1", "title": "Hello Tunnel", "projectId": "p1", "createdAt": 1000, "updatedAt": 2000],
                ])
            default:
                result = .null
            }
            let reply: JSONValue = [
                "type": "rpc_result",
                "id": .string(callId),
                "result": result,
            ]
            if let data = try? JSONEncoder().encode(reply) {
                sendMux(on: conn, serverUUID: serverUUID, clientUUID: clientUUID, meta: .wsData(connId: connId, opcode: "text"), body: data)
            }
        case .wsClose(let connId, _, _):
            lock.lock()
            receivedWsCloseCount += 1
            openVirtualStreams.removeValue(forKey: connId)
            lock.unlock()
        default:
            break
        }
    }

    private func sendMux(
        on conn: NWConnection,
        serverUUID: String,
        clientUUID: String,
        meta: TunnelMuxMeta,
        body: Data = Data()
    ) {
        guard let inner = try? TunnelProtocol.encodeMuxFrame(meta: meta, body: body),
              let outer = try? TunnelProtocol.encodeTunnelFrame(
                  payloadType: TunnelProtocol.muxPayloadType,
                  srcUUID: serverUUID,
                  dstUUID: clientUUID,
                  payload: inner
              )
        else {
            return
        }
        sendWSFrame(on: conn, opcode: 0x02, payload: outer)
    }

    private func sendWSFrame(on conn: NWConnection, opcode: UInt8, payload: Data, completion: (@Sendable () -> Void)? = nil) {
        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var len = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in
            completion?()
        })
    }
}
