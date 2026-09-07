import Realitizer
import RealityKit

/// A code-owned model assembled from existing native meshes, independent of their file format.
/// Materials, hierarchy and behavior remain Swift values; no sidecar document is required.
@MainActor
public struct ModelResourceDefinition {
    public var name: String
    public var materials: [MaterialDefinition]
    public var parts: [ModelResourcePart]
    public var rig: RigDefinition?
    public var sockets: [SocketDefinition]
    public var collisions: [ModelCollisionDefinition]
    public var poses: [PoseDefinition]
    public var clips: [AnimationClipDefinition]
    public var animationGraph: AnimationGraphDefinition?

    public init(
        name: String, materials: [MaterialDefinition], parts: [ModelResourcePart],
        rig: RigDefinition? = nil, sockets: [SocketDefinition] = [],
        collisions: [ModelCollisionDefinition] = [], poses: [PoseDefinition] = [],
        clips: [AnimationClipDefinition] = [], animationGraph: AnimationGraphDefinition? = nil
    ) {
        self.name = name
        self.materials = materials
        self.parts = parts
        self.rig = rig
        self.sockets = sockets
        self.collisions = collisions
        self.poses = poses
        self.clips = clips
        self.animationGraph = animationGraph
    }

    /// Builds a reference pose from code-owned transforms without accessing vertex buffers.
    public var restPose: PoseDefinition {
        var transforms: [AnimationTarget: ModelTransform] = [:]
        for part in parts { transforms[.part(part.id)] = part.transform }
        for joint in rig?.joints ?? [] { transforms[.joint(joint.id)] = joint.restTransform }
        return PoseDefinition(id: AnyRealitizerID("rest"), transforms: transforms)
    }
}

/// One semantic part. The mesh is reused; entity transforms are specified in code, not inferred.
@MainActor
public struct ModelResourcePart {
    public let id: AnyRealitizerID
    public var mesh: MeshResource
    public var materialID: AnyRealitizerID
    public var additionalMaterialIDs: [AnyRealitizerID] = []
    public var transform: ModelTransform
    public var parent: HierarchyNodeReference?
    public var levelsOfDetail: [ModelResourceLevel] = []

    public init<ID: RealitizerID, MaterialID: RealitizerID>(
        id: ID, mesh: MeshResource, material: MaterialID,
        transform: ModelTransform = .identity, parent: HierarchyNodeReference? = nil
    ) {
        self.id = id.erasedID
        self.mesh = mesh
        materialID = material.erasedID
        self.transform = transform
        self.parent = parent
    }
}

/// A native replacement mesh with the same part, material-slot and deformation contracts.
@MainActor
public struct ModelResourceLevel {
    public var minimumDistance: Float
    public var mesh: MeshResource

    public init(minimumDistance: Float, mesh: MeshResource) {
        self.minimumDistance = minimumDistance
        self.mesh = mesh
    }
}

extension RealityKitModelCompiler {
    /// Reuses native meshes without rerunning modeling operations or generating MeshResources.
    /// Reads and validates CPU geometry once for existing inspection and runtime contracts.
    /// Supplied materials reuse textures/shaders; their definitions describe animation defaults.
    public static func assemble(
        _ definition: ModelResourceDefinition,
        materials suppliedMaterials: [AnyRealitizerID: any Material] = [:],
        resources: ModelRenderingResources? = nil,
        budget: GeometryBudget = GeometryBudget()
    ) throws -> CompiledModelAsset {
        guard budget.maximumVertices > 0, budget.maximumTriangles > 0 else {
            throw ModelResourceError.invalid("The geometry budget must be positive.")
        }
        let materialIDs = Set(definition.materials.map(\.id))
        guard suppliedMaterials.keys.allSatisfy({ materialIDs.contains($0) }) else {
            throw ModelResourceError.invalid("A supplied material has no matching definition.")
        }
        let expectedSkeleton = try definition.rig.map { try compileSkeleton($0) }
        var remainingVertices = budget.maximumVertices
        var remainingTriangles = budget.maximumTriangles
        var compiledParts: [CompiledPart] = []
        for part in definition.parts {
            var levels: [CompiledGeometry] = []
            for level in [ModelResourceLevel(minimumDistance: 0, mesh: part.mesh)]
                + part.levelsOfDetail
            {
                let decoded = try NativeModelGeometry.read(
                    level.mesh, skeleton: expectedSkeleton,
                    maximumVertices: remainingVertices, maximumTriangles: remainingTriangles)
                remainingVertices -= decoded.geometry.mesh.vertices.count
                remainingTriangles -= decoded.geometry.mesh.triangleCount
                levels.append(
                    CompiledGeometry(
                        definition: ModelGeometryLevel(
                            minimumDistance: level.minimumDistance, geometry: decoded.geometry),
                        mesh: level.mesh, skeleton: decoded.skeleton, cpuDeformation: false))
            }
            var portable = ModelPartDefinition(
                id: part.id, geometry: levels[0].definition.geometry, material: part.materialID,
                transform: part.transform, parent: part.parent)
            portable.additionalMaterialIDs = part.additionalMaterialIDs
            portable.levelsOfDetail = levels.dropFirst().map(\.definition)
            compiledParts.append(CompiledPart(definition: portable, levels: levels))
        }
        let portable = try ModelAssetDefinition(
            name: definition.name, materials: definition.materials,
            parts: compiledParts.map(\.definition),
            rig: definition.rig, sockets: definition.sockets, collisions: definition.collisions,
            poses: definition.poses, clips: definition.clips,
            animationGraph: definition.animationGraph
        ).validated()
        var materials: [AnyRealitizerID: any Material] = [:]
        for definition in portable.materials {
            if let supplied = suppliedMaterials[definition.id] {
                materials[definition.id] = supplied
            } else {
                materials[definition.id] = try RealityKitMaterialCompiler.compile(
                    definition, resources: resources)
            }
        }
        return CompiledModelAsset(definition: portable, parts: compiledParts, materials: materials)
    }
}

/// Unsupported or inconsistent native content is rejected rather than silently rebuilt or flattened.
public enum ModelResourceError: Error, Equatable, Sendable {
    case invalid(String)
}
