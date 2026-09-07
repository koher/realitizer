import Realitizer
import RealityKit
import simd

/// Per-instance poses and overrides. Compiled resources are shared; entity and animation state never are.
@MainActor
public final class RuntimeModelInstance {
    public let definition: ModelAssetDefinition
    public let root: Entity
    private let compiled: CompiledModelAsset
    private let parts: [AnyRealitizerID: Entity]
    private let models: [AnyRealitizerID: ModelEntity]
    private let joints: [AnyRealitizerID: Entity]
    private let sockets: [AnyRealitizerID: Entity]
    private let collisions: [AnyRealitizerID: Entity]
    private var activeLevels: [AnyRealitizerID: Int] = [:]
    private var dynamicMeshes: [AnyRealitizerID: DynamicModelMesh] = [:]
    private var morphWeights: [AnyRealitizerID: [AnyRealitizerID: Float]] = [:]
    private var materialOverrides: [AnyRealitizerID: any Material] = [:]
    private var animatedMaterials: [AnyRealitizerID: any Material] = [:]
    private var visualizationMaterials: [AnyRealitizerID: any Material] = [:]
    private weak var animationOwner: RuntimeModelAnimator?

    init(
        compiled: CompiledModelAsset, root: Entity, parts: [AnyRealitizerID: Entity],
        models: [AnyRealitizerID: ModelEntity],
        joints: [AnyRealitizerID: Entity], sockets: [AnyRealitizerID: Entity],
        collisions: [AnyRealitizerID: Entity]
    ) {
        self.compiled = compiled
        definition = compiled.definition
        self.root = root
        self.parts = parts
        self.models = models
        self.joints = joints
        self.sockets = sockets
        self.collisions = collisions
    }

    public func part<ID: RealitizerID>(_ id: ID) throws -> Entity {
        try lookup(id.erasedID, in: parts, kind: .part)
    }
    /// Raw entity access is useful for attachments. Use setJointTransform to synchronize skinned geometry.
    public func joint<ID: RealitizerID>(_ id: ID) throws -> Entity {
        try lookup(id.erasedID, in: joints, kind: .joint)
    }
    public func socket<ID: RealitizerID>(_ id: ID) throws -> Entity {
        try lookup(id.erasedID, in: sockets, kind: .socket)
    }
    public func collision<ID: RealitizerID>(_ id: ID) throws -> Entity {
        try lookup(id.erasedID, in: collisions, kind: .collision)
    }
    public func attach<ID: RealitizerID>(_ entity: Entity, to socketID: ID) throws {
        try socket(socketID).addChild(entity)
    }
    public func meshEntity<ID: RealitizerID>(_ id: ID) throws -> ModelEntity {
        guard let model = models[id.erasedID] else {
            throw RuntimeModelError.missingNode(kind: .part, id: id.erasedID)
        }
        return model
    }

    public var currentPose: PoseDefinition {
        var transforms: [AnimationTarget: ModelTransform] = [:]
        for (id, entity) in parts { transforms[.part(id)] = entity.transform.portable }
        for (id, entity) in joints { transforms[.joint(id)] = entity.transform.portable }
        return PoseDefinition(id: AnyRealitizerID(rawValue: "current"), transforms: transforms)
    }

    public var statistics: ModelStatistics {
        var active = definition
        for i in compiled.parts.indices {
            let part = compiled.parts[i]
            active.parts[i].geometry =
                part.levels[activeLevels[part.definition.id, default: 0]].definition.geometry
        }
        return active.statistics
    }

    public var entityCount: Int {
        func count(_ entity: Entity) -> Int { 1 + entity.children.reduce(0) { $0 + count($1) } }
        return count(root)
    }

    public func setJointTransform<ID: RealitizerID>(_ transform: ModelTransform, for id: ID) throws {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        try apply(transforms: [.joint(id.erasedID): transform])
    }

    public func apply(_ pose: PoseDefinition) throws {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        try apply(transforms: pose.transforms)
    }

    public func resetPose() throws {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        try commit(
            transforms: definition.restPose.transforms, weights: [:], materials: [:], levels: activeLevels
        )
    }

    public func sample<ID: RealitizerID>(_ id: ID, at time: Float) throws {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        guard let clip = definition.clips.first(where: { $0.id == id.erasedID }) else {
            throw RuntimeModelError.missingClip(id.erasedID)
        }
        guard time.isFinite, time >= 0 else { throw AnimationRuntimeError.invalidDeltaTime(time) }
        var sampled = clip.sample(at: time)
        for (target, rest) in definition.restPose.transforms where sampled.transforms[target] == nil {
            sampled.transforms[target] = rest
        }
        try apply(sampled)
    }

    public func makeAnimator() throws -> RuntimeModelAnimator {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        guard let graph = definition.animationGraph else {
            throw RuntimeModelError.missingAnimationGraph
        }
        let animator = try RuntimeModelAnimator(
            instance: self,
            player: AnimationGraphPlayer(
                graph: graph, clips: definition.clips, referencePose: definition.restPose,
                referenceScalars: definition.referenceScalarValues))
        animationOwner = animator
        return animator
    }

    /// LOD replacement changes the model component below the semantic part; handles and sockets remain valid.
    public func setLevelOfDetail(_ index: Int) throws {
        guard index >= 0 else { throw RuntimeModelError.invalidLevelOfDetail }
        var levels = activeLevels
        for part in compiled.parts { levels[part.definition.id] = min(index, part.levels.count - 1) }
        try commit(transforms: [:], weights: morphWeights, materials: animatedMaterials, levels: levels)
    }

    public func updateLevelOfDetail(distance: Float) throws {
        guard distance.isFinite, distance >= 0 else { throw RuntimeModelError.invalidLevelOfDetail }
        var levels = activeLevels
        for part in compiled.parts {
            levels[part.definition.id] =
                part.levels.lastIndex(where: { $0.definition.minimumDistance <= distance }) ?? 0
        }
        try commit(transforms: [:], weights: morphWeights, materials: animatedMaterials, levels: levels)
    }

    public func setLevelOfDetail<ID: RealitizerID>(_ index: Int, part id: ID) throws {
        guard let part = compiled.parts.first(where: { $0.definition.id == id.erasedID }),
            part.levels.indices.contains(index),
            models[id.erasedID] != nil
        else { throw RuntimeModelError.invalidLevelOfDetail }
        if activeLevels[id.erasedID, default: 0] == index { return }
        var levels = activeLevels
        levels[id.erasedID] = index
        try commit(transforms: [:], weights: morphWeights, materials: animatedMaterials, levels: levels)
    }

    public func setMorphWeight<Part: RealitizerID, Target: RealitizerID>(
        _ weight: Float, part: Part, target: Target
    )
        throws
    {
        guard animationOwner == nil else { throw RuntimeModelError.animationOwnership }
        guard weight.isFinite, (0...1).contains(weight),
            let source = definition.parts.first(where: { $0.id == part.erasedID }),
            source.geometry.morphTargets.contains(where: { $0.id == target.erasedID })
        else { throw RuntimeModelError.invalidMorph }
        var weights = morphWeights
        weights[part.erasedID, default: [:]][target.erasedID] = weight
        try commit(
            transforms: [:], weights: weights, materials: animatedMaterials, levels: activeLevels)
    }

    public func setMaterial<ID: RealitizerID>(_ material: any Material, for id: ID) throws {
        guard definition.materials.contains(where: { $0.id == id.erasedID }) else {
            throw RealityKitCompilationError.missingMaterial(id.erasedID)
        }
        materialOverrides[id.erasedID] = material
        try refreshMaterials()
    }

    /// Temporary authoring overlays never mutate manual or animated materials.
    public func setVisualizationMaterials(_ materials: [AnyRealitizerID: any Material]) throws {
        for id in materials.keys where compiled.materials[id] == nil {
            throw RealityKitCompilationError.missingMaterial(id)
        }
        visualizationMaterials = materials
        try refreshMaterials()
    }

    private func refreshMaterials() throws {
        for part in definition.parts {
            let ids = [part.materialID] + part.additionalMaterialIDs
            models[part.id]?.model?.materials = try ids.map { materialID in
                guard
                    let value = visualizationMaterials[materialID] ?? animatedMaterials[materialID]
                        ?? materialOverrides[materialID] ?? compiled.materials[materialID]
                else { throw RealityKitCompilationError.missingMaterial(materialID) }
                return value
            }
        }
    }

    public func synchronizeJointEntities() throws { try refreshDeformations() }

    public func resetMaterials() {
        materialOverrides.removeAll()
        animatedMaterials.removeAll()
        visualizationMaterials.removeAll()
        for part in definition.parts {
            let ids = [part.materialID] + part.additionalMaterialIDs
            models[part.id]?.model?.materials = ids.compactMap { compiled.materials[$0] }
        }
    }

    public func geometry<ID: RealitizerID>(for id: ID) throws -> ModelGeometry {
        guard let part = compiled.parts.first(where: { $0.definition.id == id.erasedID }) else {
            throw RuntimeModelError.missingNode(kind: .part, id: id.erasedID)
        }
        return part.levels[activeLevels[id.erasedID, default: 0]].definition.geometry
    }

    public func levelOfDetail<ID: RealitizerID>(for id: ID) throws -> Int {
        guard parts[id.erasedID] != nil else {
            throw RuntimeModelError.missingNode(kind: .part, id: id.erasedID)
        }
        return activeLevels[id.erasedID, default: 0]
    }

    /// CPU-evaluated current geometry for authoring tools and geometric verification.
    public func evaluatedMesh<ID: RealitizerID>(for id: ID) throws -> MeshData {
        let geometry = try geometry(for: id)
        var mesh = geometry.mesh
        for target in geometry.morphTargets {
            let weight = morphWeights[id.erasedID]?[target.id] ?? 0
            for i in mesh.vertices.indices {
                mesh.vertices[i].position += target.positionDeltas[i] * weight
                if !target.normalDeltas.isEmpty {
                    mesh.vertices[i].normal += target.normalDeltas[i] * weight
                }
            }
        }
        for i in mesh.vertices.indices {
            mesh.vertices[i].normal = simd_normalize(mesh.vertices[i].normal)
        }
        if let skin = geometry.skin, let rig = definition.rig {
            return try skin.deform(mesh, rig: rig, pose: currentPose)
        }
        return try mesh.generatingTangents().validated()
    }

    func apply(_ sample: SampledAnimationPose) throws {
        var transforms = sample.transforms
        for collision in definition.collisions where collision.physics?.mode == .dynamic {
            switch collision.parent {
            case .part(let id): transforms.removeValue(forKey: .part(id))
            case .joint(let id): transforms.removeValue(forKey: .joint(id))
            }
        }
        var weights = morphWeights
        var materials: [AnyRealitizerID: any Material] = [:]
        for clip in definition.clips {
            for channel in clip.scalarChannels {
                if case .morph(let part, let morph) = channel.target {
                    weights[part, default: [:]][morph] = 0
                }
            }
        }
        for (target, value) in sample.scalarValues {
            guard value.isFinite, value >= 0,
                definition.referenceScalarValues[target] != nil
            else { throw RuntimeModelError.invalidMorph }
            if case .material(_, .emissiveIntensity) = target {
            } else {
                guard value <= 1 else { throw RuntimeModelError.invalidMorph }
            }
            switch target {
            case .morph(let part, let morph):
                guard value.isFinite, (0...1).contains(value) else { throw RuntimeModelError.invalidMorph }
                weights[part, default: [:]][morph] = value
            case .material(let id, let property):
                let source = materials[id] ?? materialOverrides[id] ?? compiled.materials[id]
                if var material = source as? PhysicallyBasedMaterial {
                    switch property {
                    case .roughness: material.roughness.scale = value
                    case .metallic: material.metallic.scale = value
                    case .emissiveIntensity: material.emissiveIntensity = value
                    case .opacity: material.blending = .transparent(opacity: .init(floatLiteral: value))
                    }
                    materials[id] = material
                } else if var material = source as? CustomMaterial,
                          materialOverrides[id] == nil,
                          definition.materials.first(where: { $0.id == id })?.vertexColorMode == .multiply {
                    switch property {
                    case .roughness: material.roughness.scale = value
                    case .metallic: material.metallic.scale = value
                    case .emissiveIntensity: material.custom.value.y = value
                    case .opacity: material.blending = .transparent(opacity: .init(floatLiteral: value))
                    }
                    materials[id] = material
                } else if var material = source as? UnlitMaterial, property == .opacity {
                    material.blending = .transparent(opacity: .init(floatLiteral: value))
                    materials[id] = material
                } else {
                    throw RuntimeModelError.unsupportedAnimatedMaterial(id)
                }
            }
        }
        try commit(transforms: transforms, weights: weights, materials: materials, levels: activeLevels)
    }

    func apply(transforms: [AnimationTarget: ModelTransform]) throws {
        try commit(
            transforms: transforms, weights: morphWeights, materials: animatedMaterials,
            levels: activeLevels)
    }

    func refreshDeformations() throws {
        try commit(
            transforms: [:], weights: morphWeights, materials: animatedMaterials, levels: activeLevels)
    }

    /// Prepare every recoverable operation before publishing any state or GPU buffer changes.
    private func commit(
        transforms: [AnimationTarget: ModelTransform],
        weights: [AnyRealitizerID: [AnyRealitizerID: Float]],
        materials: [AnyRealitizerID: any Material], levels: [AnyRealitizerID: Int]
    ) throws {
        let writes = try transforms.map { target, transform -> (Entity, ModelTransform) in
            try transform.validate()
            switch target {
            case .part(let id): return try (lookup(id, in: parts, kind: .part), transform)
            case .joint(let id): return try (lookup(id, in: joints, kind: .joint), transform)
            }
        }
        var pose = currentPose
        for (target, transform) in transforms { pose.transforms[target] = transform }
        var commits: [() -> Void] = []
        for part in compiled.parts {
            let id = part.definition.id
            let index = levels[id, default: 0]
            let geometry = part.levels[index]
            guard let model = models[id] else { continue }
            let ids = [part.definition.materialID] + part.definition.additionalMaterialIDs
            let resolvedMaterials = try ids.map { id -> any Material in
                guard
                    let value = visualizationMaterials[id] ?? materials[id] ?? materialOverrides[id]
                        ?? compiled.materials[id]
                else { throw RealityKitCompilationError.missingMaterial(id) }
                return value
            }
            commits.append { model.model?.materials = resolvedMaterials }
            let changedLevel = index != activeLevels[id, default: 0]
            if geometry.cpuDeformation {
                var mesh = geometry.definition.geometry.mesh
                for morph in geometry.definition.geometry.morphTargets {
                    let weight = weights[id]?[morph.id] ?? 0
                    for i in mesh.vertices.indices {
                        mesh.vertices[i].position += morph.positionDeltas[i] * weight
                        if !morph.normalDeltas.isEmpty {
                            mesh.vertices[i].normal += morph.normalDeltas[i] * weight
                        }
                    }
                }
                for i in mesh.vertices.indices {
                    mesh.vertices[i].normal = simd_normalize(mesh.vertices[i].normal)
                }
                if let skin = geometry.definition.geometry.skin, let rig = definition.rig {
                    mesh = try skin.deform(mesh, rig: rig, pose: pose)
                } else {
                    mesh = try mesh.generatingTangents()
                }
                _ = try mesh.validated()
                let prepared = mesh
                if !changedLevel, let dynamic = dynamicMeshes[id] {
                    guard mesh.vertices.count <= dynamic.lowLevelMesh.vertexCapacity,
                        mesh.indices.count <= dynamic.lowLevelMesh.indexCapacity
                    else { throw DynamicMeshError.capacityExceeded }
                    commits.append { dynamic.updateValidated(prepared) }
                } else {
                    let dynamic = try DynamicModelMesh(mesh: mesh)
                    commits.append {
                        self.dynamicMeshes[id] = dynamic
                        model.model?.mesh = dynamic.resource
                        configureDeformation(model, geometry: geometry)
                    }
                }
            } else {
                if changedLevel {
                    commits.append {
                        self.dynamicMeshes.removeValue(forKey: id)
                        model.model?.mesh = geometry.mesh
                        configureDeformation(model, geometry: geometry)
                    }
                }
                if let skeleton = geometry.skeleton {
                    let skeletalPose = SkeletalPose(
                        id: skeleton.id,
                        joints: skeleton.joints.map { joint in
                            (
                                joint.name,
                                pose.transforms[.joint(AnyRealitizerID(rawValue: joint.name))].map(Transform.init)
                                    ?? joint.restPoseTransform
                            )
                        })
                    commits.append { model.components.set(SkeletalPosesComponent(poses: [skeletalPose])) }
                }
                let morphValues = geometry.definition.geometry.morphTargets.map {
                    ($0.id.rawValue, weights[id]?[$0.id] ?? 0)
                }
                commits.append {
                    if var component = model.components[BlendShapeWeightsComponent.self] {
                        component.weightSet.set(BlendShapeWeightsData(id: "morphs", weights: morphValues))
                        model.components.set(component)
                    }
                }
            }
        }
        for (entity, transform) in writes { entity.transform = Transform(transform) }
        for commit in commits { commit() }
        morphWeights = weights
        animatedMaterials = materials
        activeLevels = levels
    }

    private func lookup(
        _ id: AnyRealitizerID, in entities: [AnyRealitizerID: Entity], kind: RuntimeModelError.NodeKind
    )
        throws -> Entity
    {
        guard let entity = entities[id] else { throw RuntimeModelError.missingNode(kind: kind, id: id) }
        return entity
    }
}

@MainActor
public final class RuntimeModelAnimator {
    public let instance: RuntimeModelInstance
    public var appliesRootMotion: Bool = false
    public private(set) var lastIKReports: [IKSolveReport] = []
    private var player: AnimationGraphPlayer
    private var targets: [AnyRealitizerID: RigConstraintTarget] = [:]

    init(instance: RuntimeModelInstance, player: AnimationGraphPlayer) throws {
        self.instance = instance
        self.player = player
        let frame = try self.player.seek(state: player.currentStateID)
        try instance.apply(frame.pose)
    }
    public var currentStateID: AnyRealitizerID { player.currentStateID }
    public func set<ID: RealitizerID>(_ value: Bool, for id: ID) throws {
        try player.set(value, for: id)
    }
    public func set<ID: RealitizerID>(_ value: Float, for id: ID) throws {
        try player.set(value, for: id)
    }
    public func activate<ID: RealitizerID>(_ id: ID) throws { try player.activate(id) }
    public func setLayerWeight<ID: RealitizerID>(_ weight: Float, for id: ID) throws {
        try player.setLayerWeight(weight, for: id)
    }
    public func setConstraintTarget<ID: RealitizerID>(_ id: ID, to target: RigConstraintTarget) throws {
        guard
            let constraint = instance.definition.rig?.constraints.first(where: { $0.id == id.erasedID })
        else {
            throw RuntimeModelError.invalidTransform
        }
        try target.validate(for: constraint)
        targets[id.erasedID] = target
    }
    public func setConstraintTarget<ID: RealitizerID>(
        _ id: ID, position: SIMD3<Float>, polePosition: SIMD3<Float>? = nil
    ) throws {
        try setConstraintTarget(
            id, to: RigConstraintTarget(position: position, polePosition: polePosition))
    }
    public func clearConstraintTarget<ID: RealitizerID>(_ id: ID) {
        targets.removeValue(forKey: id.erasedID)
    }

    @discardableResult
    public func seek<ID: RealitizerID>(state: ID, time: Float = 0) throws -> AnimationFrame {
        var candidate = player
        var frame = try candidate.seek(state: state, time: time)
        try finish(&frame)
        player = candidate
        return frame
    }

    @discardableResult
    public func advance(by deltaTime: Float) throws -> AnimationFrame {
        var candidate = player
        var frame = try candidate.advance(by: deltaTime)
        var rootTransform = instance.root.transform.portable
        if appliesRootMotion {
            rootTransform.translation += rootTransform.rotation.act(
                frame.rootMotion.translation * rootTransform.scale)
            rootTransform.rotation *= frame.rootMotion.rotation
            try rootTransform.validate()
        }
        try finish(&frame)
        player = candidate
        if appliesRootMotion { instance.root.transform = Transform(rootTransform) }
        return frame
    }

    private func finish(_ frame: inout AnimationFrame) throws {
        var reports: [IKSolveReport] = []
        if let rig = instance.definition.rig {
            let solved = try RigSolver.solve(
                rig: rig, pose: PoseDefinition(id: frame.pose.clipID, transforms: frame.pose.transforms),
                targets: targets)
            frame.pose.transforms = solved.pose.transforms
            reports = solved.inverseKinematics
        }
        try instance.apply(frame.pose)
        lastIKReports = reports
    }
}

public enum RuntimeModelError: Error, Equatable, Sendable {
    public enum NodeKind: String, Equatable, Sendable { case part, joint, socket, collision }
    case missingNode(kind: NodeKind, id: AnyRealitizerID)
    case missingClip(AnyRealitizerID)
    case missingAnimationGraph
    case animationOwnership
    case invalidLevelOfDetail
    case invalidMorph
    case invalidTransform
    case unsupportedAnimatedMaterial(AnyRealitizerID)
}
