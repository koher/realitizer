import Foundation
import simd

public enum AnimatedMaterialProperty: String, Sendable, Codable { case roughness, metallic, emissiveIntensity, opacity }
public enum ScalarAnimationTarget: Hashable, Sendable {
    case morph(part: AnyRealitizerID, target: AnyRealitizerID)
    case material(AnyRealitizerID, AnimatedMaterialProperty)
}
public struct ScalarKeyframe: Equatable, Sendable {
    public var time: Float
    public var value: Float
    public init(time: Float, value: Float) {
        self.time = time
        self.value = value
    }
}
public struct ScalarAnimationChannel: Sendable {
    public var target: ScalarAnimationTarget
    public var keyframes: [ScalarKeyframe]
    public var interpolation: TransformInterpolation
    public init(
        target: ScalarAnimationTarget, keyframes: [ScalarKeyframe], interpolation: TransformInterpolation = .linear
    ) {
        self.target = target
        self.keyframes = keyframes
        self.interpolation = interpolation
    }
    public func sample(at time: Float) -> Float? {
        guard let first = keyframes.first else { return nil }
        if time <= first.time { return first.value }
        for i in 1..<keyframes.count where time <= keyframes[i].time {
            let a = keyframes[i - 1]
            let b = keyframes[i]
            let span = b.time - a.time
            var t = span > 0 ? (time - a.time) / span : 1
            switch interpolation {
            case .step: t = 0
            case .linear: break
            case .smoothStep: t = t * t * (3 - 2 * t)
            }
            return a.value + (b.value - a.value) * t
        }
        return keyframes.last?.value
    }
}

public struct PoseKeyframe: Sendable {
    public var time: Float
    public var pose: PoseDefinition
    public init(time: Float, pose: PoseDefinition) {
        self.time = time
        self.pose = pose
    }
}

public struct BoneMask: Sendable {
    public var weights: [AnimationTarget: Float]
    public init(weights: [AnimationTarget: Float]) { self.weights = weights }
    public static func subtree<ID: RealitizerID>(root: ID, rig: RigDefinition, weight: Float = 1) throws -> Self {
        let skeleton = try rig.resolvedSkeleton()
        guard skeleton.joints.contains(where: { $0.id == root.erasedID }) else {
            throw modelingError("mask.root", "Mask root is not in the rig.")
        }
        var included: Set<AnyRealitizerID> = [root.erasedID]
        for joint in skeleton.joints where joint.parentID.map(included.contains) ?? false { included.insert(joint.id) }
        return Self(weights: Dictionary(uniqueKeysWithValues: included.map { (AnimationTarget.joint($0), weight) }))
    }
}

public enum PoseBlendMode: String, Sendable { case override, additive }

extension PoseDefinition {
    public func blended(
        with other: PoseDefinition, weight: Float, mask: BoneMask? = nil, mode: PoseBlendMode = .override,
        reference: PoseDefinition? = nil
    ) throws -> Self {
        guard weight.isFinite, (0...1).contains(weight),
            mask?.weights.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) ?? true
        else {
            throw modelingError("pose.blendWeight", "Pose and mask weights must be finite values in [0, 1].")
        }
        var result = self
        for (target, value) in other.transforms {
            let amount = weight * (mask.map { $0.weights[target] ?? 0 } ?? 1)
            let base = result.transforms[target] ?? .identity
            switch mode {
            case .override: result.transforms[target] = base.interpolated(to: value, progress: amount)
            case .additive:
                let rest = reference?.transforms[target] ?? .identity
                guard rest.scale.x != 0, rest.scale.y != 0, rest.scale.z != 0 else {
                    throw modelingError("pose.additiveScale", "Additive reference scale must be invertible.")
                }
                let deltaRotation = rest.rotation.inverse * value.rotation
                result.transforms[target] = ModelTransform(
                    scale: base.scale * simd_mix(.one, value.scale / rest.scale, SIMD3(repeating: amount)),
                    rotation: base.rotation * simd_slerp(simd_quatf(angle: 0, axis: [0, 1, 0]), deltaRotation, amount),
                    translation: base.translation + (value.translation - rest.translation) * amount)
            }
        }
        return result
    }

    /// Mirrors a pose across a coordinate plane and swaps the rig's explicitly paired joints.
    public func mirrored(rig: RigDefinition, axis: ModelingAxis = .x) throws -> Self {
        _ = try rig.resolvedSkeleton()
        var result = self
        result.transforms = [:]
        var scale = SIMD3<Float>.one
        scale[axis.rawValue] = -1
        for (target, transform) in transforms {
            let destination: AnimationTarget
            if case .joint(let id) = target, let partner = rig.joints.first(where: { $0.id == id })?.mirroredJointID {
                destination = .joint(partner)
            } else {
                destination = target
            }
            let q = transform.rotation.vector
            let v = SIMD3(q.x, q.y, q.z) * (-scale)
            result.transforms[destination] = ModelTransform(
                scale: transform.scale, rotation: simd_quatf(vector: SIMD4(v, q.w)),
                translation: transform.translation * scale)
        }
        return result
    }
}

extension AnimationClipDefinition {
    /// Authors complete named poses rather than manually constructing a channel for every target.
    public static func keyPoses<ID: RealitizerID>(
        id: ID, duration: Float, frames: [PoseKeyframe], reference: PoseDefinition,
        loopMode: AnimationLoopMode = .once, interpolation: TransformInterpolation = .smoothStep,
        events: [AnimationEventDefinition] = []
    ) throws -> Self {
        guard duration.isFinite, duration > 0, !frames.isEmpty else {
            throw modelingError("clip.keyPoses", "Pose clips require a positive duration and at least one pose.")
        }
        for i in frames.indices {
            guard frames[i].time.isFinite, (0...duration).contains(frames[i].time),
                i == 0 || frames[i].time > frames[i - 1].time
            else {
                throw modelingError("clip.poseTimes", "Pose times must be strictly increasing and within the clip.")
            }
        }
        var targets = Set(reference.transforms.keys)
        for frame in frames { targets.formUnion(frame.pose.transforms.keys) }
        // Sort by target kind as well as ID; dictionary iteration must never change emitted channels.
        let sorted = targets.sorted { targetSortKey($0) < targetSortKey($1) }
        let channels = sorted.map { target in
            TransformAnimationChannel(
                target: target,
                keyframes: frames.map { frame in
                    TransformKeyframe(
                        time: frame.time,
                        transform: frame.pose.transforms[target] ?? reference.transforms[target] ?? .identity)
                }, interpolation: interpolation)
        }
        return Self(id: id, duration: duration, loopMode: loopMode, channels: channels, events: events)
    }

    /// Bakes a procedural pose function on an explicit, deterministic sample grid including both endpoints.
    public static func bake<ID: RealitizerID>(
        id: ID, duration: Float, sampleRate: Float = 30, reference: PoseDefinition,
        loopMode: AnimationLoopMode = .once, pose: (Float) throws -> PoseDefinition
    ) throws -> Self {
        guard duration.isFinite, duration > 0, sampleRate.isFinite, sampleRate > 0, duration * sampleRate <= 100_000
        else {
            throw modelingError(
                "clip.bakeBudget", "Baked clips require a positive duration/rate and at most 100000 samples.")
        }
        let steps = max(1, Int(ceil(duration * sampleRate)))
        let frames = try (0...steps).map { i -> PoseKeyframe in
            let time = duration * Float(i) / Float(steps)
            return try PoseKeyframe(time: time, pose: pose(time))
        }
        return try keyPoses(
            id: id, duration: duration, frames: frames, reference: reference, loopMode: loopMode, interpolation: .linear
        )
    }

    /// Extracts cumulative root-local translation and rotation, including whole loop cycles.
    public func rootMotion(from start: Float, to end: Float) throws -> ModelTransform {
        guard start.isFinite, end.isFinite else {
            throw modelingError("animation.rootTime", "Root motion times must be finite.")
        }
        guard let target = rootMotionTarget, let channel = channels.first(where: { $0.target == target }), duration > 0
        else { return .identity }
        guard duration.isFinite,
            channel.keyframes.allSatisfy({
                $0.transform.scale == .one && $0.transform.isFinite
                    && abs(simd_length($0.transform.rotation.vector) - 1) < 0.001
            }),
            max(start, end) / duration < Float(Int32.max)
        else {
            throw modelingError(
                "animation.rootDomain", "Root motion requires rigid transforms and fewer than 2147483647 cycles.")
        }
        let origin = (channel.sample(at: 0) ?? .identity).matrix
        func accumulated(_ time: Float) -> simd_float4x4 {
            if loopMode == .once {
                return simd_inverse(origin) * (channel.sample(at: min(max(time, 0), duration)) ?? .identity).matrix
            }
            let positive = max(time, 0)
            let cycles = Int(floor(positive / duration))
            var power = simd_inverse(origin) * (channel.sample(at: duration) ?? .identity).matrix
            var count = cycles
            var repeated = matrix_identity_float4x4
            while count > 0 {
                if count & 1 == 1 { repeated *= power }
                power *= power
                count >>= 1
            }
            let local = positive.truncatingRemainder(dividingBy: duration)
            return repeated * simd_inverse(origin) * (channel.sample(at: local) ?? .identity).matrix
        }
        let delta = simd_inverse(accumulated(start)) * accumulated(end)
        guard delta.finite else {
            throw modelingError("animation.rootOverflow", "Root motion accumulation exceeded finite transform limits.")
        }
        let rotation = simd_quatf(delta)
        return ModelTransform(rotation: rotation.normalized, translation: delta.point(.zero))
    }
}

func targetSortKey(_ target: AnimationTarget) -> String {
    switch target {
    case .part(let id): "part:\(id.rawValue)"
    case .joint(let id): "joint:\(id.rawValue)"
    }
}
