import Foundation
import Realitizer
import RealityKit
import simd

/// Converts portable geometry, skin bindings and materials into reusable rendering resources.
@MainActor
public enum RealityKitModelCompiler {
    public static func compile(_ definition: ModelAssetDefinition, resources: ModelRenderingResources? = nil) throws -> CompiledModelAsset {
        let validated = try definition.validated()
        let skeleton = try validated.rig.map { try compileSkeleton($0) }
        let parts = try validated.parts.map { part in
            let levels =
                [
                    ModelGeometryLevel(
                        minimumDistance: 0, geometry: part.geometry)
                ] + part.levelsOfDetail
            return try CompiledPart(
                definition: part,
                levels: levels.map {
                    try compileGeometry($0, name: part.id.rawValue, rig: validated.rig, skeleton: skeleton)
                })
        }
        var materials: [AnyRealitizerID: any Material] = [:]
        for material in validated.materials {
            materials[material.id] = try RealityKitMaterialCompiler.compile(material, resources: resources)
        }
        return CompiledModelAsset(definition: validated, parts: parts, materials: materials)
    }

    static func compileSkeleton(_ rig: RigDefinition) throws -> MeshResource.Skeleton {
        let resolved = try rig.resolvedSkeleton()
        return MeshResource.Skeleton(
            id: rig.id.rawValue,
            joints: resolved.joints.indices.map { i in
                MeshResource.Skeleton.Joint(
                    name: resolved.joints[i].id.rawValue, parentIndex: resolved.parentIndices[i],
                    inverseBindPoseMatrix: resolved.inverseBindMatrices[i],
                    restPoseTransform: Transform(resolved.joints[i].restTransform))
            })
    }

    package static func compileMesh(_ mesh: MeshData) throws -> MeshResource {
        try compileGeometry(
            ModelGeometryLevel(minimumDistance: 0, mesh: mesh), name: "environment", rig: nil,
            skeleton: nil
        ).mesh
    }

    static func compileGeometry(
        _ level: ModelGeometryLevel, name: String, rig: RigDefinition?, skeleton: MeshResource.Skeleton?
    ) throws -> CompiledGeometry {
        let data = level.geometry.mesh
        // Explicit normal deltas use the dynamic CPU reference path; native morph offsets are position-only.
        let cpuDeformation = level.geometry.morphTargets.contains { !$0.normalDeltas.isEmpty }
        let resolved = try rig?.resolvedSkeleton()
        let jointIndices = Dictionary(
            uniqueKeysWithValues: (resolved?.joints ?? []).enumerated().map { ($0.element.id, $0.offset) }
        )
        let materialSlots =
            data.materialIndices.isEmpty ? [UInt32(0)] : Set(data.materialIndices).sorted()
        var meshParts: [MeshResource.Part] = []
        for slot in materialSlots {
            var part = MeshResource.Part(id: "\(name)-material-\(slot)", materialIndex: Int(slot))
            part.positions = MeshBuffers.Positions(data.vertices.map(\.position))
            part.normals = MeshBuffers.Normals(data.vertices.map(\.normal))
            part.textureCoordinates = MeshBuffers.TextureCoordinates(
                data.vertices.map(\.textureCoordinate))
            part[try NativeVertexColor.semantic()] = MeshBuffer(data.vertices.map { $0.color.linearRGBA })
            let tangents = data.vertices.map { SIMD3($0.tangent.x, $0.tangent.y, $0.tangent.z) }
            part.tangents = MeshBuffers.Tangents(tangents)
            part.bitangents = MeshBuffers.Tangents(
                zip(data.vertices, tangents).map { simd_cross($0.0.normal, $0.1) * $0.0.tangent.w })
            var indices: [UInt32] = []
            for i in 0..<data.triangleCount
            where data.materialIndices.isEmpty || data.materialIndices[i] == slot {
                indices += data.indices[(i * 3)..<(i * 3 + 3)]
            }
            part.triangleIndices = MeshBuffers.TriangleIndices(indices)
            if !cpuDeformation {
                if let skin = level.geometry.skin, let skeleton {
                    var influences: [MeshJointInfluence] = []
                    for vertex in skin.influences {
                        for influence in vertex {
                            guard let index = jointIndices[influence.jointID] else {
                                throw RealityKitCompilationError.missingJoint(influence.jointID)
                            }
                            influences.append(MeshJointInfluence(jointIndex: index, weight: influence.weight))
                        }
                        influences += Array(
                            repeating: MeshJointInfluence(jointIndex: 0, weight: 0),
                            count: skin.maximumInfluences - vertex.count)
                    }
                    part.skeletonID = skeleton.id
                    part.jointInfluences = MeshResource.JointInfluences(
                        influences: MeshBuffers.JointInfluences(influences),
                        influencesPerVertex: skin.maximumInfluences
                    )
                }
                for morph in level.geometry.morphTargets {
                    part.setBlendShapeOffsets(
                        named: morph.id.rawValue, buffer: MeshBuffers.BlendShapeOffsets(morph.positionDeltas))
                }
            }
            meshParts.append(part)
        }
        var contents = MeshResource.Contents()
        contents.models = [MeshResource.Model(id: name, parts: meshParts)]
        contents.instances = [MeshResource.Instance(id: name, model: name)]
        if level.geometry.skin != nil, !cpuDeformation, let skeleton { contents.skeletons = [skeleton] }
        return try CompiledGeometry(
            definition: level, mesh: MeshResource.generate(from: contents),
            skeleton: level.geometry.skin != nil && !cpuDeformation ? skeleton : nil,
            cpuDeformation: cpuDeformation)
    }
}

@MainActor
public final class CompiledModelAsset {
    public let definition: ModelAssetDefinition
    let parts: [CompiledPart]
    let materials: [AnyRealitizerID: any Material]

    init(
        definition: ModelAssetDefinition, parts: [CompiledPart],
        materials: [AnyRealitizerID: any Material]
    ) {
        self.definition = definition
        self.parts = parts
        self.materials = materials
    }

    public func instantiate() throws -> RuntimeModelInstance {
        let root = Entity()
        root.name = definition.name
        var joints: [AnyRealitizerID: Entity] = [:]
        for joint in definition.rig?.joints ?? [] {
            let entity = Entity()
            entity.name = "joint:\(joint.id.rawValue)"
            entity.transform = Transform(joint.restTransform)
            joints[joint.id] = entity
        }
        var partEntities: [AnyRealitizerID: Entity] = [:]
        var models: [AnyRealitizerID: ModelEntity] = [:]
        for part in parts {
            let anchor = Entity()
            anchor.name = "part:\(part.definition.id.rawValue)"
            anchor.transform = Transform(part.definition.transform)
            let slots = [part.definition.materialID] + part.definition.additionalMaterialIDs
            let model = ModelEntity(
                mesh: part.levels[0].mesh,
                materials: try slots.map { id in
                    guard let material = materials[id] else {
                        throw RealityKitCompilationError.missingMaterial(id)
                    }
                    return material
                })
            model.name = "mesh:\(part.definition.id.rawValue)"
            configureDeformation(model, geometry: part.levels[0])
            anchor.addChild(model)
            partEntities[part.definition.id] = anchor
            models[part.definition.id] = model
        }
        func node(_ reference: HierarchyNodeReference) throws -> Entity {
            switch reference {
            case .part(let id):
                guard let entity = partEntities[id] else {
                    throw RealityKitCompilationError.missingPart(id)
                }
                return entity
            case .joint(let id):
                guard let entity = joints[id] else { throw RealityKitCompilationError.missingJoint(id) }
                return entity
            }
        }
        for joint in definition.rig?.joints ?? [] {
            if let entity = joints[joint.id] {
                (joint.parentID.flatMap { joints[$0] } ?? root).addChild(entity)
            }
        }
        for part in parts {
            if let entity = partEntities[part.definition.id] {
                try (part.definition.parent.map(node) ?? root).addChild(entity)
            }
        }
        var sockets: [AnyRealitizerID: Entity] = [:]
        for socket in definition.sockets {
            let entity = Entity()
            entity.name = "socket:\(socket.id.rawValue)"
            entity.transform = Transform(socket.transform)
            try node(socket.parent).addChild(entity)
            sockets[socket.id] = entity
        }
        var collisions: [AnyRealitizerID: Entity] = [:]
        for collision in definition.collisions {
            let entity = Entity()
            entity.name = "collision:\(collision.id.rawValue)"
            entity.transform = Transform(collision.transform)
            let shape: ShapeResource
            switch collision.shape {
            case .box(let size): shape = .generateBox(size: size)
            case .sphere(let radius): shape = .generateSphere(radius: radius)
            case .capsule(let height, let radius):
                shape = .generateCapsule(height: height, radius: radius)
            case .convex(let points): shape = .generateConvex(from: points)
            }
            let owner = try collision.physics == nil ? entity : node(collision.parent)
            let localShape =
                collision.physics == nil
                ? shape
                : shape.offsetBy(
                    rotation: collision.transform.rotation, translation: collision.transform.translation)
            owner.components.set(
                CollisionComponent(
                    shapes: [localShape], mode: collision.isTrigger ? .trigger : .default,
                    filter: CollisionFilter(
                        group: CollisionGroup(rawValue: collision.group),
                        mask: CollisionGroup(rawValue: collision.mask)
                    )))
            if collision.acceptsInput { owner.components.set(InputTargetComponent()) }
            if let physics = collision.physics {
                let mode: PhysicsBodyMode
                switch physics.mode {
                case .static: mode = .static
                case .kinematic: mode = .kinematic
                case .dynamic: mode = .dynamic
                }
                let material = PhysicsMaterialResource.generate(
                    friction: physics.friction, restitution: physics.restitution)
                owner.components.set(
                    PhysicsBodyComponent(
                        shapes: [localShape], mass: physics.mass, material: material, mode: mode))
                owner.components.set(PhysicsMotionComponent())
            }
            try node(collision.parent).addChild(entity)
            collisions[collision.id] = owner
        }
        let instance = RuntimeModelInstance(
            compiled: self, root: root, parts: partEntities, models: models, joints: joints,
            sockets: sockets,
            collisions: collisions)
        try instance.refreshDeformations()
        return instance
    }
}

@MainActor
struct CompiledPart {
    let definition: ModelPartDefinition
    let levels: [CompiledGeometry]
}
@MainActor
struct CompiledGeometry {
    let definition: ModelGeometryLevel
    let mesh: MeshResource
    let skeleton: MeshResource.Skeleton?
    let cpuDeformation: Bool
}

@MainActor
func configureDeformation(_ entity: ModelEntity, geometry: CompiledGeometry) {
    entity.components.remove(SkeletalPosesComponent.self)
    entity.components.remove(BlendShapeWeightsComponent.self)
    if let skeleton = geometry.skeleton {
        entity.components.set(
            SkeletalPosesComponent(poses: [SkeletalPose(id: skeleton.id, from: skeleton)]))
    }
    if !geometry.cpuDeformation, !geometry.definition.geometry.morphTargets.isEmpty {
        entity.components.set(
            BlendShapeWeightsComponent(
                weightsMapping: BlendShapeWeightsMapping(
                    blendShapeName: "morphs",
                    weightNames: geometry.definition.geometry.morphTargets.map { $0.id.rawValue })))
    }
}

extension Transform {
    init(_ transform: ModelTransform) {
        self.init(
            scale: transform.scale, rotation: transform.rotation, translation: transform.translation)
    }
    var portable: ModelTransform {
        ModelTransform(scale: scale, rotation: rotation, translation: translation)
    }
}

public enum RealityKitCompilationError: Error, Equatable, Sendable {
    case missingMaterial(AnyRealitizerID)
    case missingPart(AnyRealitizerID)
    case missingJoint(AnyRealitizerID)
    case invalidTexture
}
