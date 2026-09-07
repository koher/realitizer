import Foundation
import simd

/// A geometry replacement that preserves its owning part, rig, sockets and runtime handles.
public struct ModelGeometryLevel: Sendable {
    public var minimumDistance: Float
    public var geometry: ModelGeometry
    public init(minimumDistance: Float, geometry: ModelGeometry) {
        self.minimumDistance = minimumDistance
        self.geometry = geometry
    }
    public init(minimumDistance: Float, mesh: MeshData) {
        self.init(minimumDistance: minimumDistance, geometry: ModelGeometry(mesh: mesh))
    }
}

public struct ModelStatistics: Equatable, Sendable, Codable {
    public let vertices: Int
    public let triangles: Int
    public let parts: Int
    public let joints: Int
    public let materials: Int
    public let collisions: Int
    public let estimatedVertexBytes: Int
}

public struct GeometryBudget: Equatable, Sendable, Codable {
    public var maximumVertices: Int
    public var maximumTriangles: Int
    public var maximumOperations: Int
    public var maximumDepth: Int
    public init(
        maximumVertices: Int = 500_000, maximumTriangles: Int = 500_000, maximumOperations: Int = 1024,
        maximumDepth: Int = 32
    ) {
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
        self.maximumOperations = maximumOperations
        self.maximumDepth = maximumDepth
    }
    public func validate(_ mesh: MeshData) throws {
        guard mesh.vertices.count <= maximumVertices, mesh.triangleCount <= maximumTriangles else {
            throw modelingError(
                "budget.geometry", "Geometry exceeds the configured vertex or triangle budget.")
        }
    }
}

public struct ModelQualityProfile: Equatable, Sendable, Codable {
    public var curveSegments: Int
    public var surfaceSegments: Int
    public var budget: GeometryBudget
    public init(
        curveSegments: Int = 24, surfaceSegments: Int = 16, budget: GeometryBudget = GeometryBudget()
    ) {
        self.curveSegments = curveSegments
        self.surfaceSegments = surfaceSegments
        self.budget = budget
    }
}

/// Art direction is a reusable input, independent of mesh resolution or game state.
public struct ArtStyleProfile: Sendable {
    public var materials: [MaterialDefinition]
    public var normalSmoothingAngle: Float
    public init(materials: [MaterialDefinition], normalSmoothingAngle: Float = .pi / 3) {
        self.materials = materials
        self.normalSmoothingAngle = normalSmoothingAngle
    }
    public func applying(to asset: ModelAssetDefinition) throws -> ModelAssetDefinition {
        var result = asset
        for material in materials {
            if let index = result.materials.firstIndex(where: { $0.id == material.id }) {
                result.materials[index] = material
            }
        }
        for i in result.parts.indices {
            result.parts[i].geometry = try result.parts[i].geometry.recalculatingNormals(
                smoothingAngle: normalSmoothingAngle)
            for j in result.parts[i].levelsOfDetail.indices {
                result.parts[i].levelsOfDetail[j].geometry = try result.parts[i].levelsOfDetail[j].geometry
                    .recalculatingNormals(smoothingAngle: normalSmoothingAngle)
            }
        }
        return try result.validated()
    }
}

extension ModelAssetDefinition {
    public var referenceScalarValues: [ScalarAnimationTarget: Float] {
        var values: [ScalarAnimationTarget: Float] = [:]
        for part in parts {
            for morph in part.geometry.morphTargets {
                values[.morph(part: part.id, target: morph.id)] = 0
            }
        }
        for material in materials {
            if material.alphaMode != .opaque {
                values[.material(material.id, .opacity)] = material.baseColor.alpha
            }
            if material.shading == .lit {
                values[.material(material.id, .roughness)] = material.roughness
                values[.material(material.id, .metallic)] = material.metallic
                values[.material(material.id, .emissiveIntensity)] = material.emissiveIntensity
            }
        }
        return values
    }

    public func globalTransform(of node: HierarchyNodeReference, pose: PoseDefinition? = nil) throws
        -> simd_float4x4
    {
        var visited: Set<HierarchyNodeReference> = []
        func resolve(_ node: HierarchyNodeReference) throws -> simd_float4x4 {
            guard visited.insert(node).inserted else {
                throw modelingError("hierarchy.cycle", "Hierarchy contains a cycle.")
            }
            switch node {
            case .part(let id):
                guard let part = parts.first(where: { $0.id == id }) else {
                    throw modelingError("hierarchy.part", "Part does not exist.")
                }
                let local = (pose?.transforms[.part(id)] ?? part.transform).matrix
                return try part.parent.map { try resolve($0) * local } ?? local
            case .joint(let id):
                guard let joint = rig?.joints.first(where: { $0.id == id }) else {
                    throw modelingError("hierarchy.joint", "Joint does not exist.")
                }
                let local = (pose?.transforms[.joint(id)] ?? joint.restTransform).matrix
                return try joint.parentID.map { try resolve(.joint($0)) * local } ?? local
            }
        }
        return try resolve(node)
    }

    public var restPose: PoseDefinition {
        var transforms: [AnimationTarget: ModelTransform] = [:]
        for part in parts { transforms[.part(part.id)] = part.transform }
        for joint in rig?.joints ?? [] { transforms[.joint(joint.id)] = joint.restTransform }
        return PoseDefinition(id: AnyRealitizerID(rawValue: "rest"), transforms: transforms)
    }

    public var statistics: ModelStatistics {
        let vertices = parts.reduce(0) { $0 + $1.geometry.mesh.vertices.count }
        return ModelStatistics(
            vertices: vertices, triangles: parts.reduce(0) { $0 + $1.geometry.mesh.triangleCount },
            parts: parts.count,
            joints: rig?.joints.count ?? 0, materials: materials.count, collisions: collisions.count,
            estimatedVertexBytes: vertices * MemoryLayout<MeshVertex>.stride)
    }

    func extendedValidationDiagnostics() -> [ModelDiagnostic] {
        var diagnostics: [ModelDiagnostic] = []
        func check(_ path: String, _ body: () throws -> Void) {
            do { try body() } catch let error as ModelValidationError {
                diagnostics += error.diagnostics.map {
                    ModelDiagnostic(
                        severity: $0.severity, code: $0.code, path: "\(path).\($0.path)", message: $0.message)
                }
            } catch {
                diagnostics.append(.error("asset.validation", path: path, String(describing: error)))
            }
        }
        if let rig { check("rig") { _ = try rig.resolvedSkeleton() } }
        let materialIDs = Set(materials.map(\.id))
        for (i, part) in parts.enumerated() {
            check("parts[\(i)]") {
                let slots = [part.materialID] + part.additionalMaterialIDs
                guard slots.allSatisfy({ materialIDs.contains($0) }) else {
                    throw modelingError(
                        "material.missingSlot", "Every material slot must reference a declared material.")
                }
                let levels =
                    [
                        ModelGeometryLevel(
                            minimumDistance: 0, geometry: part.geometry)
                    ] + part.levelsOfDetail
                var previous: Float = -1
                for level in levels {
                    guard (level.geometry.skin == nil) == (part.geometry.skin == nil),
                        Set(level.geometry.morphTargets.map(\.id)) == Set(part.geometry.morphTargets.map(\.id))
                    else {
                        throw modelingError(
                            "lod.deformationContract",
                            "Every LOD must preserve skin presence and semantic morph target identifiers.")
                    }
                    guard level.minimumDistance.isFinite, level.minimumDistance > previous else {
                        throw modelingError(
                            "lod.distances", "LOD distances must be finite and strictly increasing.")
                    }
                    previous = level.minimumDistance
                    _ = try level.geometry.mesh.validated()
                    guard level.geometry.mesh.materialIndices.allSatisfy({ Int($0) < slots.count }) else {
                        throw modelingError(
                            "mesh.materialSlot", "A triangle references an unknown material slot.")
                    }
                    if let skin = level.geometry.skin {
                        guard let rig else {
                            throw modelingError("skin.missingRig", "Skinned parts require a rig.")
                        }
                        guard part.parent == nil, part.transform == .identity else {
                            throw modelingError(
                                "skin.coordinateSpace",
                                "Skinned geometry must be authored in rig space with an identity root part transform."
                            )
                        }
                        try skin.validate(vertexCount: level.geometry.mesh.vertices.count, rig: rig)
                    }
                    guard
                        Set(level.geometry.morphTargets.map(\.id)).count == level.geometry.morphTargets.count
                    else {
                        throw modelingError("morph.duplicate", "Morph target identifiers must be unique.")
                    }
                    for target in level.geometry.morphTargets {
                        try target.validate(vertexCount: level.geometry.mesh.vertices.count)
                    }
                }
            }
        }
        return diagnostics + authoringValidationDiagnostics()
    }
}
