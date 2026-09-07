import simd

/// A RealityKit-independent local transform.
public struct ModelTransform: Equatable, Sendable, Codable {
    public var scale: SIMD3<Float>
    public var rotation: simd_quatf
    public var translation: SIMD3<Float>

    public init(
        scale: SIMD3<Float> = .one,
        rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
        translation: SIMD3<Float> = .zero
    ) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = ModelTransform()

    public var matrix: simd_float4x4 {
        var value = simd_float4x4(rotation)
        value.columns.0 *= scale.x
        value.columns.1 *= scale.y
        value.columns.2 *= scale.z
        value.columns.3 = SIMD4(translation, 1)
        return value
    }

    private enum CodingKeys: String, CodingKey { case scale, rotation, translation }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scale = try values.decode(SIMD3<Float>.self, forKey: .scale)
        rotation = simd_quatf(vector: try values.decode(SIMD4<Float>.self, forKey: .rotation))
        translation = try values.decode(SIMD3<Float>.self, forKey: .translation)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scale, forKey: .scale)
        try values.encode(rotation.vector, forKey: .rotation)
        try values.encode(translation, forKey: .translation)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scale == rhs.scale
            && lhs.rotation.vector == rhs.rotation.vector
            && lhs.translation == rhs.translation
    }

    public var isFinite: Bool {
        scale.isFinite
            && rotation.vector.isFinite
            && translation.isFinite
    }

    public func applying(to point: SIMD3<Float>) -> SIMD3<Float> {
        translation + rotation.act(scale * point)
    }

    public func applyingToNormal(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        let safeScale = SIMD3<Float>(
            scale.x == 0 ? 1 : scale.x,
            scale.y == 0 ? 1 : scale.y,
            scale.z == 0 ? 1 : scale.z
        )
        let transformed = rotation.act(normal / safeScale)
        let length = simd_length(transformed)
        return length > 0 ? transformed / length : .zero
    }

    public func interpolated(to other: Self, progress: Float) -> Self {
        let amount = min(max(progress, 0), 1)
        return Self(
            scale: simd_mix(scale, other.scale, SIMD3(repeating: amount)),
            rotation: simd_slerp(rotation.normalized, other.rotation.normalized, amount),
            translation: simd_mix(
                translation,
                other.translation,
                SIMD3(repeating: amount)
            )
        )
    }
}

extension SIMD2 where Scalar == Float {
    package var isFinite: Bool { x.isFinite && y.isFinite }
}

extension SIMD3 where Scalar == Float {
    package var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

extension SIMD4 where Scalar == Float {
    package var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
