import simd

/// Scale-aware tolerances. Area comparisons use the square of the length tolerance.
public struct GeometryTolerance: Equatable, Sendable, Codable {
    public var relative: Float
    public var absolute: Float

    public init(relative: Float = 0.000_001, absolute: Float = 0.000_000_01) {
        self.relative = relative
        self.absolute = absolute
    }

    public func length(for extent: Float) -> Float { max(absolute, abs(extent) * relative) }
}

public enum ModelingAxis: Int, CaseIterable, Sendable, Codable {
    case x, y, z
    public var vector: SIMD3<Float> {
        var result = SIMD3<Float>.zero
        result[rawValue] = 1
        return result
    }
}

/// Reproducible SplitMix64 random numbers, independent of Swift's randomized hashing.
public struct ModelingRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

package func modelingError(_ code: String, _ message: String, path: String = "geometry") -> ModelValidationError {
    ModelValidationError(diagnostics: [.error(code, path: path, message)])
}

func cross2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

package func unitVector(_ value: SIMD3<Float>, fallback: SIMD3<Float> = [0, 1, 0]) -> SIMD3<Float> {
    let length = simd_length(value)
    return length.isFinite && length > 1e-12 ? value / length : fallback
}

func orthogonal(to normal: SIMD3<Float>) -> SIMD3<Float> {
    unitVector(simd_cross(abs(normal.x) < 0.8 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1), normal))
}

/// Builds a tangent without normalizing cancellation error from a nearly parallel direction.
func orthonormalTangent(_ tangent: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
    let n = unitVector(normal)
    let fallback = orthogonal(to: n)
    guard tangent.isFinite else { return fallback }
    let scale = simd_reduce_max(simd_abs(tangent))
    guard scale > 0 else { return fallback }

    // Scaling first makes the degeneracy test independent of mesh and UV units and avoids
    // overflow or underflow when measuring an otherwise finite tangent.
    let direction = tangent / scale
    let projected = direction - n * simd_dot(n, direction)
    let angularTolerance = 8 * Float.ulpOfOne
    guard simd_length_squared(projected) > angularTolerance * angularTolerance * simd_length_squared(direction)
    else { return fallback }

    // A second projection removes the residual normal component before normalization can
    // amplify it. The authored normal is left unchanged, including for later validation.
    let corrected = projected - n * simd_dot(n, projected)
    return unitVector(corrected, fallback: fallback)
}

extension simd_float4x4 {
    var finite: Bool {
        columns.0.isFinite && columns.1.isFinite && columns.2.isFinite && columns.3.isFinite
    }
    func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
}
