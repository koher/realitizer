/// A strongly typed identifier used by a model definition.
public protocol RealitizerID: RawRepresentable, Hashable, Sendable where RawValue == String {}

/// A type-erased semantic identifier stored by Realitizer definitions.
public struct AnyRealitizerID: RealitizerID, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init<I: RealitizerID>(_ id: I) {
        rawValue = id.rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension RealitizerID {
    /// Returns a stable type-erased representation of this identifier.
    public var erasedID: AnyRealitizerID {
        AnyRealitizerID(self)
    }
}
