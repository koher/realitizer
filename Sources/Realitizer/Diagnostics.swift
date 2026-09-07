/// The severity of a diagnostic emitted by a Realitizer validator or compiler.
public enum DiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

/// A machine-readable problem associated with a stable path in a model definition.
public struct ModelDiagnostic: Codable, Equatable, Sendable {
    public let severity: DiagnosticSeverity
    public let code: String
    public let path: String
    public let message: String

    public init(
        severity: DiagnosticSeverity,
        code: String,
        path: String,
        message: String
    ) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }
}

/// The complete result of validating a model definition.
public struct ModelValidationReport: Equatable, Sendable {
    public let diagnostics: [ModelDiagnostic]

    public init(diagnostics: [ModelDiagnostic] = []) {
        self.diagnostics = diagnostics
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    public func throwingIfNeeded() throws {
        if hasErrors {
            throw ModelValidationError(diagnostics: diagnostics)
        }
    }
}

/// An error containing structured validation diagnostics.
public struct ModelValidationError: Error, CustomStringConvertible, Sendable {
    public let diagnostics: [ModelDiagnostic]

    public init(diagnostics: [ModelDiagnostic]) {
        self.diagnostics = diagnostics
    }

    public var description: String {
        diagnostics
            .map { "[\($0.code)] \($0.path): \($0.message)" }
            .joined(separator: "\n")
    }
}

extension ModelDiagnostic {
    static func error(_ code: String, path: String, _ message: String) -> Self {
        Self(severity: .error, code: code, path: path, message: message)
    }
}
