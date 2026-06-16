// Sources/EdgeRumCore/AttributeBag.swift
//
// Flat key→primitive bag of attributes. Lives inside EdgeRumCore so
// the Recorder, ContextProvider, and PayloadBuilder all share one
// representation; never surfaces through the public umbrella module.
//
// Merge semantics: `lhs.merging(rhs)` returns a new bag where rhs
// keys win on conflict — CLAUDE.md "Recorder + transport implementation
// notes" step 2: `contextBag.merging(eventBag) { _, new in new }`.
//
// Refs: PLAN-iOS.md §7.6 (type discipline), §F3/T3.2.
//

import Foundation

/// A flat dictionary of attribute keys to `AttributeValue` primitives.
///
/// Internal-only — only used inside EdgeRumCore and friends. The bag
/// is the single shape every layer agrees on: capture sites flatten
/// nested data into it with dot-notation keys, the `ContextProvider`
/// fills the identity attributes, the `Recorder` merges them, and the
/// `PayloadBuilder` encodes the result to JSON.
public struct AttributeBag: Sendable, Hashable {

    public private(set) var values: [String: AttributeValue]

    public init(_ values: [String: AttributeValue] = [:]) {
        self.values = values
    }

    // MARK: Access

    public subscript(key: String) -> AttributeValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public mutating func set(_ key: String, _ value: AttributeValue) {
        values[key] = value
    }

    public mutating func setIfPresent(_ key: String, _ value: AttributeValue?) {
        if let value { values[key] = value }
    }

    public mutating func merge(_ other: AttributeBag) {
        for (key, value) in other.values {
            values[key] = value
        }
    }

    public mutating func merge(_ other: [String: AttributeValue]) {
        for (key, value) in other {
            values[key] = value
        }
    }

    // MARK: Merge

    /// Returns a new bag with `other`'s values overlaid on this bag's.
    /// On key conflict, `other` wins — the contract is
    /// "event attrs win on conflict" so callers pass the event bag
    /// as the argument and the context bag as the receiver.
    public func merging(_ other: AttributeBag) -> AttributeBag {
        var copy = self
        copy.merge(other)
        return copy
    }

    public func merging(_ other: [String: AttributeValue]) -> AttributeBag {
        var copy = self
        copy.merge(other)
        return copy
    }

    // MARK: Inspection

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
    public var keys: Dictionary<String, AttributeValue>.Keys { values.keys }
}

extension AttributeBag: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AttributeValue)...) {
        var dict: [String: AttributeValue] = [:]
        for (k, v) in elements { dict[k] = v }
        self.init(dict)
    }
}
