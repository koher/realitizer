import simd

/// A semantic joint influence. Vertex weights are normalized explicitly at binding time.
public struct JointWeight: Equatable, Sendable, Codable {
    public var jointID: AnyRealitizerID
    public var weight: Float
    public init<ID: RealitizerID>(_ joint: ID, weight: Float) {
        jointID = joint.erasedID
        self.weight = weight
    }
}

public struct SkinBinding: Equatable, Sendable, Codable {
    public var influences: [[JointWeight]]
    public var maximumInfluences: Int
    public init(influences: [[JointWeight]], maximumInfluences: Int = 4) {
        self.influences = influences
        self.maximumInfluences = maximumInfluences
    }

    public func validate(vertexCount: Int, rig: RigDefinition) throws {
        try validateWeights(vertexCount: vertexCount)
        let joints = Set(rig.joints.map(\.id))
        guard influences.allSatisfy({ $0.allSatisfy { joints.contains($0.jointID) } }) else {
            throw modelingError("skin.joint", "Skin weights must reference joints in the supplied rig.")
        }
    }

    public func validateWeights(vertexCount: Int) throws {
        guard influences.count == vertexCount, (1...8).contains(maximumInfluences) else {
            throw modelingError(
                "skin.count",
                "Skin binding requires one influence list per vertex and between one and eight influences per vertex.",
                path: "skin")
        }
        for (i, weights) in influences.enumerated() {
            guard !weights.isEmpty, weights.count <= maximumInfluences,
                Set(weights.map(\.jointID)).count == weights.count,
                weights.allSatisfy({ $0.weight.isFinite && $0.weight >= 0 }),
                abs(weights.reduce(0) { $0 + $1.weight } - 1) < 0.0001
            else {
                throw modelingError(
                    "skin.weights",
                    "Weights must reference distinct existing joints, be nonnegative, and sum to one.",
                    path: "skin.vertices[\(i)]")
            }
        }
    }

    public func remapped(using map: MeshVertexMap) throws -> Self {
        try validateWeights(vertexCount: map.sourceVertexCount)
        let output = map.contributions.map { row -> [JointWeight] in
            var accumulated: [AnyRealitizerID: Float] = [:]
            for source in row {
                for influence in influences[source.sourceIndex] {
                    accumulated[influence.jointID, default: 0] += influence.weight * source.weight
                }
            }
            return accumulated.keys.sorted { $0.rawValue < $1.rawValue }.compactMap {
                accumulated[$0]! > 0 ? JointWeight($0, weight: accumulated[$0]!) : nil
            }
        }
        let result = Self(influences: output, maximumInfluences: maximumInfluences)
        // Never silently discard small weights when an interpolated vertex exceeds the declared limit.
        try result.validateWeights(vertexCount: map.contributions.count)
        return result
    }

    /// Distance-to-bone weighting gives an editable starting point for procedural assets.
    public static func automatic(
        mesh: MeshData, rig: RigDefinition, maximumInfluences: Int = 4, falloff: Float = 2
    )
        throws -> Self
    {
        guard (1...8).contains(maximumInfluences), falloff.isFinite, falloff > 0 else {
            throw modelingError(
                "skin.automatic", "Influence count must be 1...8 and falloff must be positive.")
        }
        let skeleton = try rig.resolvedSkeleton()
        guard !skeleton.joints.isEmpty else {
            throw modelingError("skin.emptyRig", "Automatic binding requires a nonempty rig.")
        }
        let origins = skeleton.bindMatrices.map { $0.point(.zero) }
        var weights: [[JointWeight]] = []
        for vertex in mesh.vertices {
            var distances: [(index: Int, distance: Float)] = []
            for i in skeleton.joints.indices {
                let b: SIMD3<Float> = origins[i]
                let a: SIMD3<Float> = skeleton.parentIndices[i].map { origins[$0] } ?? b
                let axis: SIMD3<Float> = b - a
                let length = simd_length_squared(axis)
                let t: Float = length > 0 ? min(max(simd_dot(vertex.position - a, axis) / length, 0), 1) : 0
                let closest: SIMD3<Float> = a + axis * t
                let distance: Float = simd_distance(vertex.position, closest)
                distances.append((i, distance))
            }
            distances.sort {
                $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance
            }
            let chosen = Array(distances.prefix(maximumInfluences))
            let raw: [Float] = chosen.map { pow(max($0.distance, 0.0001), -falloff) }
            let sum = raw.reduce(0, +)
            var vertexWeights: [JointWeight] = []
            for i in chosen.indices {
                vertexWeights.append(JointWeight(skeleton.joints[chosen[i].index].id, weight: raw[i] / sum))
            }
            weights.append(vertexWeights)
        }
        let binding = Self(influences: weights, maximumInfluences: maximumInfluences)
        try binding.validate(vertexCount: mesh.vertices.count, rig: rig)
        return binding
    }

    /// CPU reference evaluator used by tests, collision/debug tools, and renderer comparisons.
    public func deform(_ mesh: MeshData, rig: RigDefinition, pose: PoseDefinition) throws -> MeshData {
        try validate(vertexCount: mesh.vertices.count, rig: rig)
        let skeleton = try rig.resolvedSkeleton()
        let globals = try skeleton.globalMatrices(pose: pose)
        let indices = Dictionary(
            uniqueKeysWithValues: skeleton.joints.enumerated().map { ($0.element.id, $0.offset) })
        let matrices = zip(globals, skeleton.inverseBindMatrices).map(*)
        var result = mesh
        for i in mesh.vertices.indices {
            var matrix = simd_float4x4(0)
            for influence in influences[i] {
                matrix += matrices[indices[influence.jointID]!] * influence.weight
            }
            let original = mesh.vertices[i]
            result.vertices[i].position = matrix.point(original.position)
            let linear = simd_float3x3(
                columns: (
                    SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                    SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                    SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
                ))
            guard abs(simd_determinant(linear)) > 1e-10 else {
                throw modelingError("skin.singular", "The blended skin transform is singular.")
            }
            result.vertices[i].normal = unitVector(simd_transpose(simd_inverse(linear)) * original.normal)
        }
        return try result.generatingTangents().validated()
    }
}

/// Dense position/normal deltas relative to the unmodified base mesh.
public struct MorphTarget: Sendable {
    public let id: AnyRealitizerID
    public var positionDeltas: [SIMD3<Float>]
    public var normalDeltas: [SIMD3<Float>]
    public init<ID: RealitizerID>(
        id: ID, positionDeltas: [SIMD3<Float>], normalDeltas: [SIMD3<Float>] = []
    ) {
        self.id = id.erasedID
        self.positionDeltas = positionDeltas
        self.normalDeltas = normalDeltas
    }
    public func validate(vertexCount: Int) throws {
        guard positionDeltas.count == vertexCount,
            normalDeltas.isEmpty || normalDeltas.count == vertexCount,
            positionDeltas.allSatisfy(\.isFinite), normalDeltas.allSatisfy(\.isFinite)
        else {
            throw modelingError(
                "morph.deltas", "Morph deltas must be finite and match the base vertex count.")
        }
    }
}

public struct ResolvedSkeleton: Sendable {
    public let joints: [JointDefinition]
    public let parentIndices: [Int?]
    public let bindMatrices: [simd_float4x4]
    public let inverseBindMatrices: [simd_float4x4]

    public func globalMatrices(pose: PoseDefinition) throws -> [simd_float4x4] {
        var result: [simd_float4x4] = []
        for i in joints.indices {
            let transform = pose.transforms[.joint(joints[i].id)] ?? joints[i].restTransform
            guard transform.isFinite, abs(simd_length(transform.rotation.vector) - 1) < 0.001 else {
                throw modelingError(
                    "pose.transform", "Joint transforms must be finite with unit rotations.")
            }
            let local = transform.matrix
            result.append(parentIndices[i].map { result[$0] * local } ?? local)
        }
        return result
    }
}

extension RigDefinition {
    public func resolvedSkeleton() throws -> ResolvedSkeleton {
        guard Set(joints.map(\.id)).count == joints.count else {
            throw modelingError("rig.duplicate", "Joint identifiers must be unique.")
        }
        var sorted: [JointDefinition] = []
        var remaining = joints
        var indices: [AnyRealitizerID: Int] = [:]
        while !remaining.isEmpty {
            guard
                let index = remaining.firstIndex(where: {
                    $0.parentID == nil || indices[$0.parentID!] != nil
                })
            else {
                throw modelingError("rig.hierarchy", "Rig contains a cycle or a missing parent.")
            }
            let joint = remaining.remove(at: index)
            indices[joint.id] = sorted.count
            sorted.append(joint)
        }
        var binds: [simd_float4x4] = []
        var inverses: [simd_float4x4] = []
        let parents = sorted.map { $0.parentID.flatMap { indices[$0] } }
        for i in sorted.indices {
            let local = (sorted[i].bindTransform ?? sorted[i].restTransform).matrix
            let global = parents[i].map { binds[$0] * local } ?? local
            guard global.finite, abs(simd_determinant(global)) > 1e-12 else {
                throw modelingError("rig.bindMatrix", "Bind transforms must be finite and invertible.")
            }
            binds.append(global)
            inverses.append(simd_inverse(global))
        }
        return ResolvedSkeleton(
            joints: sorted, parentIndices: parents, bindMatrices: binds, inverseBindMatrices: inverses)
    }
}
