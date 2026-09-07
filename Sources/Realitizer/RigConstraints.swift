import simd

public struct InverseKinematicsConstraint: Sendable {
    public let id: AnyRealitizerID
    public var chain: [AnyRealitizerID]
    public var iterations: Int
    public var tolerance: Float
    public init<ID: RealitizerID>(
        id: ID, chain: [AnyRealitizerID], iterations: Int = 32, tolerance: Float = 0.001
    ) {
        self.id = id.erasedID
        self.chain = chain
        self.iterations = iterations
        self.tolerance = tolerance
    }
}

public struct LookAtConstraint: Sendable {
    public let id: AnyRealitizerID
    public var joint: AnyRealitizerID
    public var localAxis: SIMD3<Float>
    public var weight: Float
    public init<ID: RealitizerID, Joint: RealitizerID>(
        id: ID, joint: Joint, localAxis: SIMD3<Float> = [0, 0, 1], weight: Float = 1
    ) {
        self.id = id.erasedID
        self.joint = joint.erasedID
        self.localAxis = localAxis
        self.weight = weight
    }
}

/// A three-joint chain with two fixed-length bones. The runtime target supplies the bend-plane pole.
public struct TwoBoneIKConstraint: Sendable {
    public let id: AnyRealitizerID
    public var root: AnyRealitizerID
    public var middle: AnyRealitizerID
    public var tip: AnyRealitizerID
    public var tolerance: Float
    public init<ID: RealitizerID, Joint: RealitizerID>(
        id: ID, root: Joint, middle: Joint, tip: Joint, tolerance: Float = 0.001
    ) {
        self.id = id.erasedID
        self.root = root.erasedID
        self.middle = middle.erasedID
        self.tip = tip.erasedID
        self.tolerance = tolerance
    }
}

public enum RigConstraint: Sendable {
    case inverseKinematics(InverseKinematicsConstraint)
    case lookAt(LookAtConstraint)
    case twoBoneIK(TwoBoneIKConstraint)

    public var id: AnyRealitizerID {
        switch self {
        case .inverseKinematics(let definition): definition.id
        case .lookAt(let definition): definition.id
        case .twoBoneIK(let definition): definition.id
        }
    }

    public func validate(in rig: RigDefinition) throws {
        let joints = Dictionary(rig.joints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func chain(_ ids: [AnyRealitizerID], tolerance: Float) throws {
            guard ids.count >= 2, Set(ids).count == ids.count, ids.allSatisfy({ joints[$0] != nil }),
                tolerance.isFinite, tolerance > 0,
                (1..<ids.count).allSatisfy({ joints[ids[$0]]?.parentID == ids[$0 - 1] })
            else {
                throw modelingError(
                    "ik.chain",
                    "IK requires distinct directly connected joints and a positive finite tolerance.")
            }
        }
        switch self {
        case .inverseKinematics(let value):
            try chain(value.chain, tolerance: value.tolerance)
            guard (1...128).contains(value.iterations) else {
                throw modelingError("ik.iterations", "IK iteration count must be in 1...128.")
            }
        case .lookAt(let value):
            guard joints[value.joint] != nil, value.localAxis.isFinite,
                simd_length_squared(value.localAxis) > 1e-12,
                value.weight.isFinite, (0...1).contains(value.weight)
            else {
                throw modelingError(
                    "lookAt.definition",
                    "Look-at requires a joint, a nonzero finite axis, and weight in [0, 1].")
            }
        case .twoBoneIK(let value):
            try chain([value.root, value.middle, value.tip], tolerance: value.tolerance)
        }
    }
}

/// All positions use rig space. A target can be supplied by gameplay queries or a deterministic preview.
public struct RigConstraintTarget: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var polePosition: SIMD3<Float>?
    public init(position: SIMD3<Float>, polePosition: SIMD3<Float>? = nil) {
        self.position = position
        self.polePosition = polePosition
    }
    public func validate(for constraint: RigConstraint) throws {
        guard position.isFinite, polePosition?.isFinite ?? true else {
            throw modelingError("constraint.target", "Constraint target positions must be finite.")
        }
        if case .twoBoneIK = constraint {
            guard polePosition != nil else {
                throw modelingError("ik.pole", "Two-bone IK requires an explicit rig-space pole position.")
            }
        } else if polePosition != nil {
            throw modelingError("constraint.unusedPole", "Only two-bone IK consumes a pole position.")
        }
    }
}
