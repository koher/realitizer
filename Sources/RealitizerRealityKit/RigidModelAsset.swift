import Foundation
import Realitizer
import RealityKit
import simd

extension RealityKitModelCompiler {
    /// Assembles finished rigid resources without reading vertex or index arrays.
    /// Validate geometry during baking. Use `inspect()` for explicit CPU inspection.
    /// Supports static meshes, rigid joints, transform clips, sockets and authored LODs.
    public static func assembleRigid(
        _ definition: ModelResourceDefinition,
        materials suppliedMaterials: [AnyRealitizerID: any Material] = [:],
        resources: ModelRenderingResources? = nil,
        budget: GeometryBudget = GeometryBudget()
    ) throws -> RigidModelAsset {
        try RigidModelAsset.validate(definition, suppliedMaterials: suppliedMaterials, budget: budget)
        var materials = suppliedMaterials
        for material in definition.materials where materials[material.id] == nil {
            materials[material.id] = try RealityKitMaterialCompiler.compile(material, resources: resources)
        }
        return RigidModelAsset(definition: definition, materials: materials, budget: budget)
    }
}

/// Shared native meshes and small code-owned metadata. No portable geometry is cached.
@MainActor
public final class RigidModelAsset {
    public let definition: ModelResourceDefinition
    let materials: [AnyRealitizerID: any Material]
    private let budget: GeometryBudget

    init(definition: ModelResourceDefinition, materials: [AnyRealitizerID: any Material], budget: GeometryBudget) {
        self.definition = definition
        self.materials = materials
        self.budget = budget
    }

    public func instantiate() throws -> RigidModelInstance {
        try RigidModelInstance(asset: self)
    }

    /// Explicitly reads and validates CPU geometry for inspection, export comparison or previews.
    /// The resulting compiled asset shares the same native meshes and materials.
    public func inspect() throws -> CompiledModelAsset {
        try RealityKitModelCompiler.assemble(definition, materials: materials, budget: budget)
    }

    static func validate(
        _ definition: ModelResourceDefinition,
        suppliedMaterials: [AnyRealitizerID: any Material], budget: GeometryBudget
    ) throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw ModelResourceError.invalid(message) }
        }
        func unique(_ ids: [AnyRealitizerID]) -> Bool {
            Set(ids).count == ids.count && ids.allSatisfy { !$0.rawValue.isEmpty }
        }
        try require(!definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Rigid assets require a name.")
        try require(budget.maximumVertices > 0 && budget.maximumTriangles > 0, "The geometry budget must be positive.")
        try require(definition.collisions.isEmpty && definition.animationGraph == nil
                    && (definition.rig?.constraints.isEmpty ?? true),
                    "Rigid resources do not support physics, constraints or animation graphs; use full assembly.")
        let materialIDs = Set(definition.materials.map(\.id))
        let joints = definition.rig?.joints ?? []
        try require(unique(definition.materials.map(\.id)) && unique(definition.parts.map(\.id))
                    && unique(joints.map(\.id)) && unique(definition.sockets.map(\.id))
                    && unique(definition.poses.map(\.id)) && unique(definition.clips.map(\.id)),
                    "Semantic IDs must be nonempty and unique within each collection.")
        try require(suppliedMaterials.keys.allSatisfy { materialIDs.contains($0) },
                    "A supplied material has no matching definition.")
        for material in definition.materials { try material.validate() }
        _ = try definition.rig?.resolvedSkeleton()

        var parents: [HierarchyNodeReference: HierarchyNodeReference] = [:]
        let nodes = Set(definition.parts.map { HierarchyNodeReference.part($0.id) }
                        + joints.map { HierarchyNodeReference.joint($0.id) })
        for joint in joints {
            try joint.restTransform.validate()
            if let parent = joint.parentID { parents[.joint(joint.id)] = .joint(parent) }
        }
        var vertices = 0, triangles = 0
        for part in definition.parts {
            try part.transform.validate()
            if let parent = part.parent { parents[.part(part.id)] = parent }
            let slots = [part.materialID] + part.additionalMaterialIDs
            try require(slots.allSatisfy { materialIDs.contains($0) }, "A part references an unknown material.")
            var previous: Float = 0
            for level in part.levelsOfDetail {
                try require(level.minimumDistance.isFinite && level.minimumDistance > previous,
                            "LOD distances must be finite, positive and strictly increasing.")
                previous = level.minimumDistance
            }
            for mesh in [part.mesh] + part.levelsOfDetail.map(\.mesh) {
                // Inspect layout and counts only. MeshBuffer.elements is intentionally never accessed.
                let contents = mesh.contents
                try require(contents.models.count == 1 && contents.instances.count == 1 && contents.skeletons.isEmpty,
                            "Rigid resources require one model and one mesh instance without skin or morphs.")
                let model = contents.models.first!, instance = contents.instances.first!
                try require(instance.model == model.id && instance.transform == matrix_identity_float4x4
                            && !model.parts.isEmpty, "Mesh instances must have identity transforms and nonempty parts.")
                for native in model.parts {
                    let count = native.positions.count, indexCount = native.triangleIndices?.count ?? 0
                    try require(count > 0 && indexCount > 0 && indexCount.isMultiple(of: 3)
                                && native.materialIndex >= 0 && native.materialIndex < slots.count,
                                "Rigid meshes require triangles and valid material slots.")
                    try require(native.jointInfluences == nil && native.skeletonID == nil && native.blendShapeNames.isEmpty,
                                "Skin and morphs require full assembly.")
                    if let colors = native[try NativeVertexColor.semantic()] {
                        try require(colors.rate == .vertex && colors.count == count,
                                    "Vertex colors must have vertex rate and match position counts.")
                    }
                    try require(native.positions.rate == .vertex && native.normals?.rate == .vertex
                                && native.tangents?.rate == .vertex && native.bitangents?.rate == .vertex
                                && native.textureCoordinates?.rate == .vertex && native.normals?.count == count
                                && native.tangents?.count == count && native.bitangents?.count == count
                                && native.textureCoordinates?.count == count,
                                "Finish normals, tangents, bitangents and UVs before using rigid resources.")
                    try require(count <= budget.maximumVertices - vertices
                                && indexCount / 3 <= budget.maximumTriangles - triangles,
                                "Rigid resources exceed the aggregate geometry budget, including all LODs.")
                    vertices += count
                    triangles += indexCount / 3
                }
            }
        }
        for node in nodes {
            var visited: Set<HierarchyNodeReference> = [], current: HierarchyNodeReference? = node
            while let value = current {
                try require(nodes.contains(value) && visited.insert(value).inserted,
                            "Hierarchy parents must exist and cannot form cycles.")
                current = parents[value]
            }
        }
        for socket in definition.sockets {
            try require(nodes.contains(socket.parent), "A socket references an unknown parent.")
            try socket.transform.validate()
        }
        let targets = Set(definition.restPose.transforms.keys)
        for pose in definition.poses {
            try require(pose.transforms.keys.allSatisfy { targets.contains($0) }, "A pose references an unknown target.")
            for transform in pose.transforms.values { try transform.validate() }
        }
        for clip in definition.clips {
            try clip.validate()
            if let signature = clip.rigSignature {
                try require(signature == definition.rig?.signature, "A clip has an incompatible rig signature.")
            }
            try require(clip.scalarChannels.isEmpty && clip.events.isEmpty && clip.rootMotionTarget == nil,
                        "Rigid clips support local transform channels; scalar channels, events and root motion require full assembly.")
            try require(clip.channels.allSatisfy { targets.contains($0.target) }, "A clip references an unknown target.")
        }
    }
}
