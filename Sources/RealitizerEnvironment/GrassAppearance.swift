import Realitizer
import simd

/// A deliberately inexpensive approximation of ambient, wrapped sun and leaf transmission.
/// It does not sample scene lights or shadow maps. Colors must be opaque and in 0...1.
public struct GrassAppearance: Equatable, Sendable {
    public let rootColor: RGBAColor
    public let tipColor: RGBAColor
    public let sunDirection: SIMD3<Float>
    public let ambient: Float
    public let transmission: Float

    public init(
        rootColor: RGBAColor = .init(red: 0.24, green: 0.44, blue: 0.08),
        tipColor: RGBAColor = .init(red: 0.66, green: 0.82, blue: 0.26),
        sunDirection: SIMD3<Float> = [-0.4, 0.8, 0.45], ambient: Float = 0.65,
        transmission: Float = 0.15
    ) throws {
        let colors = [rootColor, tipColor]
        guard colors.allSatisfy({ $0.isFinite && $0.alpha == 1
            && (0...1).contains($0.red) && (0...1).contains($0.green) && (0...1).contains($0.blue) }),
            sunDirection.isFinite, simd_length(sunDirection).isFinite, simd_length(sunDirection) > 0.0001,
            ambient.isFinite, (0...1).contains(ambient),
            transmission.isFinite, (0...1).contains(transmission)
        else { throw modelingError("grass.appearance", "Grass appearance requires opaque unit-range colors, a nonzero sun direction and unit-range lighting weights.") }
        self.rootColor = rootColor
        self.tipColor = tipColor
        self.sunDirection = simd_normalize(sunDirection)
        self.ambient = ambient
        self.transmission = transmission
    }
}
