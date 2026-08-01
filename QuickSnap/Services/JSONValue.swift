//
//  JSONValue.swift
//  QuickSnap
//

import Foundation

/// A parsed JSON value.
///
/// Exists because the MCP surface is dynamically shaped — tool arguments and
/// results are whatever each tool's schema says — and `[String: Any]` from
/// `JSONSerialization` is not `Sendable`, so it can't cross from the
/// listener's queue to the main actor. This can, and it makes the tool code
/// read like the JSON it produces.
nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Bridging

    init(_ any: Any) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as Bool where type(of: any) == type(of: true):
            self = .bool(value)
        case let value as NSNumber:
            // NSNumber erases Bool to 0/1, so check its ObjC type encoding.
            self = strcmp(value.objCType, "c") == 0 ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(any)
    }

    var serialized: Data {
        (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    // MARK: - Access

    subscript(key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// A trimmed, non-empty string argument, or nil — how every optional
    /// string parameter on the tool surface wants to be read.
    func trimmedString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
