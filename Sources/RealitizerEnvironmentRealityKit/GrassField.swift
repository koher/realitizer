import Foundation
import Metal
import Realitizer
import RealitizerEnvironment
import RealitizerRealityKit
import RealityKit
import simd

public enum GrassFieldError: Error, Equatable, Sendable {
    case invalidUpdate
}

/// Counts submitted by the field, not measured GPU draw calls or visible pixels.
public struct GrassFieldStatistics: Equatable, Sendable {
    public var activeChunks = 0
    public var activeBlades = 0
    public var activeTriangles = 0
}

/// Texture-free opaque grass with GPU wind, chunk culling and cached geometry LODs.
/// Add `root` to a scene and call `update` with explicit game time (pauses are respected).
/// This lightweight lighting path intentionally does not receive scene lights or shadows.
@MainActor
public final class GrassField {
    public let root = Entity()
    public let definition: GrassFieldDefinition
    public let wind: GrassWind
    public let detail: GrassDetail
    public private(set) var statistics = GrassFieldStatistics()
    private var material: CustomMaterial
    private var chunks: [Chunk] = []
    /// Reuse explicitly prepared resources, or use the shared bundled library.
    public init(_ definition: GrassFieldDefinition, wind: GrassWind, detail: GrassDetail,
                appearance: GrassAppearance, resources: EnvironmentResources? = nil) throws {
        let resolvedLibrary = try (resources ?? EnvironmentResources.shared()).library
        guard resolvedLibrary.functionNames.contains("realitizer_grass_geometry"),
              resolvedLibrary.functionNames.contains("realitizer_grass_surface") else {
            throw EnvironmentResourceError.missingFunction("realitizer_grass")
        }
        var material = try CustomMaterial(
            surfaceShader: .init(named: "realitizer_grass_surface", in: resolvedLibrary),
            geometryModifier: .init(named: "realitizer_grass_geometry", in: resolvedLibrary), lightingModel: .unlit)
        material.faceCulling = .none
        material.blending = .opaque
        material.baseColor = .init(tint: RealityKitMaterialCompiler.color(appearance.rootColor))
        material.emissiveColor = .init(color: RealityKitMaterialCompiler.color(appearance.tipColor))
        // These unused unlit/PBR fields transport our private shader constants.
        material.roughness = .init(floatLiteral: appearance.ambient)
        material.metallic = .init(floatLiteral: appearance.sunDirection.x * 0.5 + 0.5)
        material.specular = .init(floatLiteral: appearance.sunDirection.y * 0.5 + 0.5)
        material.clearcoat = .init(floatLiteral: appearance.sunDirection.z * 0.5 + 0.5)
        material.clearcoatRoughness = .init(floatLiteral: appearance.transmission)
        self.material = material
        self.definition = definition
        self.wind = wind
        self.detail = detail
        root.name = "grass-field"
        for chunk in definition.chunks() {
            let near = try chunk.mesh()
            let far = try chunk.mesh(far: true, densityStride: detail.farDensityStride)
            func compile(_ mesh: MeshData) throws -> MeshResource {
                try RealityKitModelCompiler.compileMesh(mesh)
            }
            let nearResource = try compile(near), farResource = try compile(far)
            let entity = ModelEntity(mesh: nearResource, materials: [material])
            entity.name = "grass-chunk-\(chunk.coordinate.x)-\(chunk.coordinate.y)"
            entity.model?.boundsMargin = wind.boundsMargin
            entity.components.set(DynamicLightShadowComponent(castsShadow: false))
            entity.isEnabled = false
            root.addChild(entity)
            chunks.append(Chunk(entity: entity, near: nearResource, far: farResource, bounds: near.bounds!,
                                nearCount: chunk.blades.count, farCount: far.vertices.count / 3))
        }
    }

    /// Camera coordinates must be relative to `root`; use root.convert(position:from:)
    /// when the field is transformed. Meshes and topology remain unchanged during updates.
    public func update(time: Float, cameraPosition: SIMD3<Float>) throws {
        guard time.isFinite, abs(time) <= 1_000_000,
            cameraPosition.x.isFinite, cameraPosition.y.isFinite, cameraPosition.z.isFinite,
            simd_length(cameraPosition).isFinite else { throw GrassFieldError.invalidUpdate }
        material.custom.value = [time * wind.speed, wind.direction.x * wind.strength, wind.direction.y * wind.strength, 0]
        var stats = GrassFieldStatistics()
        for index in chunks.indices {
            var chunk = chunks[index]
            let nearest = simd_clamp(cameraPosition, chunk.bounds.minimum, chunk.bounds.maximum)
            let distance = max(0, simd_distance(cameraPosition, nearest) - wind.boundsMargin)
            let state = Self.level(distance: distance, previous: chunk.level, detail: detail)
            chunk.entity.isEnabled = state != .hidden
            if state != .hidden {
                let isNear = state == .near
                if chunk.level != state {
                    chunk.entity.model?.mesh = isNear ? chunk.near : chunk.far
                }
                chunk.entity.model?.materials = [material]
                stats.activeChunks += 1
                stats.activeBlades += isNear ? chunk.nearCount : chunk.farCount
                stats.activeTriangles += isNear ? chunk.nearCount * 3 : chunk.farCount
            }
            chunk.level = state
            chunks[index] = chunk
        }
        statistics = stats
    }

    enum Level { case near, far, hidden }
    static func level(distance: Float, previous: Level, detail: GrassDetail) -> Level {
        let farThreshold = detail.farDistance + (previous == .hidden ? 0 : detail.hysteresis)
        if distance > farThreshold { return .hidden }
        let nearThreshold = detail.nearDistance + (previous == .near ? detail.hysteresis : 0)
        return distance <= nearThreshold ? .near : .far
    }

    private struct Chunk {
        let entity: ModelEntity
        let near: MeshResource
        let far: MeshResource
        let bounds: MeshBounds
        let nearCount: Int
        let farCount: Int
        var level = Level.hidden
    }
}
