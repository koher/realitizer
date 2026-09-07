import simd

/// One geometry payload. Skin and morph arrays always belong to this mesh, including at each LOD.
/// Build and finish a mesh first, then bind it. Use processing results for later seam/normal changes.
public struct ModelGeometry: Sendable {
    public let mesh: MeshData
    public let skin: SkinBinding?
    public let morphTargets: [MorphTarget]

    /// Raw authoring values are validated by `validate` and by the asset compiler.
    public init(mesh: MeshData, skin: SkinBinding? = nil, morphTargets: [MorphTarget] = []) {
        self.mesh = mesh
        self.skin = skin
        self.morphTargets = morphTargets
    }

    public func validate() throws {
        _ = try mesh.validated()
        try skin?.validateWeights(vertexCount: mesh.vertices.count)
        guard Set(morphTargets.map(\.id)).count == morphTargets.count else {
            throw modelingError(
                "geometry.duplicateMorph", "Morph identifiers must be unique within a geometry.")
        }
        for morph in morphTargets { try morph.validate(vertexCount: mesh.vertices.count) }
    }

    public func binding(_ skin: SkinBinding, to rig: RigDefinition) throws -> Self {
        try validate()
        try skin.validate(vertexCount: mesh.vertices.count, rig: rig)
        return Self(mesh: mesh, skin: skin, morphTargets: morphTargets)
    }

    /// A code-defined weighting function; no persistent paint/editor state is involved.
    public func binding(
        to rig: RigDefinition, maximumInfluences: Int = 4,
        weights: (MeshVertex) throws -> [JointWeight]
    ) throws -> Self {
        try binding(
            SkinBinding(influences: mesh.vertices.map(weights), maximumInfluences: maximumInfluences),
            to: rig)
    }

    public func automaticallyBinding(
        to rig: RigDefinition, maximumInfluences: Int = 4, falloff: Float = 2
    )
        throws -> Self
    {
        try binding(
            .automatic(mesh: mesh, rig: rig, maximumInfluences: maximumInfluences, falloff: falloff),
            to: rig)
    }

    public func addingMorph(_ morph: MorphTarget) throws -> Self {
        let result = Self(mesh: mesh, skin: skin, morphTargets: morphTargets + [morph])
        try result.validate()
        return result
    }

    /// Samples absolute target positions on the finished base mesh; stores position-only deltas.
    public func addingMorph<ID: RealitizerID>(id: ID, position: (MeshVertex) throws -> SIMD3<Float>)
        throws -> Self
    {
        try addingMorph(
            MorphTarget(id: id, positionDeltas: mesh.vertices.map { try position($0) - $0.position }))
    }

    /// Rejects a result computed for a different source, even if vertex counts happen to match.
    public func applying(_ result: MeshProcessingResult) throws -> Self {
        try validate()
        guard mesh == result.source else {
            throw modelingError(
                "geometry.processingSource", "Processing result belongs to a different source mesh.")
        }
        let remap = result.vertexMap
        let transferredSkin = try skin.map { try $0.remapped(using: remap) }
        let targets = morphTargets.map { morph in
            MorphTarget(
                id: morph.id, positionDeltas: remap.interpolate(morph.positionDeltas),
                normalDeltas: morph.normalDeltas.isEmpty ? [] : remap.interpolate(morph.normalDeltas))
        }
        let output = Self(mesh: result.mesh, skin: transferredSkin, morphTargets: targets)
        try output.validate()
        return output
    }

    public func recalculatingNormals(smoothingAngle: Float = .pi) throws -> Self {
        try applying(MeshProcessor.recalculateNormals(of: mesh, smoothingAngle: smoothingAngle))
    }

    public func projectingUV(_ projection: UVProjection) throws -> Self {
        try applying(MeshProcessor.projectUV(of: mesh, using: projection))
    }
}

/// An explicit source contribution for an output render vertex. Indices are local to one processing result.
public struct VertexContribution: Equatable, Sendable {
    public let sourceIndex: Int
    public let weight: Float
    public init(sourceIndex: Int, weight: Float = 1) {
        self.sourceIndex = sourceIndex
        self.weight = weight
    }
}

/// Output-to-input correspondence, supporting splitting and weighted interpolation without positional guesses.
public struct MeshVertexMap: Sendable {
    public let sourceVertexCount: Int
    public let contributions: [[VertexContribution]]

    public init(sourceVertexCount: Int, contributions: [[VertexContribution]]) throws {
        guard sourceVertexCount > 0, !contributions.isEmpty,
            contributions.allSatisfy({ row in
                !row.isEmpty && Set(row.map(\.sourceIndex)).count == row.count
                    && row.allSatisfy {
                        (0..<sourceVertexCount).contains($0.sourceIndex) && $0.weight.isFinite && $0.weight > 0
                    }
                    && abs(row.reduce(Float(0)) { $0 + $1.weight } - 1) < 0.00001
            })
        else {
            throw modelingError(
                "geometry.vertexMap",
                "Each output needs distinct valid source indices and positive weights summing to one.")
        }
        self.sourceVertexCount = sourceVertexCount
        self.contributions = contributions
    }

    func interpolate(_ values: [SIMD3<Float>]) -> [SIMD3<Float>] {
        contributions.map { row in row.reduce(.zero) { $0 + values[$1.sourceIndex] * $1.weight } }
    }
}

/// A checked geometric operation result, not a persistent editor command or an undo record.
public struct MeshProcessingResult: Sendable {
    public let source: MeshData
    public let mesh: MeshData
    public let vertexMap: MeshVertexMap

    public init(source: MeshData, mesh: MeshData, vertexMap: MeshVertexMap) throws {
        _ = try source.validated()
        _ = try mesh.validated()
        guard vertexMap.sourceVertexCount == source.vertices.count,
            vertexMap.contributions.count == mesh.vertices.count
        else {
            throw modelingError(
                "geometry.mapCount", "Vertex correspondence must match source and output meshes.")
        }
        self.source = source
        self.mesh = mesh
        self.vertexMap = vertexMap
    }

    init(source: MeshData, mesh: MeshData, sourceIndices: [Int]) throws {
        try self.init(
            source: source, mesh: mesh,
            vertexMap: MeshVertexMap(
                sourceVertexCount: source.vertices.count,
                contributions: sourceIndices.map { [VertexContribution(sourceIndex: $0)] }))
    }
}
