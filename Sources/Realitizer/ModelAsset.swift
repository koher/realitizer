import Foundation
import simd

/// One independently addressable mesh in a model asset.
public struct ModelPartDefinition: Sendable {
    public let id: AnyRealitizerID
    public var geometry: ModelGeometry
    public var materialID: AnyRealitizerID
    public var transform: ModelTransform
    public var parent: HierarchyNodeReference?
    public var additionalMaterialIDs: [AnyRealitizerID] = []
    public var levelsOfDetail: [ModelGeometryLevel] = []

    public init<ID: RealitizerID, MaterialID: RealitizerID>(
        id: ID,
        mesh: MeshData,
        material: MaterialID,
        transform: ModelTransform = .identity,
        parent: HierarchyNodeReference? = nil
    ) {
        self.init(
            id: id, geometry: ModelGeometry(mesh: mesh), material: material, transform: transform,
            parent: parent)
    }

    public init<ID: RealitizerID, MaterialID: RealitizerID>(
        id: ID,
        geometry: ModelGeometry,
        material: MaterialID,
        transform: ModelTransform = .identity,
        parent: HierarchyNodeReference? = nil
    ) {
        self.id = id.erasedID
        self.geometry = geometry
        materialID = material.erasedID
        self.transform = transform
        self.parent = parent
    }
}

/// A portable collision primitive.
public enum CollisionShapeDefinition: Equatable, Sendable {
    case box(size: SIMD3<Float>)
    case sphere(radius: Float)
    case capsule(height: Float, radius: Float)
    case convex(points: [SIMD3<Float>])
}

/// One collision shape attached to a semantic hierarchy node.
public struct ModelCollisionDefinition: Sendable {
    public let id: AnyRealitizerID
    public var parent: HierarchyNodeReference
    public var shape: CollisionShapeDefinition
    public var transform: ModelTransform
    public var group: UInt32 = 1
    public var mask: UInt32 = .max
    public var isTrigger: Bool = false
    public var acceptsInput: Bool = false
    public var physics: ModelPhysicsDefinition? = nil

    public init<ID: RealitizerID>(
        id: ID,
        parent: HierarchyNodeReference,
        shape: CollisionShapeDefinition,
        transform: ModelTransform = .identity
    ) {
        self.id = id.erasedID
        self.parent = parent
        self.shape = shape
        self.transform = transform
    }
}

/// The complete code-first source of truth for a game-ready model.
public struct ModelAssetDefinition: Sendable {
    public var name: String
    public var materials: [MaterialDefinition]
    public var parts: [ModelPartDefinition]
    public var rig: RigDefinition?
    public var sockets: [SocketDefinition]
    public var collisions: [ModelCollisionDefinition]
    public var poses: [PoseDefinition]
    public var clips: [AnimationClipDefinition]
    public var animationGraph: AnimationGraphDefinition?

    public init(
        name: String,
        materials: [MaterialDefinition],
        parts: [ModelPartDefinition],
        rig: RigDefinition? = nil,
        sockets: [SocketDefinition] = [],
        collisions: [ModelCollisionDefinition] = [],
        poses: [PoseDefinition] = [],
        clips: [AnimationClipDefinition] = [],
        animationGraph: AnimationGraphDefinition? = nil
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

    public func validationReport() -> ModelValidationReport {
        var diagnostics: [ModelDiagnostic] = []
        validateTopLevel(into: &diagnostics)
        validateHierarchy(into: &diagnostics)
        validateAnimation(into: &diagnostics)
        diagnostics.append(contentsOf: extendedValidationDiagnostics())
        return ModelValidationReport(diagnostics: diagnostics)
    }

    public func validated() throws -> Self {
        try validationReport().throwingIfNeeded()
        return self
    }

    public var bounds: MeshBounds? {
        let points = parts.flatMap { part in
            guard let matrix = try? globalTransform(of: .part(part.id)) else { return [SIMD3<Float>]() }
            return part.geometry.mesh.vertices.map { matrix.point($0.position) }
        }
        guard let first = points.first else {
            return nil
        }
        return MeshBounds(
            minimum: points.dropFirst().reduce(first, simd_min),
            maximum: points.dropFirst().reduce(first, simd_max)
        )
    }

    private func validateTopLevel(into diagnostics: inout [ModelDiagnostic]) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(.error("asset.emptyName", path: "name", "Asset name must not be empty."))
        }
        appendDuplicateDiagnostics(materials.map(\.id), collection: "materials", into: &diagnostics)
        appendDuplicateDiagnostics(parts.map(\.id), collection: "parts", into: &diagnostics)
        appendDuplicateDiagnostics(sockets.map(\.id), collection: "sockets", into: &diagnostics)
        appendDuplicateDiagnostics(collisions.map(\.id), collection: "collisions", into: &diagnostics)
        appendDuplicateDiagnostics(poses.map(\.id), collection: "poses", into: &diagnostics)
        appendDuplicateDiagnostics(clips.map(\.id), collection: "clips", into: &diagnostics)

        let materialIDs = Set(materials.map(\.id))
        for material in materials {
            diagnostics += material.validationReport().diagnostics
        }

        for (index, part) in parts.enumerated() {
            let path = "parts[\(index)]"
            diagnostics.append(contentsOf: part.geometry.mesh.validationDiagnostics(path: "\(path).mesh"))
            if !materialIDs.contains(part.materialID) {
                diagnostics.append(
                    .error(
                        "part.missingMaterial", path: "\(path).materialID",
                        "Part references an unknown material."))
            }
            if !part.transform.isFinite {
                diagnostics.append(
                    .error(
                        "part.invalidTransform", path: "\(path).transform", "Part transform must be finite."))
            }
        }

    }

    private func validateHierarchy(into diagnostics: inout [ModelDiagnostic]) {
        let partIDs = Set(parts.map(\.id))
        let joints = rig?.joints ?? []
        let jointIDs = Set(joints.map(\.id))

        if let rig {
            if rig.version < 1 {
                diagnostics.append(
                    .error("rig.invalidVersion", path: "rig.version", "Rig version must be at least one."))
            }
            appendDuplicateDiagnostics(joints.map(\.id), collection: "rig.joints", into: &diagnostics)
            for (index, joint) in joints.enumerated() {
                let path = "rig.joints[\(index)]"
                if let parentID = joint.parentID, !jointIDs.contains(parentID) {
                    diagnostics.append(
                        .error(
                            "joint.missingParent", path: "\(path).parentID",
                            "Joint references an unknown parent joint."
                        ))
                }
                if !joint.restTransform.isFinite {
                    diagnostics.append(
                        .error(
                            "joint.invalidTransform", path: "\(path).restTransform",
                            "Joint rest transform must be finite."))
                }
                if let mirror = joint.mirroredJointID, !jointIDs.contains(mirror) {
                    diagnostics.append(
                        .error(
                            "joint.missingMirror", path: "\(path).mirroredJointID",
                            "Joint references an unknown mirrored joint."))
                }
            }
            var parents: [AnyRealitizerID: AnyRealitizerID?] = [:]
            for joint in joints {
                parents[joint.id] = joint.parentID
            }
            for id in cyclicNodes(in: parents) {
                diagnostics.append(
                    .error(
                        "joint.hierarchyCycle", path: "rig.joints.\(id.rawValue)",
                        "Joint hierarchy must not contain a cycle."))
            }
        }

        for (index, part) in parts.enumerated() {
            if let parent = part.parent,
                !nodeExists(parent, partIDs: partIDs, jointIDs: jointIDs)
            {
                diagnostics.append(
                    .error(
                        "part.missingParent", path: "parts[\(index)].parent",
                        "Part references an unknown hierarchy node."))
            }
        }
        var partParents: [AnyRealitizerID: AnyRealitizerID?] = [:]
        for part in parts {
            let parentID: AnyRealitizerID?
            if case .part(let id)? = part.parent {
                parentID = id
            } else {
                parentID = nil
            }
            partParents[part.id] = parentID
        }
        for id in cyclicNodes(in: partParents) {
            diagnostics.append(
                .error(
                    "part.hierarchyCycle", path: "parts.\(id.rawValue)",
                    "Part hierarchy must not contain a cycle."))
        }

        for (index, socket) in sockets.enumerated() {
            if !nodeExists(socket.parent, partIDs: partIDs, jointIDs: jointIDs) {
                diagnostics.append(
                    .error(
                        "socket.missingParent", path: "sockets[\(index)].parent",
                        "Socket references an unknown hierarchy node."))
            }
            if !socket.transform.isFinite {
                diagnostics.append(
                    .error(
                        "socket.invalidTransform", path: "sockets[\(index)].transform",
                        "Socket transform must be finite."))
            }
        }

        for (index, collision) in collisions.enumerated() {
            let path = "collisions[\(index)]"
            if !nodeExists(collision.parent, partIDs: partIDs, jointIDs: jointIDs) {
                diagnostics.append(
                    .error(
                        "collision.missingParent", path: "\(path).parent",
                        "Collision shape references an unknown hierarchy node."))
            }
            if !collision.transform.isFinite {
                diagnostics.append(
                    .error(
                        "collision.invalidTransform", path: "\(path).transform",
                        "Collision transform must be finite."))
            }
            switch collision.shape {
            case .capsule(let height, let radius):
                if !height.isFinite || !radius.isFinite || radius <= 0 || height < 2 * radius {
                    diagnostics.append(
                        .error(
                            "collision.invalidCapsule", path: path,
                            "Capsule total height must be at least twice its positive radius."))
                }
            case .convex(let points):
                if points.count < 4 || points.count > 4096 || !points.allSatisfy(\.isFinite) {
                    diagnostics.append(
                        .error(
                            "collision.invalidConvex", path: path, "Convex shapes require 4...4096 finite points."
                        ))
                }
            case .box(let size):
                if !size.isFinite || size.x <= 0 || size.y <= 0 || size.z <= 0 {
                    diagnostics.append(
                        .error(
                            "collision.invalidBox", path: "\(path).shape",
                            "Collision box dimensions must be finite and greater than zero."))
                }
            case .sphere(let radius):
                if !radius.isFinite || radius <= 0 {
                    diagnostics.append(
                        .error(
                            "collision.invalidSphere", path: "\(path).shape",
                            "Collision sphere radius must be finite and greater than zero."))
                }
            }
        }
    }

    private func validateAnimation(into diagnostics: inout [ModelDiagnostic]) {
        let partIDs = Set(parts.map(\.id))
        let jointIDs = Set((rig?.joints ?? []).map(\.id))
        let clipIDs = Set(clips.map(\.id))

        for (poseIndex, pose) in poses.enumerated() {
            for target in pose.transforms.keys
            where !animationTargetExists(target, partIDs: partIDs, jointIDs: jointIDs) {
                diagnostics.append(
                    .error(
                        "pose.missingTarget", path: "poses[\(poseIndex)]",
                        "Pose references an unknown animation target."))
            }
        }

        for (clipIndex, clip) in clips.enumerated() {
            let clipPath = "clips[\(clipIndex)]"
            if !clip.duration.isFinite || clip.duration <= 0 {
                diagnostics.append(
                    .error(
                        "clip.invalidDuration", path: "\(clipPath).duration",
                        "Clip duration must be finite and greater than zero."))
            }
            var channelTargets: Set<AnimationTarget> = []
            for (channelIndex, channel) in clip.channels.enumerated() {
                let channelPath = "\(clipPath).channels[\(channelIndex)]"
                if !channelTargets.insert(channel.target).inserted {
                    diagnostics.append(
                        .error(
                            "clip.duplicateChannel", path: channelPath,
                            "A clip must contain at most one channel for each target."))
                }
                if !animationTargetExists(channel.target, partIDs: partIDs, jointIDs: jointIDs) {
                    diagnostics.append(
                        .error(
                            "clip.missingTarget", path: "\(channelPath).target",
                            "Channel references an unknown animation target."))
                }
                if channel.keyframes.isEmpty {
                    diagnostics.append(
                        .error(
                            "clip.emptyChannel", path: "\(channelPath).keyframes",
                            "Animation channel must contain at least one keyframe."))
                }
                for (keyframeIndex, keyframe) in channel.keyframes.enumerated() {
                    if !keyframe.time.isFinite || keyframe.time < 0 || keyframe.time > clip.duration {
                        diagnostics.append(
                            .error(
                                "clip.invalidKeyframeTime", path: "\(channelPath).keyframes[\(keyframeIndex)].time",
                                "Keyframe time must be within the clip duration."))
                    }
                    if !keyframe.transform.isFinite {
                        diagnostics.append(
                            .error(
                                "clip.invalidKeyframeTransform",
                                path: "\(channelPath).keyframes[\(keyframeIndex)].transform",
                                "Keyframe transform must be finite."))
                    }
                    if keyframeIndex > 0 && keyframe.time <= channel.keyframes[keyframeIndex - 1].time {
                        diagnostics.append(
                            .error(
                                "clip.unsortedKeyframes", path: "\(channelPath).keyframes",
                                "Keyframe times must be strictly increasing."))
                    }
                }
            }
            appendDuplicateDiagnostics(
                clip.events.map(\.id), collection: "\(clipPath).events", into: &diagnostics)
            for (eventIndex, event) in clip.events.enumerated()
            where !event.time.isFinite || event.time < 0 || event.time > clip.duration {
                diagnostics.append(
                    .error(
                        "clip.invalidEventTime", path: "\(clipPath).events[\(eventIndex)].time",
                        "Event time must be within the clip duration."))
            }
        }

        if let graph = animationGraph {
            validate(graph, clipIDs: clipIDs, into: &diagnostics)
        }
    }

    private func validate(
        _ graph: AnimationGraphDefinition,
        clipIDs: Set<AnyRealitizerID>,
        into diagnostics: inout [ModelDiagnostic]
    ) {
        appendDuplicateDiagnostics(
            graph.parameters.map(\.id), collection: "animationGraph.parameters", into: &diagnostics)
        appendDuplicateDiagnostics(
            graph.states.map(\.id), collection: "animationGraph.states", into: &diagnostics)
        var parameterKinds: [AnyRealitizerID: AnimationParameterKind] = [:]
        for parameter in graph.parameters {
            parameterKinds[parameter.id] = parameter.kind
        }
        let stateIDs = Set(graph.states.map(\.id))
        if !stateIDs.contains(graph.initialStateID) {
            diagnostics.append(
                .error(
                    "graph.missingInitialState", path: "animationGraph.initialStateID",
                    "Animation graph references an unknown initial state."))
        }
        for (index, state) in graph.states.enumerated() {
            if !clipIDs.contains(state.clipID) {
                diagnostics.append(
                    .error(
                        "graph.missingClip", path: "animationGraph.states[\(index)].clipID",
                        "Animation state references an unknown clip."))
            }
            if !state.speed.isFinite || state.speed < 0 {
                diagnostics.append(
                    .error(
                        "graph.invalidSpeed", path: "animationGraph.states[\(index)].speed",
                        "Animation state speed must be finite and nonnegative."))
            }
        }
        for (index, transition) in graph.transitions.enumerated() {
            let path = "animationGraph.transitions[\(index)]"
            if !stateIDs.contains(transition.sourceStateID)
                || !stateIDs.contains(transition.destinationStateID)
            {
                diagnostics.append(
                    .error(
                        "graph.missingTransitionState", path: path,
                        "Animation transition references an unknown state.")
                )
            }
            if !transition.duration.isFinite || transition.duration < 0 {
                diagnostics.append(
                    .error(
                        "graph.invalidTransitionDuration", path: "\(path).duration",
                        "Transition duration must be finite and nonnegative."))
            }
            if transition.conditions.isEmpty {
                diagnostics.append(
                    .error(
                        "graph.emptyConditions", path: "\(path).conditions",
                        "Transition must contain at least one condition."))
            }
            for (conditionIndex, condition) in transition.conditions.enumerated() {
                guard let parameterID = condition.parameterID else {
                    continue
                }
                let conditionPath = "\(path).conditions[\(conditionIndex)]"
                guard let kind = parameterKinds[parameterID] else {
                    diagnostics.append(
                        .error(
                            "graph.missingParameter", path: conditionPath,
                            "Transition condition references an unknown parameter."))
                    continue
                }
                let matches: Bool
                switch (condition, kind) {
                case (.boolean(_, _), .boolean(_)),
                    (.scalarGreaterThan(_, _), .scalar(_)),
                    (.scalarLessThan(_, _), .scalar(_)),
                    (.trigger(_), .trigger):
                    matches = true
                default:
                    matches = false
                }
                if !matches {
                    diagnostics.append(
                        .error(
                            "graph.parameterTypeMismatch", path: conditionPath,
                            "Transition condition does not match its parameter type."))
                }
            }
        }
    }
}

private func appendDuplicateDiagnostics(
    _ ids: [AnyRealitizerID],
    collection: String,
    into diagnostics: inout [ModelDiagnostic]
) {
    var known: Set<AnyRealitizerID> = []
    for (index, id) in ids.enumerated() where !known.insert(id).inserted {
        diagnostics.append(
            .error(
                "id.duplicate", path: "\(collection)[\(index)].id",
                "Semantic identifiers must be unique within their collection."))
    }
}

private func cyclicNodes(
    in parents: [AnyRealitizerID: AnyRealitizerID?]
) -> Set<AnyRealitizerID> {
    var cyclic: Set<AnyRealitizerID> = []
    for origin in parents.keys {
        var path: [AnyRealitizerID] = []
        var positions: [AnyRealitizerID: Int] = [:]
        var current: AnyRealitizerID? = origin
        while let id = current, let parent = parents[id] {
            if let position = positions[id] {
                cyclic.formUnion(path[position...])
                break
            }
            positions[id] = path.count
            path.append(id)
            current = parent
        }
    }
    return cyclic
}

private func nodeExists(
    _ node: HierarchyNodeReference,
    partIDs: Set<AnyRealitizerID>,
    jointIDs: Set<AnyRealitizerID>
) -> Bool {
    switch node {
    case .part(let id):
        partIDs.contains(id)
    case .joint(let id):
        jointIDs.contains(id)
    }
}

private func animationTargetExists(
    _ target: AnimationTarget,
    partIDs: Set<AnyRealitizerID>,
    jointIDs: Set<AnyRealitizerID>
) -> Bool {
    switch target {
    case .part(let id):
        partIDs.contains(id)
    case .joint(let id):
        jointIDs.contains(id)
    }
}
