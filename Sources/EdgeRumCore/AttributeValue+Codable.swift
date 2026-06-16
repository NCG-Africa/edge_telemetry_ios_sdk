// Sources/EdgeRumCore/AttributeValue+Codable.swift
//
// `Codable` conformance for `AttributeValue`. Each case encodes to its
// raw JSON primitive — string, integer, double, or boolean — exactly
// what the EdgeTelemetryProcessor wire contract demands.
//
// Decoding tries `Bool` first; on Apple's Foundation a JSON `true` /
// `false` decodes to `Bool` cleanly, while a JSON `1` / `0` only
// decodes to `Int`. Ordering Bool ahead of Int avoids ambiguity from
// NSNumber's dual conformance.
//
// Refs: PLAN-iOS.md §7.2, §7.6, §F3/T3.2 ("JSONEncoder extension
//       encodes each AttributeValue to raw JSON").
//

import Foundation

extension AttributeValue: Codable {

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try c.encode(s)
        case .int(let i):
            try c.encode(i)
        case .double(let d):
            try c.encode(d)
        case .bool(let b):
            try c.encode(b)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool BEFORE Int — see file header.
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                AttributeValue.self,
                DecodingError.Context(
                    codingPath: c.codingPath,
                    debugDescription: "AttributeValue must be string, int, double, or bool"
                )
            )
        }
    }
}
