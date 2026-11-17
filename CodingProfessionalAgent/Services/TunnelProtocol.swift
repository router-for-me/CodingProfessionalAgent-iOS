import Foundation

struct DiscoveredTunnelServer: Identifiable, Codable, Hashable, Sendable {
    let uuid: String
    let name: String
    let type: String

    var id: String { uuid }
}

enum TunnelProtocolError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case missingScheme
    case unsupportedScheme(String)
    case invalidURL(String)
    case emptyAPIKey
    case invalidAPIKey
    case invalidUUID
    case payloadTooLarge
    case malformedFrame(String)
    case unsupportedVersion(UInt8)

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            L10n.ErrorMessage.tunnelEmptyURL
        case .missingScheme:
            L10n.ErrorMessage.tunnelMissingScheme
        case .unsupportedScheme(let scheme):
            L10n.ErrorMessage.tunnelUnsupportedScheme(scheme)
        case .invalidURL(let detail):
            detail
        case .emptyAPIKey:
            L10n.ErrorMessage.tunnelEmptyAPIKey
        case .invalidAPIKey:
            L10n.ErrorMessage.tunnelInvalidAPIKey
        case .invalidUUID:
            L10n.ErrorMessage.tunnelInvalidUUID
        case .payloadTooLarge:
            L10n.ErrorMessage.tunnelPayloadTooLarge
        case .malformedFrame(let detail):
            L10n.ErrorMessage.tunnelMalformedFrame(detail)
        case .unsupportedVersion(let version):
            L10n.ErrorMessage.tunnelUnsupportedVersion(version)
        }
    }
}

struct TunnelEndpoint: Equatable, Hashable, Sendable {
    let normalizedBaseURL: String
    let webSocketBaseURL: String

    func handshakeURL(clientUUID: String, clientName: String) throws -> URL {
        guard TunnelProtocol.isValidUUID(clientUUID) else {
            throw TunnelProtocolError.invalidUUID
        }
        guard var components = URLComponents(string: webSocketBaseURL) else {
            throw TunnelProtocolError.invalidURL(L10n.ErrorMessage.tunnelInvalidURL)
        }
        let cleanName = TunnelProtocol.sanitizeClientName(clientName)
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        let encodedUUID = clientUUID.addingPercentEncoding(withAllowedCharacters: allowed) ?? clientUUID
        let encodedName = cleanName.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleanName
        components.percentEncodedQuery = "role=client&uuid=\(encodedUUID)&name=\(encodedName)"
        guard let url = components.url else {
            throw TunnelProtocolError.invalidURL(L10n.ErrorMessage.tunnelInvalidURL)
        }
        return url
    }
}

enum TunnelControlEvent: Equatable, Sendable {
    case serverList(requestId: String?, servers: [DiscoveredTunnelServer])
    case serverOnline(DiscoveredTunnelServer)
    case serverOffline(DiscoveredTunnelServer)
    case error(code: String, targetUUID: String?, message: String)
}

struct DecodedTunnelFrame: Equatable, Sendable {
    let version: UInt8
    let payloadType: UInt8
    let srcUUID: String
    let dstUUID: String
    let payload: Data
}

enum TunnelMuxMeta: Equatable, Sendable {
    case httpRequest(id: String, method: String, path: String, headers: [String: JSONValue]?)
    case httpResponse(id: String, status: Int, headers: [String: JSONValue]?)
    case wsOpen(connId: String, path: String, headers: [String: JSONValue]?)
    case wsOpenResult(connId: String, ok: Bool, status: Int?, error: String?, headers: [String: JSONValue]?)
    case wsData(connId: String, opcode: String)
    case wsClose(connId: String, code: Int?, reason: String?)
}

struct DecodedMuxFrame: Equatable, Sendable {
    let meta: TunnelMuxMeta
    let body: Data
}

// Stateless codec and validator for CLIProxyAPI /v1/tunnel and CPA PayloadType=0x02 multiplexing.
enum TunnelProtocol {
    /// Only tunnel servers declaring this handshake `type` are CPA desktop endpoints.
    /// Servers with any other (or missing) type are filtered out of discovery.
    static let expectedServerType = "CodingProfessionalAgent"
    static let protocolVersion: UInt8 = 0x01
    static let muxPayloadType: UInt8 = 0x02
    static let maxRawPayloadBytes = 67_108_864 // 64 MiB
    static let maxInboundFrameBytes = 67_109_376 // 64 MiB + 512
    static let maxMuxMetaBytes = 65_536 // 64 KiB
    static let maxControlFrameBytes = 4_096

    static func parseEndpoint(_ raw: String) -> Result<TunnelEndpoint, TunnelProtocolError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyURL)
        }
        guard let schemeRange = trimmed.range(of: "://") else {
            return .failure(.missingScheme)
        }
        let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
        let isSecure: Bool
        switch scheme {
        case "http", "ws":
            isSecure = false
        case "https", "wss":
            isSecure = true
        default:
            return .failure(.unsupportedScheme(scheme))
        }

        if trimmed.contains("#") {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelUrlHasFragment))
        }
        if trimmed.contains("?") {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelUrlHasQuery))
        }

        let afterScheme = trimmed[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authoritySlice = afterScheme[..<authorityEnd]
        if authoritySlice.contains("@") {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelUrlHasCredentials))
        }

        var explicitPort: Int?
        if authoritySlice.hasPrefix("[") {
            guard let closeBracket = authoritySlice.firstIndex(of: "]") else {
                return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidIPv6))
            }
            let remainder = authoritySlice[authoritySlice.index(after: closeBracket)...]
            if !remainder.isEmpty {
                guard remainder.hasPrefix(":") else {
                    return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidURL))
                }
                let portDigits = remainder.dropFirst()
                guard !portDigits.isEmpty,
                      portDigits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                      let parsed = Int(portDigits),
                      (1...65535).contains(parsed)
                else {
                    return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidPort))
                }
                explicitPort = parsed
            }
        } else if let colon = authoritySlice.firstIndex(of: ":") {
            let portDigits = authoritySlice[authoritySlice.index(after: colon)...]
            if portDigits.contains(":") {
                return .failure(.invalidURL(L10n.ErrorMessage.tunnelIPv6Brackets))
            }
            guard !portDigits.isEmpty,
                  portDigits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let parsed = Int(portDigits),
                  (1...65535).contains(parsed)
            else {
                return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidPort))
            }
            explicitPort = parsed
        }

        guard let components = URLComponents(string: trimmed),
              let rawHost = components.host,
              !rawHost.isEmpty
        else {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidURL))
        }

        if (components.user != nil && !(components.user?.isEmpty ?? true)) ||
            (components.password != nil && !(components.password?.isEmpty ?? true))
        {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelUrlHasCredentials))
        }
        if components.query != nil || components.fragment != nil {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelUrlHasQueryOrFragment))
        }

        let bareHost = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !bareHost.isEmpty else {
            return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidHost))
        }
        let formattedHost = bareHost.contains(":") ? "[\(bareHost)]" : bareHost

        var portSuffix = ""
        if let port = explicitPort ?? components.port {
            guard (1...65535).contains(port) else {
                return .failure(.invalidURL(L10n.ErrorMessage.tunnelInvalidPort))
            }
            let defaultPort = isSecure ? 443 : 80
            if port != defaultPort {
                portSuffix = ":\(port)"
            }
        }

        var cleanPath = components.percentEncodedPath
        while cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        let basePath: String
        if cleanPath.hasSuffix("/v1/tunnel") {
            basePath = String(cleanPath.dropLast("/v1/tunnel".count))
        } else if cleanPath.hasSuffix("/v1") {
            basePath = String(cleanPath.dropLast("/v1".count))
        } else {
            basePath = cleanPath
        }

        let httpScheme = isSecure ? "https" : "http"
        let wsScheme = isSecure ? "wss" : "ws"
        let authority = "\(formattedHost)\(portSuffix)"
        let normalizedPath = (basePath.hasSuffix("/v1") || basePath.hasSuffix("/v1/tunnel"))
            ? "\(basePath)/v1/tunnel"
            : basePath
        return .success(TunnelEndpoint(
            normalizedBaseURL: "\(httpScheme)://\(authority)\(normalizedPath)",
            webSocketBaseURL: "\(wsScheme)://\(authority)\(basePath)/v1/tunnel"
        ))
    }

    static func validateAPIKey(_ raw: String) -> Result<String, TunnelProtocolError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyAPIKey)
        }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return .failure(.invalidAPIKey)
            }
        }
        return .success(trimmed)
    }

    static func isValidUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    static func sanitizeClientName(_ raw: String) -> String {
        let filteredScalars = raw.unicodeScalars.filter { scalar in
            scalar.value > 0x1F && scalar.value != 0x7F
        }
        let cleaned = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "CPA-iOS" }

        var result = ""
        var usedBytes = 0
        for character in cleaned {
            let charBytes = character.utf8.count
            if usedBytes + charBytes > 256 {
                break
            }
            result.append(character)
            usedBytes += charBytes
        }
        let finalName = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalName.isEmpty ? "CPA-iOS" : finalName
    }

    static func redactSecret(_ text: String, secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !trimmed.isEmpty else { return text }
        var output = text.replacingOccurrences(of: trimmed, with: "[REDACTED]")
        let allowedSets: [CharacterSet] = [
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"),
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"),
            .urlQueryAllowed,
            .alphanumerics,
        ]
        for allowed in allowedSets {
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
               !encoded.isEmpty,
               encoded != trimmed
            {
                output = output.replacingOccurrences(of: encoded, with: "[REDACTED]", options: [.caseInsensitive])
            }
        }
        return output
    }

    // Outbound client control frames are capped at 4 KiB, whereas inbound server_list frames from
    // CLIProxyAPI may exceed 4 KiB up to the transport inbound ceiling (websocket-tunnel_CN.md §3).
    static func decodeControlFrame(_ data: Data) -> TunnelControlEvent? {
        guard data.count <= maxInboundFrameBytes,
              String(data: data, encoding: .utf8) != nil,
              let json = JSONValue.parse(data),
              let type = json["type"]?.stringValue
        else {
            return nil
        }

        switch type {
        case "server_list":
            let requestId = json["request_id"]?.stringValue
            let servers = (json["servers"]?.arrayValue ?? []).compactMap { item -> DiscoveredTunnelServer? in
                guard let uuid = item["uuid"]?.stringValue, !uuid.isEmpty,
                      let name = item["name"]?.stringValue,
                      let serverType = item["type"]?.stringValue,
                      serverType == expectedServerType
                else {
                    return nil
                }
                return DiscoveredTunnelServer(uuid: uuid, name: name, type: serverType)
            }
            return .serverList(requestId: requestId, servers: servers)
        case "server_online":
            guard let srv = json["server"],
                  let uuid = srv["uuid"]?.stringValue, !uuid.isEmpty,
                  let name = srv["name"]?.stringValue,
                  let serverType = srv["type"]?.stringValue,
                  serverType == expectedServerType
            else {
                return nil
            }
            return .serverOnline(DiscoveredTunnelServer(uuid: uuid, name: name, type: serverType))
        case "server_offline":
            guard let srv = json["server"],
                  let uuid = srv["uuid"]?.stringValue, !uuid.isEmpty
            else {
                return nil
            }
            // Offline is keyed by uuid only; it is honored regardless of type so any
            // previously tracked entry is removed even if the field is absent.
            let name = srv["name"]?.stringValue ?? ""
            let serverType = srv["type"]?.stringValue ?? ""
            return .serverOffline(DiscoveredTunnelServer(uuid: uuid, name: name, type: serverType))
        case "error":
            guard let code = json["code"]?.stringValue, !code.isEmpty else {
                return nil
            }
            return .error(
                code: code,
                targetUUID: json["target_uuid"]?.stringValue,
                message: json["message"]?.stringValue ?? code
            )
        default:
            return nil
        }
    }

    static func encodeListServersFrame(requestId: String) throws -> String {
        let cleanId = String(requestId.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
        let truncatedId = String(cleanId.utf8.prefix(128)).flatMap { String($0) } ?? "refresh"
        let payload: JSONValue = [
            "type": "list_servers",
            "request_id": .string(truncatedId),
        ]
        return try payload.jsonString()
    }

    static func encodeTunnelFrame(
        payloadType: UInt8,
        srcUUID: String,
        dstUUID: String,
        payload: Data
    ) throws -> Data {
        guard isValidUUID(srcUUID), isValidUUID(dstUUID) else {
            throw TunnelProtocolError.invalidUUID
        }
        guard payload.count <= maxRawPayloadBytes else {
            throw TunnelProtocolError.payloadTooLarge
        }
        let srcBytes = Array(srcUUID.utf8)
        let dstBytes = Array(dstUUID.utf8)
        var frame = Data(capacity: 4 + srcBytes.count + dstBytes.count + payload.count)
        frame.append(protocolVersion)
        frame.append(payloadType)
        frame.append(UInt8(srcBytes.count))
        frame.append(UInt8(dstBytes.count))
        frame.append(contentsOf: srcBytes)
        frame.append(contentsOf: dstBytes)
        frame.append(payload)
        return frame
    }

    static func decodeTunnelFrame(_ raw: Data) throws -> DecodedTunnelFrame {
        guard raw.count >= 4 else {
            throw TunnelProtocolError.malformedFrame("short header")
        }
        let base = raw.startIndex
        let version = raw[base]
        guard version == protocolVersion else {
            throw TunnelProtocolError.unsupportedVersion(version)
        }
        let payloadType = raw[base + 1]
        let srcLen = Int(raw[base + 2])
        let dstLen = Int(raw[base + 3])
        let headerLen = 4 + srcLen + dstLen
        guard (1...128).contains(srcLen),
              (1...128).contains(dstLen),
              raw.count >= headerLen
        else {
            throw TunnelProtocolError.malformedFrame("invalid header lengths")
        }

        let srcData = raw[(base + 4)..<(base + 4 + srcLen)]
        let dstData = raw[(base + 4 + srcLen)..<(base + headerLen)]
        guard srcData.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
              dstData.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }),
              let srcUUID = String(data: srcData, encoding: .utf8),
              let dstUUID = String(data: dstData, encoding: .utf8)
        else {
            throw TunnelProtocolError.malformedFrame("invalid UUID bytes")
        }

        let bodySlice = raw[(base + headerLen)..<raw.endIndex]
        guard bodySlice.count <= maxRawPayloadBytes else {
            throw TunnelProtocolError.payloadTooLarge
        }
        return DecodedTunnelFrame(
            version: version,
            payloadType: payloadType,
            srcUUID: srcUUID,
            dstUUID: dstUUID,
            payload: Data(bodySlice)
        )
    }

    static func encodeMuxFrame(meta: TunnelMuxMeta, body: Data = Data()) throws -> Data {
        let metaJSON: JSONValue
        switch meta {
        case .httpRequest(let id, let method, let path, let headers):
            var obj: [String: JSONValue] = [
                "type": "http_request",
                "id": .string(id),
                "method": .string(method),
                "path": .string(path),
            ]
            if let headers, !headers.isEmpty {
                obj["headers"] = .object(headers)
            }
            metaJSON = .object(obj)
        case .httpResponse(let id, let status, let headers):
            var obj: [String: JSONValue] = [
                "type": "http_response",
                "id": .string(id),
                "status": .number(Double(status)),
            ]
            if let headers, !headers.isEmpty {
                obj["headers"] = .object(headers)
            }
            metaJSON = .object(obj)
        case .wsOpen(let connId, let path, let headers):
            var obj: [String: JSONValue] = [
                "type": "ws_open",
                "connId": .string(connId),
                "path": .string(path),
            ]
            if let headers, !headers.isEmpty {
                obj["headers"] = .object(headers)
            }
            metaJSON = .object(obj)
        case .wsOpenResult(let connId, let ok, let status, let error, let headers):
            var obj: [String: JSONValue] = [
                "type": "ws_open_result",
                "connId": .string(connId),
                "ok": .bool(ok),
            ]
            if let status {
                obj["status"] = .number(Double(status))
            }
            if let error {
                obj["error"] = .string(error)
            }
            if let headers, !headers.isEmpty {
                obj["headers"] = .object(headers)
            }
            metaJSON = .object(obj)
        case .wsData(let connId, let opcode):
            metaJSON = [
                "type": "ws_data",
                "connId": .string(connId),
                "opcode": .string(opcode),
            ]
        case .wsClose(let connId, let code, let reason):
            var obj: [String: JSONValue] = [
                "type": "ws_close",
                "connId": .string(connId),
            ]
            if let code {
                obj["code"] = .number(Double(code))
            }
            if let reason {
                obj["reason"] = .string(reason)
            }
            metaJSON = .object(obj)
        }

        let metaData = try JSONEncoder().encode(metaJSON)
        guard (1...maxMuxMetaBytes).contains(metaData.count) else {
            throw TunnelProtocolError.malformedFrame("mux metadata out of bounds")
        }
        let totalLen = 4 + metaData.count + body.count
        guard totalLen <= maxRawPayloadBytes else {
            throw TunnelProtocolError.payloadTooLarge
        }

        var out = Data(capacity: totalLen)
        var lengthBE = UInt32(metaData.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
        out.append(metaData)
        out.append(body)
        return out
    }

    static func decodeMuxFrame(_ raw: Data) throws -> DecodedMuxFrame {
        guard raw.count >= 5 else {
            throw TunnelProtocolError.malformedFrame("short mux frame")
        }
        let base = raw.startIndex
        let metaLen = (Int(raw[base]) << 24)
            | (Int(raw[base + 1]) << 16)
            | (Int(raw[base + 2]) << 8)
            | Int(raw[base + 3])
        guard (1...maxMuxMetaBytes).contains(metaLen), 4 + metaLen <= raw.count else {
            throw TunnelProtocolError.malformedFrame("invalid mux metadata length")
        }
        let metaSlice = raw[(base + 4)..<(base + 4 + metaLen)]
        guard String(data: metaSlice, encoding: .utf8) != nil,
              let json = JSONValue.parse(Data(metaSlice)),
              let object = json.objectValue,
              let type = object["type"]?.stringValue
        else {
            throw TunnelProtocolError.malformedFrame("invalid mux metadata JSON")
        }

        let headers = object["headers"]?.objectValue
        let meta: TunnelMuxMeta
        switch type {
        case "http_request":
            guard let id = object["id"]?.stringValue,
                  let method = object["method"]?.stringValue,
                  let path = object["path"]?.stringValue
            else {
                throw TunnelProtocolError.malformedFrame("incomplete http_request")
            }
            meta = .httpRequest(id: id, method: method, path: path, headers: headers)
        case "http_response":
            guard let id = object["id"]?.stringValue,
                  let rawStatus = object["status"]?.doubleValue,
                  let status = exactInt(rawStatus, in: 100...999)
            else {
                throw TunnelProtocolError.malformedFrame("invalid http_response")
            }
            meta = .httpResponse(id: id, status: status, headers: headers)
        case "ws_open":
            guard let connId = object["connId"]?.stringValue else {
                throw TunnelProtocolError.malformedFrame("incomplete ws_open")
            }
            let path = object["path"]?.stringValue ?? "/api/ws"
            meta = .wsOpen(connId: connId, path: path, headers: headers)
        case "ws_open_result":
            guard let connId = object["connId"]?.stringValue,
                  let ok = object["ok"]?.boolValue
            else {
                throw TunnelProtocolError.malformedFrame("incomplete ws_open_result")
            }
            var parsedStatus: Int?
            if let statusField = object["status"], !statusField.isNull {
                guard let rawStatus = statusField.doubleValue,
                      let exactStatus = exactInt(rawStatus, in: 100...999)
                else {
                    throw TunnelProtocolError.malformedFrame("invalid ws_open_result status")
                }
                parsedStatus = exactStatus
            }
            meta = .wsOpenResult(
                connId: connId,
                ok: ok,
                status: parsedStatus,
                error: object["error"]?.stringValue,
                headers: headers
            )
        case "ws_data":
            guard let connId = object["connId"]?.stringValue,
                  let opcode = object["opcode"]?.stringValue
            else {
                throw TunnelProtocolError.malformedFrame("incomplete ws_data")
            }
            meta = .wsData(connId: connId, opcode: opcode)
        case "ws_close":
            guard let connId = object["connId"]?.stringValue else {
                throw TunnelProtocolError.malformedFrame("incomplete ws_close")
            }
            var parsedCode: Int?
            if let codeField = object["code"], !codeField.isNull {
                guard let rawCode = codeField.doubleValue,
                      let exactCode = exactInt(rawCode, in: 0...65535)
                else {
                    throw TunnelProtocolError.malformedFrame("invalid ws_close code")
                }
                parsedCode = exactCode
            }
            meta = .wsClose(
                connId: connId,
                code: parsedCode,
                reason: object["reason"]?.stringValue
            )
        default:
            throw TunnelProtocolError.malformedFrame("unknown mux type \(type)")
        }

        let body = Data(raw[(base + 4 + metaLen)..<raw.endIndex])
        return DecodedMuxFrame(meta: meta, body: body)
    }

    // Extracts a header value case-insensitively, supporting both string and string-array values
    // (such as Node.js http.IncomingHttpHeaders["set-cookie"]).
    static func headerValue(for name: String, in headers: [String: JSONValue]?) -> String? {
        guard let headers else { return nil }
        let target = name.lowercased()
        guard let value = headers.first(where: { $0.key.lowercased() == target })?.value else {
            return nil
        }
        if let single = value.stringValue, !single.isEmpty {
            return single
        }
        if let list = value.arrayValue {
            for item in list {
                if let text = item.stringValue, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func exactInt(_ value: Double, in range: ClosedRange<Int>) -> Int? {
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(range.lowerBound),
              value <= Double(range.upperBound)
        else {
            return nil
        }
        return Int(value)
    }
}
