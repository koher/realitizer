import simd

extension ModelAssetDefinition {
    /// Validates cross-feature contracts before allocating renderer resources.
    func authoringValidationDiagnostics() -> [ModelDiagnostic] {
        var result: [ModelDiagnostic] = []
        func check(_ path: String, _ body: () throws -> Void) {
            do { try body() } catch let error as ModelValidationError {
                result += error.diagnostics.map {
                    .init(
                        severity: $0.severity, code: $0.code, path: path + "." + $0.path, message: $0.message)
                }
            } catch { result.append(.error("asset.authoring", path: path, String(describing: error))) }
        }
        func require(_ condition: Bool, _ code: String, _ message: String) throws {
            if !condition { throw modelingError(code, message) }
        }
        let targets = Set(restPose.transforms.keys)
        func transform(_ value: ModelTransform) throws {
            try require(
                value.isFinite && abs(simd_length(value.rotation.vector) - 1) < 0.001
                    && (0..<3).allSatisfy { abs(value.scale[$0]) > 1e-7 }, "transform.invalid",
                "Transforms require finite, nonzero scales and unit quaternions.")
        }
        func pose(_ value: PoseDefinition) throws {
            for (target, value) in value.transforms {
                try require(targets.contains(target), "pose.target", "Pose target does not exist.")
                try transform(value)
            }
        }
        for part in parts { check("parts.\(part.id.rawValue)") { try transform(part.transform) } }
        for socket in sockets {
            check("sockets.\(socket.id.rawValue)") { try transform(socket.transform) }
        }
        for value in poses { check("poses.\(value.id.rawValue)") { try pose(value) } }
        if let rig {
            check("rig") {
                var constraintIDs: Set<AnyRealitizerID> = []
                let joints = Dictionary(
                    rig.joints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for joint in rig.joints {
                    try transform(joint.restTransform)
                    try transform(joint.bindTransform ?? joint.restTransform)
                    if let mirror = joint.mirroredJointID {
                        try require(
                            joints[mirror]?.mirroredJointID == joint.id, "rig.mirrorPair",
                            "Mirrored joints must reference each other.")
                    }
                    if let limits = joint.rotationLimits {
                        try require(
                            limits.minimumRadians.isFinite && limits.maximumRadians.isFinite
                                && (0..<3).allSatisfy { limits.minimumRadians[$0] <= limits.maximumRadians[$0] },
                            "rig.rotationLimits", "Rotation limits must be finite and ordered.")
                    }
                    if !rig.constraints.isEmpty {
                        try require(
                            joint.restTransform.scale == .one, "rig.constraintScale",
                            "Constraint solvers require unit joint scales.")
                    }
                }
                for constraint in rig.constraints {
                    try constraint.validate(in: rig)
                    try require(
                        constraintIDs.insert(constraint.id).inserted, "rig.constraintID",
                        "Constraint identifiers must be unique.")
                }
            }
        }
        var physicalOwners: Set<HierarchyNodeReference> = []
        for collision in collisions {
            check("collisions.\(collision.id.rawValue)") {
                try transform(collision.transform)
                if case .convex(let points) = collision.shape {
                    _ = try MeshBuilder.convexHull(points: points)
                }
                if let physics = collision.physics {
                    try require(
                        !collision.isTrigger && collision.transform.scale == .one
                            && physicalOwners.insert(collision.parent).inserted,
                        "physics.ownership",
                        "Each physics owner requires one non-trigger collider with an unscaled local offset.")
                    try require(
                        physics.mass.isFinite && physics.mass > 0 && physics.friction.isFinite
                            && physics.friction >= 0
                            && physics.restitution.isFinite && (0...1).contains(physics.restitution),
                        "physics.material",
                        "Physics mass must be positive, friction nonnegative, and restitution in [0, 1].")
                    if physics.mode == .dynamic {
                        let target: AnimationTarget
                        switch collision.parent {
                        case .part(let id): target = .part(id)
                        case .joint(let id): target = .joint(id)
                        }
                        try require(
                            !clips.contains { $0.channels.contains { $0.target == target } },
                            "physics.animationConflict",
                            "Dynamic physics owners cannot also have transform animation channels.")
                        if case .joint = target {
                            throw modelingError(
                                "physics.dynamicJoint",
                                "Dynamic physics is supported on parts; driven rig joints require explicit gameplay coordination."
                            )
                        }
                    }
                }
            }
        }
        for clip in clips {
            check("clips.\(clip.id.rawValue)") {
                try clip.validate()
                if let signature = clip.rigSignature {
                    try require(
                        signature == rig?.signature, "clip.rigSignature",
                        "Clip rig signature does not match the asset rig.")
                }
                for channel in clip.channels {
                    for key in channel.keyframes {
                        try transform(key.transform)
                        if case .joint = channel.target, rig?.constraints.isEmpty == false {
                            try require(
                                key.transform.scale == .one, "clip.constraintScale",
                                "Constrained joint animation must use unit scales.")
                        }
                    }
                }
                if let root = clip.rootMotionTarget {
                    try require(
                        clip.channels.contains { $0.target == root }, "clip.rootChannel",
                        "Root motion requires a transform channel.")
                    switch root {
                    case .part(let id):
                        try require(
                            parts.first { $0.id == id }?.parent == nil, "clip.rootParent",
                            "Root motion must target a hierarchy root.")
                    case .joint(let id):
                        try require(
                            rig?.joints.first { $0.id == id }?.parentID == nil, "clip.rootParent",
                            "Root motion must target a hierarchy root.")
                    }
                    _ = try clip.rootMotion(from: 0, to: clip.duration)
                }
                var scalarTargets: Set<ScalarAnimationTarget> = []
                for channel in clip.scalarChannels {
                    try require(
                        scalarTargets.insert(channel.target).inserted && !channel.keyframes.isEmpty,
                        "clip.scalarChannel", "Scalar channels must be nonempty and unique per target.")
                    var unitRange = true
                    switch channel.target {
                    case .morph(let part, let target):
                        try require(
                            parts.first { $0.id == part }?.geometry.morphTargets.contains { $0.id == target }
                                == true,
                            "clip.morphTarget", "Scalar channel references a missing morph target.")
                    case .material(let id, let property):
                        guard let material = materials.first(where: { $0.id == id }) else {
                            throw modelingError(
                                "clip.materialTarget", "Scalar channel references a missing material.")
                        }
                        try require(
                            material.shading == .lit || property == .opacity, "clip.unlitProperty",
                            "Only opacity can be animated on an unlit material.")
                        try require(
                            property != .opacity || material.alphaMode != .opaque,
                            "clip.opaqueMaterial", "Opacity animation requires a blend or mask material.")
                        unitRange = property != .emissiveIntensity
                    }
                    for i in channel.keyframes.indices {
                        let key = channel.keyframes[i]
                        try require(
                            key.time.isFinite && key.time >= 0 && key.time <= clip.duration
                                && (i == 0 || key.time > channel.keyframes[i - 1].time)
                                && key.value.isFinite && key.value >= 0 && (!unitRange || key.value <= 1),
                            "clip.scalarKeyframe",
                            "Scalar keyframes need ordered in-range times and values within the target's range.")
                    }
                }
            }
        }
        if let graph = animationGraph {
            check("animationGraph") {
                try graph.validate(clips: clips)
                let parameters = Dictionary(
                    graph.parameters.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
                let clipIDs = Set(clips.map(\.id))
                func scalar(_ id: AnyRealitizerID) -> Bool {
                    if case .scalar? = parameters[id] { true } else { false }
                }
                for parameter in graph.parameters {
                    if case .scalar(let value) = parameter.kind {
                        try require(value.isFinite, "graph.scalarDefault", "Scalar defaults must be finite.")
                    }
                }
                for state in graph.states {
                    if let space = state.blendSpace {
                        _ = try space.weights(at: .zero)
                        try require(
                            scalar(space.xParameter) && (space.yParameter.map(scalar) ?? true)
                                && space.samples.allSatisfy { clipIDs.contains($0.clipID) },
                            "graph.blendSpace",
                            "Blend spaces require declared scalar parameters and existing clips.")
                    }
                }
                var layerIDs: Set<AnyRealitizerID> = []
                for layer in graph.layers {
                    try require(
                        layerIDs.insert(layer.id).inserted && clipIDs.contains(layer.clipID)
                            && layer.weight.isFinite
                            && (0...1).contains(layer.weight)
                            && layer.speed.isFinite && layer.speed >= 0
                            && (layer.weightParameter.map(scalar) ?? true),
                        "graph.layer",
                        "Layers require unique IDs, existing clips, valid weights/speeds and scalar weight parameters."
                    )
                    for (target, weight) in layer.mask.weights {
                        try require(
                            targets.contains(target) && weight.isFinite && (0...1).contains(weight), "graph.mask",
                            "Masks require existing targets and weights in [0, 1].")
                    }
                    if let reference = layer.referencePose { try pose(reference) }
                    for (target, weight) in layer.scalarWeights {
                        try require(
                            referenceScalarValues[target] != nil && weight.isFinite && (0...1).contains(weight),
                            "graph.scalarMask", "Scalar masks require existing targets and weights in [0, 1].")
                    }
                }
                for transition in graph.transitions {
                    for condition in transition.conditions {
                        switch condition {
                        case .scalarGreaterThan(_, let threshold), .scalarLessThan(_, let threshold):
                            try require(
                                threshold.isFinite, "graph.threshold", "Transition thresholds must be finite.")
                        default: break
                        }
                    }
                }
            }
        }
        return result
    }
}
