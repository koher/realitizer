import Realitizer
import RealityKit

/// Independent transforms and LOD selection backed by a shared, finished rigid asset.
@MainActor
public final class RigidModelInstance {
    public let root: Entity
    public let asset: RigidModelAsset
    private let parts: [AnyRealitizerID: Entity]
    private let joints: [AnyRealitizerID: Entity]
    private let models: [AnyRealitizerID: ModelEntity]
    private let sockets: [AnyRealitizerID: Entity]
    private var levels: [AnyRealitizerID: Int] = [:]

    init(asset: RigidModelAsset) throws {
        self.asset = asset
        let definition = asset.definition, root = Entity()
        root.name = definition.name
        var parts: [AnyRealitizerID: Entity] = [:], joints: [AnyRealitizerID: Entity] = [:]
        var models: [AnyRealitizerID: ModelEntity] = [:], sockets: [AnyRealitizerID: Entity] = [:]
        for joint in definition.rig?.joints ?? [] {
            let entity = Entity()
            entity.name = "joint:\(joint.id.rawValue)"
            entity.transform = Transform(joint.restTransform)
            joints[joint.id] = entity
        }
        for part in definition.parts {
            let anchor = Entity()
            anchor.name = "part:\(part.id.rawValue)"
            anchor.transform = Transform(part.transform)
            let model = ModelEntity(mesh: part.mesh,
                                    materials: ([part.materialID] + part.additionalMaterialIDs).map { asset.materials[$0]! })
            model.name = "mesh:\(part.id.rawValue)"
            anchor.addChild(model)
            parts[part.id] = anchor
            models[part.id] = model
        }
        func node(_ reference: HierarchyNodeReference) -> Entity {
            switch reference {
            case .part(let id): parts[id]!
            case .joint(let id): joints[id]!
            }
        }
        for joint in definition.rig?.joints ?? [] {
            (joint.parentID.map { joints[$0]! } ?? root).addChild(joints[joint.id]!)
        }
        for part in definition.parts { (part.parent.map(node) ?? root).addChild(parts[part.id]!) }
        for socket in definition.sockets {
            let entity = Entity()
            entity.name = "socket:\(socket.id.rawValue)"
            entity.transform = Transform(socket.transform)
            node(socket.parent).addChild(entity)
            sockets[socket.id] = entity
        }
        self.root = root
        self.parts = parts
        self.joints = joints
        self.models = models
        self.sockets = sockets
    }

    public func part<ID: RealitizerID>(_ id: ID) throws -> Entity { try lookup(id.erasedID, in: parts, kind: .part) }
    public func joint<ID: RealitizerID>(_ id: ID) throws -> Entity { try lookup(id.erasedID, in: joints, kind: .joint) }
    public func socket<ID: RealitizerID>(_ id: ID) throws -> Entity { try lookup(id.erasedID, in: sockets, kind: .socket) }
    public func meshEntity<ID: RealitizerID>(_ id: ID) throws -> ModelEntity { try lookup(id.erasedID, in: models, kind: .part) }

    public var currentPose: PoseDefinition {
        var transforms: [AnimationTarget: ModelTransform] = [:]
        for (id, entity) in parts { transforms[.part(id)] = entity.transform.portable }
        for (id, entity) in joints { transforms[.joint(id)] = entity.transform.portable }
        return PoseDefinition(id: AnyRealitizerID("current"), transforms: transforms)
    }

    public func apply(_ pose: PoseDefinition) throws {
        let writes = try pose.transforms.map { target, transform -> (Entity, Transform) in
            try transform.validate()
            let entity: Entity
            switch target {
            case .part(let id): entity = try part(id)
            case .joint(let id): entity = try joint(id)
            }
            return (entity, Transform(transform))
        }
        for (entity, transform) in writes { entity.transform = transform }
    }

    public func resetPose() throws { try apply(asset.definition.restPose) }

    public func sample<ID: RealitizerID>(_ id: ID, at time: Float) throws {
        guard time.isFinite && time >= 0 else { throw AnimationRuntimeError.invalidDeltaTime(time) }
        guard let clip = asset.definition.clips.first(where: { $0.id == id.erasedID }) else {
            throw RuntimeModelError.missingClip(id.erasedID)
        }
        var transforms = asset.definition.restPose.transforms
        transforms.merge(clip.sample(at: time).transforms) { _, sampled in sampled }
        try apply(PoseDefinition(id: id.erasedID, transforms: transforms))
    }

    public func setLevelOfDetail(_ index: Int) throws {
        guard index >= 0 else { throw RuntimeModelError.invalidLevelOfDetail }
        for part in asset.definition.parts { select(min(index, part.levelsOfDetail.count), for: part) }
    }

    /// Changes one part without changing other parts or replacing semantic Entity handles.
    /// Indices beyond the available levels select the coarsest level, as in the global setter.
    public func setLevelOfDetail<ID: RealitizerID>(_ index: Int, part id: ID) throws {
        guard index >= 0 else { throw RuntimeModelError.invalidLevelOfDetail }
        guard let part = asset.definition.parts.first(where: { $0.id == id.erasedID }) else {
            throw RuntimeModelError.missingNode(kind: .part, id: id.erasedID)
        }
        select(min(index, part.levelsOfDetail.count), for: part)
    }

    public func updateLevelOfDetail(distance: Float) throws {
        guard distance.isFinite && distance >= 0 else { throw RuntimeModelError.invalidLevelOfDetail }
        for part in asset.definition.parts {
            select(part.levelsOfDetail.prefix { distance >= $0.minimumDistance }.count, for: part)
        }
    }

    public func levelOfDetail<ID: RealitizerID>(for id: ID) throws -> Int {
        _ = try part(id)
        return levels[id.erasedID, default: 0]
    }

    private func select(_ index: Int, for part: ModelResourcePart) {
        guard index != levels[part.id, default: 0] else { return }
        models[part.id]?.model?.mesh = index == 0 ? part.mesh : part.levelsOfDetail[index - 1].mesh
        levels[part.id] = index
    }

    private func lookup<T>(_ id: AnyRealitizerID, in table: [AnyRealitizerID: T], kind: RuntimeModelError.NodeKind) throws -> T {
        guard let value = table[id] else { throw RuntimeModelError.missingNode(kind: kind, id: id) }
        return value
    }
}
