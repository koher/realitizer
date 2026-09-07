import Foundation

/// Non-premultiplied, sRGB-encoded RGB channels and linear alpha.
/// Material colors use channels in 0...1; emission strength is specified separately.
public struct RGBAColor: Equatable, Sendable, Codable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    /// Creates a color from sRGB-encoded channels, not linear light values.
    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(sRGB: SIMD3<Float>, alpha: Float = 1) {
        self.init(red: sRGB.x, green: sRGB.y, blue: sRGB.z, alpha: alpha)
    }

    public init(linearSRGB: SIMD3<Float>, alpha: Float = 1) {
        func encode(_ x: Float) -> Float {
            // Preserve the neutral white attribute exactly across interpolation and topology processing.
            x == 1 ? 1 : (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        self.init(
            red: encode(linearSRGB.x), green: encode(linearSRGB.y), blue: encode(linearSRGB.z),
            alpha: alpha)
    }

    /// Linear light RGB for calculations and GPU uniforms. Alpha is never gamma corrected.
    public var linearSRGB: SIMD3<Float> {
        func decode(_ x: Float) -> Float {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(decode(red), decode(green), decode(blue))
    }

    public var sRGB: SIMD3<Float> { SIMD3(red, green, blue) }

    /// GPU vertex colors and interpolation use linear RGB with straight alpha.
    public var linearRGBA: SIMD4<Float> { SIMD4(linearSRGB, alpha) }

    public var isNormalized: Bool {
        isFinite && (0...1).contains(red) && (0...1).contains(green)
            && (0...1).contains(blue) && (0...1).contains(alpha)
    }

    /// Interpolates RGB in linear light and alpha linearly. The fraction must be in 0...1.
    public func interpolated(to other: Self, fraction: Float) -> Self {
        if fraction == 0 { return self }
        if fraction == 1 { return other }
        return Self(linearSRGB: linearSRGB * (1 - fraction) + other.linearSRGB * fraction,
             alpha: alpha * (1 - fraction) + other.alpha * fraction)
    }

    public static let white = Self(red: 1, green: 1, blue: 1)
    public static let error = Self(red: 1, green: 0.05, blue: 0.2)

    public var isFinite: Bool {
        red.isFinite && green.isFinite && blue.isFinite && alpha.isFinite
    }
}

/// The basic shading model for a generated material.
public enum MaterialShading: String, Sendable, Codable {
    case lit
    case unlit
}

/// Explicit rasterization intent; texture pixels never silently choose a render mode.
public enum MaterialAlphaMode: Equatable, Sendable, Codable {
    case opaque
    case blend
    case mask(cutoff: Float)
}

public enum VertexColorMode: String, Sendable, Codable {
    case ignore
    /// Multiply base color and texture by interpolated vertex RGB in linear sRGB.
    /// Vertex alpha participates only in blend/mask materials. Emission is independent.
    case multiply
}

/// A portable material description compiled by a rendering adapter.
public struct MaterialDefinition: Sendable {
    public let id: AnyRealitizerID
    public var baseColor: RGBAColor
    public var roughness: Float
    public var metallic: Float
    public var shading: MaterialShading
    public var alphaMode: MaterialAlphaMode
    public var vertexColorMode: VertexColorMode
    public var baseColorTexture: TextureImage? = nil
    public var normalTexture: TextureImage? = nil
    public var roughnessTexture: TextureImage? = nil
    public var metallicTexture: TextureImage? = nil
    public var emissiveTexture: TextureImage? = nil
    public var emissiveColor: RGBAColor = .white
    public var emissiveIntensity: Float = 0
    public var doubleSided: Bool = false
    /// Keep the default for scene-integrated surfaces. Disable for authored
    /// unlit colors that must survive the renderer's tone mapping.
    /// Only used by the unlit shading model.
    public var unlitToneMapping: Bool = true

    public init<ID: RealitizerID>(
        id: ID,
        baseColor: RGBAColor,
        roughness: Float = 0.7,
        metallic: Float = 0,
        shading: MaterialShading = .lit,
        alphaMode: MaterialAlphaMode = .opaque,
        vertexColorMode: VertexColorMode = .ignore
    ) {
        self.id = id.erasedID
        self.baseColor = baseColor
        self.roughness = roughness
        self.metallic = metallic
        self.shading = shading
        self.alphaMode = alphaMode
        self.vertexColorMode = vertexColorMode
    }
}
