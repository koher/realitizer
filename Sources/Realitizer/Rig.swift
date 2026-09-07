/// A reference to a transform-bearing node in a generated model hierarchy.
public enum HierarchyNodeReference: Hashable, Sendable {
    case part(AnyRealitizerID)
    case joint(AnyRealitizerID)

    public static func part<ID: RealitizerID>(id: ID) -> Self {
        .part(id.erasedID)
    }

    public static func joint<ID: RealitizerID>(id: ID) -> Self {
        .joint(id.erasedID)
    }

    public var id: AnyRealitizerID {
        switch self {
        case .part(let id), .joint(let id):
            id
        }
    }
}

/// Optional limits applied by authoring tools and animation evaluators.
public struct JointRotationLimits: Equatable, Sendable {
    public var minimumRadians: SIMD3<Float>
    public var maximumRadians: SIMD3<Float>

    public init(minimumRadians: SIMD3<Float>, maximumRadians: SIMD3<Float>) {
        self.minimumRadians = minimumRadians
        self.maximumRadians = maximumRadians
    }
}

/// One joint in a portable rigid or skeletal rig.
public struct JointDefinition: Sendable {
    public let id: AnyRealitizerID
    public var parentID: AnyRealitizerID?
    public var restTransform: ModelTransform
    /// Defaults to the rest transform. Stored separately to keep binding independent of animation.
    public var bindTransform: ModelTransform? = nil
    public var rotationLimits: JointRotationLimits?
    public var semanticRole: String?
    public var mirroredJointID: AnyRealitizerID?

    public init<ID: RealitizerID>(
        id: ID,
        parent: AnyRealitizerID? = nil,
        restTransform: ModelTransform = .identity,
        rotationLimits: JointRotationLimits? = nil,
        semanticRole: String? = nil,
        mirroredJoint: AnyRealitizerID? = nil
    ) {
        self.id = id.erasedID
        parentID = parent
        self.restTransform = restTransform
        self.rotationLimits = rotationLimits
        self.semanticRole = semanticRole
        mirroredJointID = mirroredJoint
    }

    public init<ID: RealitizerID, ParentID: RealitizerID>(
        id: ID,
        parent: ParentID,
        restTransform: ModelTransform = .identity,
        rotationLimits: JointRotationLimits? = nil,
        semanticRole: String? = nil
    ) {
        self.id = id.erasedID
        parentID = parent.erasedID
        self.restTransform = restTransform
        self.rotationLimits = rotationLimits
        self.semanticRole = semanticRole
        mirroredJointID = nil
    }
}

/// A named hierarchy shared by poses and animation clips.
public struct RigDefinition: Sendable {
    public let id: AnyRealitizerID
    public var version: Int
    public var joints: [JointDefinition]
    public var constraints: [RigConstraint] = []

    public init<ID: RealitizerID>(id: ID, version: Int = 1, joints: [JointDefinition]) {
        self.id = id.erasedID
        self.version = version
        self.joints = joints
    }

    public var signature: RigSignature {
        let ordered = joints.sorted { $0.id.rawValue < $1.id.rawValue }
        return RigSignature(
            rigID: id,
            version: version,
            jointIDs: ordered.map(\.id),
            parentIDs: ordered.map(\.parentID)
        )
    }
}

/// A deterministic compatibility signature for animation data.
public struct RigSignature: Equatable, Sendable {
    public let rigID: AnyRealitizerID
    public let version: Int
    public let jointIDs: [AnyRealitizerID]
    public let parentIDs: [AnyRealitizerID?]

    public init(
        rigID: AnyRealitizerID,
        version: Int,
        jointIDs: [AnyRealitizerID],
        parentIDs: [AnyRealitizerID?]
    ) {
        self.rigID = rigID
        self.version = version
        self.jointIDs = jointIDs
        self.parentIDs = parentIDs
    }
}

/// A semantic attachment point for equipment, effects, cameras, or audio.
public struct SocketDefinition: Sendable {
    public let id: AnyRealitizerID
    public var parent: HierarchyNodeReference
    public var transform: ModelTransform
    public var purpose: String?

    public init<ID: RealitizerID>(
        id: ID,
        parent: HierarchyNodeReference,
        transform: ModelTransform = .identity,
        purpose: String? = nil
    ) {
        self.id = id.erasedID
        self.parent = parent
        self.transform = transform
        self.purpose = purpose
    }
}
