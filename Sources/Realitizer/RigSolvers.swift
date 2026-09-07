import simd

public struct IKSolveReport: Equatable, Sendable {
    public let constraintID: AnyRealitizerID
    public let remainingDistance: Float
    public let iterations: Int
    public let reached: Bool
}
public struct RigSolveResult: Sendable {
    public let pose: PoseDefinition
    public let inverseKinematics: [IKSolveReport]
}

public enum RigSolver {
    public static func solve(
        rig: RigDefinition, pose: PoseDefinition, targets: [AnyRealitizerID: RigConstraintTarget]
    ) throws
        -> RigSolveResult
    {
        let skeleton = try rig.resolvedSkeleton()
        guard Set(rig.constraints.map(\.id)).count == rig.constraints.count,
            targets.keys.allSatisfy({ id in rig.constraints.contains { $0.id == id } })
        else {
            throw modelingError(
                "constraint.identifiers",
                "Constraints must have unique IDs and all targets must reference a constraint.")
        }
        for constraint in rig.constraints {
            try constraint.validate(in: rig)
            try targets[constraint.id]?.validate(for: constraint)
        }
        let lookup = Dictionary(
            uniqueKeysWithValues: skeleton.joints.enumerated().map { ($0.element.id, $0.offset) })
        var result = pose
        for joint in skeleton.joints where result.transforms[.joint(joint.id)] == nil {
            result.transforms[.joint(joint.id)] = joint.restTransform
        }
        var reports: [IKSolveReport] = []
        func constrained(_ rotation: simd_quatf, joint: JointDefinition) throws -> simd_quatf {
            guard let limits = joint.rotationLimits else { return rotation.normalized }
            guard limits.minimumRadians.isFinite, limits.maximumRadians.isFinite,
                (0..<3).allSatisfy({ limits.minimumRadians[$0] <= limits.maximumRadians[$0] })
            else {
                throw modelingError(
                    "rig.rotationLimits", "Joint rotation limits must be finite and ordered.")
            }
            let q = rotation.normalized.vector
            let x = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
            let y = asin(min(max(2 * (q.w * q.y - q.z * q.x), -1), 1))
            let z = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
            let e = simd_min(simd_max(SIMD3(x, y, z), limits.minimumRadians), limits.maximumRadians)
            return simd_quatf(angle: e.z, axis: [0, 0, 1]) * simd_quatf(angle: e.y, axis: [0, 1, 0])
                * simd_quatf(angle: e.x, axis: [1, 0, 0])
        }
        for joint in skeleton.joints {
            var value = result.transforms[.joint(joint.id)]!
            guard value.isFinite, abs(simd_length(value.rotation.vector) - 1) < 0.001,
                rig.constraints.isEmpty || value.scale == .one
            else {
                throw modelingError(
                    "rig.poseDomain",
                    "Constraint poses require finite transforms, unit quaternions and unit scales.")
            }
            value.rotation = try constrained(value.rotation, joint: joint)
            result.transforms[.joint(joint.id)] = value
        }
        for constraint in rig.constraints {
            // Omitted targets leave a constraint inactive, with no inferred rest or world-space target.
            guard let input = targets[constraint.id] else { continue }
            switch constraint {
            case .lookAt(let definition):
                let jointID = definition.joint
                let axis = definition.localAxis
                let weight = definition.weight
                let target = input.position
                guard let index = lookup[jointID], target.isFinite,
                    axis.isFinite, simd_length_squared(axis) > 1e-12, weight.isFinite,
                    (0...1).contains(weight)
                else {
                    throw modelingError(
                        "lookAt.input",
                        "Look-at requires an existing joint, a finite target, a nonzero axis and weight in [0, 1]."
                    )
                }
                let globals = try skeleton.globalMatrices(pose: result)
                let origin = globals[index].point(.zero)
                if simd_distance_squared(origin, target) < 1e-12 { continue }
                let worldRotation = simd_quatf(globals[index]).normalized
                let delta = simd_quatf(
                    from: unitVector(worldRotation.act(axis)), to: unitVector(target - origin))
                let parentRotation =
                    skeleton.parentIndices[index].map { simd_quatf(globals[$0]).normalized }
                    ?? simd_quatf(angle: 0, axis: [0, 1, 0])
                let desired = parentRotation.inverse * delta * worldRotation
                var local = result.transforms[.joint(jointID)]!
                local.rotation = try constrained(
                    simd_slerp(local.rotation, desired, weight), joint: skeleton.joints[index])
                result.transforms[.joint(jointID)] = local
            case .inverseKinematics(let definition):
                let id = definition.id
                let chain = definition.chain
                let maximumIterations = definition.iterations
                let tolerance = definition.tolerance
                let target = input.position
                guard chain.count >= 2, Set(chain).count == chain.count,
                    chain.allSatisfy({ lookup[$0] != nil }),
                    (1...128).contains(maximumIterations), tolerance.isFinite, tolerance > 0,
                    target.isFinite
                else {
                    throw modelingError(
                        "ik.input",
                        "IK requires a valid chain, a finite target, 1...128 iterations and a positive tolerance."
                    )
                }
                let indices = chain.map { lookup[$0]! }
                for i in 1..<indices.count where skeleton.parentIndices[indices[i]] != indices[i - 1] {
                    throw modelingError("ik.chain", "IK chains must contain directly connected joints.")
                }
                let end = indices.last!
                var residual = Float.infinity
                var iterations = 0
                for iteration in 0..<maximumIterations {
                    var globals = try skeleton.globalMatrices(pose: result)
                    residual = simd_distance(globals[end].point(.zero), target)
                    if residual <= tolerance { break }
                    iterations = iteration + 1
                    for index in indices.dropLast().reversed() {
                        globals = try skeleton.globalMatrices(pose: result)
                        let origin = globals[index].point(.zero)
                        let current = globals[end].point(.zero) - origin
                        let desired = target - origin
                        if simd_length_squared(current) < 1e-12 || simd_length_squared(desired) < 1e-12 {
                            continue
                        }
                        let delta = simd_quatf(from: unitVector(current), to: unitVector(desired))
                        let parentRotation =
                            skeleton.parentIndices[index].map { simd_quatf(globals[$0]).normalized }
                            ?? simd_quatf(angle: 0, axis: [0, 1, 0])
                        let joint = skeleton.joints[index]
                        var local = result.transforms[.joint(joint.id)]!
                        local.rotation = try constrained(
                            parentRotation.inverse * delta * parentRotation * local.rotation, joint: joint)
                        result.transforms[.joint(joint.id)] = local
                    }
                }
                residual = try simd_distance(
                    skeleton.globalMatrices(pose: result)[end].point(.zero), target)
                reports.append(
                    IKSolveReport(
                        constraintID: id, remainingDistance: residual, iterations: iterations,
                        reached: residual <= tolerance))
            case .twoBoneIK(let definition):
                let root = lookup[definition.root]!
                let middle = lookup[definition.middle]!
                let tip = lookup[definition.tip]!
                let globals = try skeleton.globalMatrices(pose: result)
                let a = globals[root].point(.zero)
                let b = globals[middle].point(.zero)
                let c = globals[tip].point(.zero)
                let upper = simd_distance(a, b)
                let lower = simd_distance(b, c)
                guard upper > 1e-6, lower > 1e-6 else {
                    throw modelingError("ik.boneLength", "Two-bone IK requires two nonzero bone lengths.")
                }
                let target = input.position
                let direction = unitVector(
                    target - a, fallback: unitVector(c - a, fallback: unitVector(b - a)))
                let rawPole = input.polePosition! - a
                let projectedPole = rawPole - direction * simd_dot(rawPole, direction)
                guard simd_length_squared(projectedPole) > 1e-12 else {
                    throw modelingError("ik.poleAxis", "The pole must lie outside the root-to-target axis.")
                }
                let distance = min(
                    max(simd_distance(a, target), max(abs(upper - lower), 1e-6)), upper + lower)
                let along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
                let height = sqrt(max(0, upper * upper - along * along))
                let desiredMiddle = a + direction * along + unitVector(projectedPole) * height
                let desiredTip = a + direction * distance
                for (jointIndex, childIndex, desired) in [
                    (root, middle, desiredMiddle), (middle, tip, desiredTip),
                ] {
                    let current = try skeleton.globalMatrices(pose: result)
                    let origin = current[jointIndex].point(.zero)
                    let from = current[childIndex].point(.zero) - origin
                    let to = desired - origin
                    if simd_length_squared(to) < 1e-14 { continue }
                    let delta = simd_quatf(from: unitVector(from), to: unitVector(to))
                    let parent =
                        skeleton.parentIndices[jointIndex].map { simd_quatf(current[$0]).normalized }
                        ?? simd_quatf(angle: 0, axis: [0, 1, 0])
                    let joint = skeleton.joints[jointIndex]
                    var local = result.transforms[.joint(joint.id)]!
                    local.rotation = try constrained(
                        parent.inverse * delta * parent * local.rotation, joint: joint)
                    result.transforms[.joint(joint.id)] = local
                }
                let residual = try simd_distance(
                    skeleton.globalMatrices(pose: result)[tip].point(.zero), target)
                reports.append(
                    IKSolveReport(
                        constraintID: definition.id, remainingDistance: residual,
                        iterations: 1, reached: residual <= definition.tolerance))
            }
        }
        return RigSolveResult(pose: result, inverseKinematics: reports)
    }
}

public struct RetargetJoint: Sendable {
    public var source: AnyRealitizerID
    public var destination: AnyRealitizerID
    public var axisCorrection: simd_quatf
    public var translationScale: Float
    public init<Source: RealitizerID, Destination: RealitizerID>(
        source: Source, destination: Destination,
        axisCorrection: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), translationScale: Float = 1
    ) {
        self.source = source.erasedID
        self.destination = destination.erasedID
        self.axisCorrection = axisCorrection
        self.translationScale = translationScale
    }
}
public struct RetargetMap: Sendable {
    public var joints: [RetargetJoint]
    public init(joints: [RetargetJoint]) { self.joints = joints }
    public func apply(
        _ pose: PoseDefinition, from source: RigDefinition, to destination: RigDefinition
    ) throws
        -> PoseDefinition
    {
        _ = try source.resolvedSkeleton()
        _ = try destination.resolvedSkeleton()
        guard Set(joints.map(\.destination)).count == joints.count else {
            throw modelingError("retarget.duplicate", "Each destination joint may be mapped only once.")
        }
        var result = PoseDefinition(
            id: pose.id,
            transforms: Dictionary(
                uniqueKeysWithValues: destination.joints.map { (.joint($0.id), $0.restTransform) }))
        for mapping in joints {
            guard let src = source.joints.first(where: { $0.id == mapping.source }),
                let dst = destination.joints.first(where: { $0.id == mapping.destination }),
                mapping.translationScale.isFinite, mapping.translationScale > 0,
                mapping.axisCorrection.vector.isFinite,
                abs(simd_length(mapping.axisCorrection.vector) - 1) < 0.001
            else {
                throw modelingError(
                    "retarget.mapping",
                    "Retarget joints must exist with a positive scale and a unit axis correction.")
            }
            let input = pose.transforms[.joint(src.id)] ?? src.restTransform
            let correction = mapping.axisCorrection
            let delta = src.restTransform.rotation.inverse * input.rotation
            result.transforms[.joint(dst.id)] = ModelTransform(
                scale: dst.restTransform.scale,
                rotation: dst.restTransform.rotation * correction * delta * correction.inverse,
                translation: dst.restTransform.translation + correction.act(
                    input.translation - src.restTransform.translation) * mapping.translationScale)
        }
        return result
    }
}

/// Closed-form critically damped secondary motion. No variable-step integration instability.
public struct SpringMotion: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public init(position: SIMD3<Float> = .zero, velocity: SIMD3<Float> = .zero) {
        self.position = position
        self.velocity = velocity
    }
    public mutating func advance(towards target: SIMD3<Float>, frequency: Float, deltaTime: Float)
        throws
    {
        guard target.isFinite, position.isFinite, velocity.isFinite, frequency.isFinite, frequency > 0,
            deltaTime.isFinite, deltaTime >= 0
        else {
            throw modelingError(
                "spring.input", "Spring inputs must be finite with positive frequency and nonnegative time."
            )
        }
        let omega = 2 * Float.pi * frequency
        let offset = position - target
        let decay = exp(-omega * deltaTime)
        let impulse = velocity + omega * offset
        position = target + (offset + impulse * deltaTime) * decay
        velocity = (velocity - omega * impulse * deltaTime) * decay
    }
}
