import Foundation

// Loosely typed JSON value used for RPC arguments, results and event payloads.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self {
            return object[key]
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    // Decodes a typed model by round-tripping through JSON.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    // Decodes every element of an array, skipping elements that do not match the model.
    func decodeList<T: Decodable>(_ type: T.Type) -> [T] {
        guard let items = arrayValue else { return [] }
        return items.compactMap { try? $0.decode(type) }
    }

    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    init(floatLiteral value: Double) {
        self = .number(value)
    }

    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue {
    // Wraps an optional string, mapping nil to JSON null.
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}

extension Date {
    // Milliseconds since 1970, matching JavaScript Date.now().
    var milliseconds: Double {
        (timeIntervalSince1970 * 1000).rounded()
    }
}
