import Foundation
import simd

/// Interpretation of RGB bytes. Alpha is always linear and non-premultiplied.
public enum TextureEncoding: String, Equatable, Sendable, Codable {
    case sRGB
    case raw
}

/// RGBA8 pixels, row-major from the upper-left, with an explicit encoding.
public struct TextureImage: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    public var encoding: TextureEncoding
    public init(width: Int, height: Int, pixels: [UInt8], encoding: TextureEncoding = .sRGB) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.encoding = encoding
    }

    public func validate() throws {
        guard (1...4096).contains(width), (1...4096).contains(height), pixels.count == width * height * 4 else {
            throw modelingError(
                "texture.dimensions", "RGBA textures require dimensions in 1...4096 and four bytes per pixel.")
        }
    }

    public static func generate(width: Int = 256, height: Int = 256, sample: (SIMD2<Float>) -> RGBAColor) throws -> Self
    {
        try generateData(width: width, height: height, encoding: .sRGB) { uv in
            let color = sample(uv)
            return SIMD4(color.red, color.green, color.blue, color.alpha)
        }
    }

    /// Generates non-color channels, such as roughness or encoded normals, without gamma conversion.
    public static func generateData(
        width: Int = 256, height: Int = 256, sample: (SIMD2<Float>) -> SIMD4<Float>
    ) throws -> Self {
        try generateData(width: width, height: height, encoding: .raw, sample: sample)
    }

    private static func generateData(
        width: Int, height: Int, encoding: TextureEncoding, sample: (SIMD2<Float>) -> SIMD4<Float>
    ) throws -> Self {
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw modelingError("texture.size", "Texture dimensions must be between 1 and 4096.")
        }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = sample(SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height)))
                guard (0..<4).allSatisfy({ color[$0].isFinite }) else {
                    throw modelingError("texture.nonFinite", "Texture sample returned a non-finite color.")
                }
                pixels += (0..<4).map { color[$0] }.map {
                    UInt8((min(max($0, 0), 1) * 255).rounded())
                }
            }
        }
        return Self(width: width, height: height, pixels: pixels, encoding: encoding)
    }

    public static func checker(
        size: Int = 256, cells: Int = 8, first: RGBAColor = .white,
        second: RGBAColor = RGBAColor(red: 0.15, green: 0.15, blue: 0.15)
    ) throws -> Self {
        guard (1...4096).contains(cells) else {
            throw modelingError("texture.cells", "Checker cell count must be in 1...4096.")
        }
        return try generate(width: size, height: size) { uv in
            (Int(uv.x * Float(cells)) + Int(uv.y * Float(cells))).isMultiple(of: 2) ? first : second
        }
    }

    public static func noise(size: Int = 256, seed: UInt64, low: RGBAColor, high: RGBAColor) throws -> Self {
        var random = ModelingRandom(seed: seed)
        return try generate(width: size, height: size) { _ in
            let t = random.unit()
            return RGBAColor(
                red: low.red + (high.red - low.red) * t, green: low.green + (high.green - low.green) * t,
                blue: low.blue + (high.blue - low.blue) * t, alpha: low.alpha + (high.alpha - low.alpha) * t)
        }
    }

    /// Builds a tangent-space normal map from a scalar height function.
    public static func normalMap(size: Int = 256, strength: Float = 1, height: (SIMD2<Float>) -> Float) throws -> Self {
        guard strength.isFinite else {
            throw modelingError("texture.normalStrength", "Normal strength must be finite.")
        }
        let step = 1 / Float(max(size, 1))
        return try generateData(width: size, height: size) { uv in
            let dx = (height(uv + SIMD2(step, 0)) - height(uv - SIMD2(step, 0))) / (2 * step)
            let dy = (height(uv + SIMD2(0, step)) - height(uv - SIMD2(0, step))) / (2 * step)
            guard dx.isFinite, dy.isFinite else { return SIMD4(.nan, 0, 0, 1) }
            let normal = unitVector(SIMD3(-dx * strength, -dy * strength, 1))
            return SIMD4(normal.x * 0.5 + 0.5, normal.y * 0.5 + 0.5, normal.z * 0.5 + 0.5, 1)
        }
    }
}
