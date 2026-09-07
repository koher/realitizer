import CoreGraphics
import Foundation
import Realitizer
import RealityKit

#if canImport(AppKit)
    import AppKit
    package typealias RealitizerPlatformColor = NSColor
#else
    import UIKit
    package typealias RealitizerPlatformColor = UIColor
#endif

@MainActor
public enum RealityKitMaterialCompiler {
    public static func compile(_ definition: MaterialDefinition, resources: ModelRenderingResources? = nil) throws -> any Material {
        try definition.validate()
        let texture = try definition.baseColorTexture.map { try makeTexture($0, semantic: .color) }
        var opaqueTint = definition.baseColor
        opaqueTint.alpha = 1
        switch definition.shading {
        case .lit:
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color(opaqueTint), texture: texture.map { .init($0) })
            material.roughness = .init(floatLiteral: definition.roughness)
            material.metallic = .init(floatLiteral: definition.metallic)
            if let image = definition.roughnessTexture {
                material.roughness.texture = .init(try makeTexture(image, semantic: .raw))
            }
            if let image = definition.metallicTexture {
                material.metallic.texture = .init(try makeTexture(image, semantic: .raw))
            }
            if let image = definition.normalTexture {
                material.normal.texture = .init(try makeTexture(image, semantic: .normal))
            }
            material.emissiveColor = .init(color: color(definition.emissiveColor))
            if let image = definition.emissiveTexture {
                material.emissiveColor.texture = .init(try makeTexture(image, semantic: .color))
            }
            material.emissiveIntensity = definition.emissiveIntensity
            material.faceCulling = definition.doubleSided ? .none : .back
            switch definition.alphaMode {
            case .opaque: material.blending = .opaque
            case .blend:
                material.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
            case .mask(let cutoff):
                material.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
                material.opacityThreshold = cutoff
            }
            return try applyingVertexColor(to: material, definition: definition, resources: resources)
        case .unlit:
            var material = UnlitMaterial(
                color: color(opaqueTint), applyPostProcessToneMap: definition.unlitToneMapping)
            material.color.texture = texture.map { .init($0) }
            material.faceCulling = definition.doubleSided ? .none : .back
            switch definition.alphaMode {
            case .opaque: material.blending = .opaque
            case .blend:
                material.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
            case .mask(let cutoff):
                material.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
                material.opacityThreshold = cutoff
            }
            return try applyingVertexColor(to: material, definition: definition, resources: resources)
        }
    }

    /// Restores library vertex-color shading on a native material loaded from an archive.
    /// The native material must match the definition, including texture presence and shading.
    /// Existing textures are retained; emission tint and alpha controls follow the definition.
    /// An emissive texture in the definition is compiled to preserve unlit emission behavior.
    /// Definitions using `.ignore` return the supplied material unchanged.
    public static func applyingVertexColor(to material: any Material, definition: MaterialDefinition,
                                          resources: ModelRenderingResources? = nil) throws -> any Material {
        try definition.validate()
        guard definition.vertexColorMode == .multiply else { return material }
        let resources = try resources ?? ModelRenderingResources.shared()
        let name = definition.shading == .lit ? "realitizer_vertex_color_lit" : "realitizer_vertex_color_unlit"
        var result = try CustomMaterial(from: material, surfaceShader: .init(named: name, in: resources.library))
        let flags = (definition.baseColorTexture == nil ? 0 : 1)
            | (definition.normalTexture == nil ? 0 : 2)
            | (definition.roughnessTexture == nil ? 0 : 4)
            | (definition.metallicTexture == nil ? 0 : 8)
            | (definition.emissiveTexture == nil ? 0 : 16)
        // Emission strength is independent of the base color, including vertex color.
        result.emissiveColor = .init(color: color(definition.emissiveColor))
        if let image = definition.emissiveTexture {
            result.emissiveColor.texture = .init(try makeTexture(image, semantic: .color))
        }
        result.custom.value = SIMD4(Float(flags), definition.emissiveIntensity,
                                    definition.alphaMode == .opaque ? 0 : 1, -1)
        switch definition.alphaMode {
        case .opaque: result.blending = .opaque
        case .blend: result.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
        case .mask(let cutoff):
            result.blending = .transparent(opacity: .init(floatLiteral: definition.baseColor.alpha))
            result.opacityThreshold = cutoff
            result.custom.value.w = cutoff
        }
        return result
    }

    static func makeTexture(_ image: TextureImage, semantic: TextureResource.Semantic) throws
        -> TextureResource
    {
        try image.validate()
        let colorSpace = CGColorSpace(
            name: image.encoding == .sRGB ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
            let cgImage = CGImage(
                width: image.width, height: image.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else {
            throw RealityKitCompilationError.invalidTexture
        }
        return try TextureResource(image: cgImage, options: .init(semantic: semantic))
    }

    package static func color(_ color: RGBAColor) -> RealitizerPlatformColor {
        #if canImport(AppKit)
            return NSColor(
                srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha))
        #else
            RealitizerPlatformColor(
                red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
        #endif
    }
}
