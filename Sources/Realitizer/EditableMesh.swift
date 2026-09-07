import simd

/// Reconstructing topology from render vertices is an explicit authoring choice.
public enum TopologyWelding: Sendable {
    case none
    /// Coincident positions become one topology vertex, even across UV seams.
    /// Do not use for separate shells that intentionally touch at identical positions.
    case exactPositions
}

public struct FaceSample: Sendable {
    public let id: FaceID
    public let center: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let materialIndex: UInt32
}

public struct RegionExtrusionResult: Sendable {
    public let capFaces: [FaceID]
    public let sideFaces: [FaceID]
}

public struct VertexID: Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
public struct FaceID: Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Per-corner attributes preserve discontinuities without duplicating modeling vertices.
public struct MeshCorner: Equatable, Sendable, Codable {
    public var vertex: VertexID
    public var uv: SIMD2<Float>
    public var color: RGBAColor
    public init(_ vertex: VertexID, uv: SIMD2<Float> = .zero, color: RGBAColor = .white) {
        self.vertex = vertex
        self.uv = uv
        self.color = color
    }
}

public struct MeshFace: Equatable, Sendable, Codable {
    public var id: FaceID
    public var corners: [MeshCorner]
    public var materialIndex: UInt32
    public init(id: FaceID, corners: [MeshCorner], materialIndex: UInt32 = 0) {
        self.id = id
        self.corners = corners
        self.materialIndex = materialIndex
    }
}

/// A directed topological edge is identified by its endpoints and face, not storage position.
public struct HalfEdge: Hashable, Sendable {
    public let origin: VertexID
    public let destination: VertexID
    public let face: FaceID
    public let nextVertex: VertexID
    public let oppositeFace: FaceID?
}

/// An indexed polygon mesh. Unaffected vertex/face IDs remain stable after local edits.
/// Adjacency is derived on demand, so stale half-edge caches cannot survive an edit.
public struct EditableMesh: Sendable {
    public private(set) var positions: [VertexID: SIMD3<Float>]
    public internal(set) var faces: [FaceID: MeshFace]
    private var nextVertex: Int
    private var nextFace: Int

    public init(positions: [SIMD3<Float>], polygons: [[Int]], materialIndices: [UInt32] = []) throws {
        self.positions = Dictionary(
            uniqueKeysWithValues: positions.enumerated().map { (VertexID($0.offset), $0.element) })
        faces = [:]
        nextVertex = positions.count
        nextFace = polygons.count
        guard materialIndices.isEmpty || materialIndices.count == polygons.count else {
            throw modelingError("topology.materials", "Material count must match the face count.")
        }
        for (i, polygon) in polygons.enumerated() {
            faces[FaceID(i)] = MeshFace(
                id: FaceID(i), corners: polygon.map { MeshCorner(VertexID($0)) },
                materialIndex: materialIndices.isEmpty ? 0 : materialIndices[i])
        }
        try validate()
    }

    /// Attribute seams remain per corner. Welding never uses a hidden positional tolerance.
    public init(renderMesh: MeshData, welding: TopologyWelding) throws {
        _ = try renderMesh.validated()
        var lookup: [SIMD3<Float>: Int] = [:]
        var points: [SIMD3<Float>] = []
        let mapping = renderMesh.vertices.map { vertex -> Int in
            if case .exactPositions = welding, let existing = lookup[vertex.position] { return existing }
            let index = points.count
            lookup[vertex.position] = index
            points.append(vertex.position)
            return index
        }
        let polygons = stride(from: 0, to: renderMesh.indices.count, by: 3).map { i in
            (0..<3).map { mapping[Int(renderMesh.indices[i + $0])] }
        }
        try self.init(
            positions: points, polygons: polygons, materialIndices: renderMesh.materialIndices)
        for i in 0..<polygons.count {
            for j in 0..<3 {
                faces[FaceID(i)]!.corners[j].uv =
                    renderMesh.vertices[Int(renderMesh.indices[i * 3 + j])].textureCoordinate
                faces[FaceID(i)]!.corners[j].color =
                    renderMesh.vertices[Int(renderMesh.indices[i * 3 + j])].color
            }
        }
    }

    public var vertexIDs: [VertexID] { positions.keys.sorted() }
    public var faceIDs: [FaceID] { faces.keys.sorted() }

    public func halfEdges() throws -> [HalfEdge] {
        try validate()
        let uses = edgeUses()
        return faceIDs.flatMap { id -> [HalfEdge] in
            let face = faces[id]!
            return face.corners.indices.map { i in
                let a = face.corners[i].vertex
                let b = face.corners[(i + 1) % face.corners.count].vertex
                return HalfEdge(
                    origin: a, destination: b, face: id,
                    nextVertex: face.corners[(i + 2) % face.corners.count].vertex,
                    oppositeFace: uses[UndirectedEdge(a, b)]?.first(where: { $0.face != id })?.face)
            }
        }
    }

    public func validate(requireClosed: Bool = false) throws {
        guard !faces.isEmpty, positions.values.allSatisfy(\.isFinite) else {
            throw modelingError(
                "topology.emptyOrNonFinite", "A mesh requires faces and finite vertex positions.")
        }
        for id in faceIDs {
            let face = faces[id]!
            guard face.corners.count >= 3, Set(face.corners.map(\.vertex)).count == face.corners.count,
                face.corners.allSatisfy({ positions[$0.vertex] != nil && $0.uv.isFinite && $0.color.isNormalized })
            else {
                throw modelingError(
                    "topology.invalidFace", "A face needs at least three distinct valid corners.",
                    path: "faces[\(id.rawValue)]")
            }
        }
        for (_, edges) in edgeUses() {
            guard edges.count <= 2 else {
                throw modelingError("topology.nonManifold", "More than two faces share an edge.")
            }
            if requireClosed && edges.count != 2 {
                throw modelingError("topology.boundary", "This operation requires a closed manifold.")
            }
            if edges.count == 2 && edges[0].origin == edges[1].origin {
                throw modelingError(
                    "topology.winding", "Adjacent faces must traverse shared edges in opposite directions.")
            }
        }
    }

    public mutating func setPosition(_ position: SIMD3<Float>, for id: VertexID) throws {
        guard positions[id] != nil, position.isFinite else {
            throw modelingError("topology.vertex", "Vertex must exist and its position must be finite.")
        }
        positions[id] = position
    }

    public func selectFaces(normal direction: SIMD3<Float>, minimumDot: Float = 0.99) -> [FaceID] {
        faceIDs.filter { simd_dot(faceNormal(faces[$0]!), unitVector(direction)) >= minimumDot }
    }

    /// Evaluate a spatial/material query each time the model-building code runs.
    public func selectFaces(where predicate: (FaceSample) throws -> Bool) rethrows -> [FaceID] {
        try faceIDs.filter { id in
            let face = faces[id]!
            let center =
                face.corners.reduce(SIMD3<Float>.zero) { $0 + positions[$1.vertex]! }
                / Float(face.corners.count)
            return try predicate(
                FaceSample(
                    id: id, center: center, normal: faceNormal(face), materialIndex: face.materialIndex))
        }
    }

    /// Extrudes a connected or disconnected region as a unit. Only boundary edges receive side walls.
    /// The cap retains selected face IDs. Work is committed only after validation succeeds.
    @discardableResult
    public mutating func extrude(faces selection: [FaceID], offset: SIMD3<Float>) throws
        -> RegionExtrusionResult
    {
        try validate()
        let selected = Set(selection)
        guard !selected.isEmpty, selected.count == selection.count,
            selected.allSatisfy({ faces[$0] != nil }), offset.isFinite,
            simd_length_squared(offset) > 1e-16
        else {
            throw modelingError(
                "extrude.region", "A region requires distinct existing faces and a finite nonzero offset.")
        }
        let boundary = try halfEdges().filter { edge in
            selected.contains(edge.face)
                && (edge.oppositeFace == nil || !selected.contains(edge.oppositeFace!))
        }
        guard !boundary.isEmpty else {
            throw modelingError(
                "extrude.closedRegion",
                "A region extrusion requires boundary edges; transform a complete closed shell instead.")
        }
        var result = self
        let used = Set(selected.flatMap { faces[$0]!.corners.map(\.vertex) }).sorted()
        var moved: [VertexID: VertexID] = [:]
        for id in used { moved[id] = result.addVertex(positions[id]! + offset) }
        for id in selected.sorted() {
            result.faces[id]!.corners = faces[id]!.corners.map {
                MeshCorner(moved[$0.vertex]!, uv: $0.uv, color: $0.color)
            }
        }
        var sides: [FaceID] = []
        for edge in boundary {
            let face = faces[edge.face]!
            let a = face.corners.first { $0.vertex == edge.origin }!
            let b = face.corners.first { $0.vertex == edge.destination }!
            let id = FaceID(result.nextFace)
            result.addFace(
                [a, b, MeshCorner(moved[b.vertex]!, uv: b.uv, color: b.color),
                 MeshCorner(moved[a.vertex]!, uv: a.uv, color: a.color)],
                material: face.materialIndex)
            sides.append(id)
        }
        let remaining = Set(result.faces.values.flatMap { $0.corners.map(\.vertex) })
        result.positions = result.positions.filter { remaining.contains($0.key) }
        try result.validate()
        _ = try result.renderMesh()
        self = result
        return RegionExtrusionResult(capFaces: selected.sorted(), sideFaces: sides)
    }

    public mutating func setMaterial(_ slot: UInt32, on selection: [FaceID]) throws {
        guard selection.allSatisfy({ faces[$0] != nil }) else {
            throw modelingError("topology.selection", "Selected face does not exist.")
        }
        for id in selection { faces[id]!.materialIndex = slot }
    }

    /// Extrudes one face along its normal, retaining the original face ID on the new cap.
    /// Local changes are committed only after the resulting topology passes validation.
    public mutating func extrude(face id: FaceID, distance: Float, scale: Float = 1) throws {
        guard let face = faces[id], distance.isFinite, scale.isFinite, scale > 0 else {
            throw modelingError(
                "topology.extrude", "Face must exist; distance must be finite and scale positive.")
        }
        var result = self
        let normal = faceNormal(face)
        let center =
            face.corners.reduce(SIMD3<Float>.zero) { $0 + positions[$1.vertex]! }
            / Float(face.corners.count)
        let newCorners = face.corners.map { corner -> MeshCorner in
            let position = center + (positions[corner.vertex]! - center) * scale + normal * distance
            return MeshCorner(result.addVertex(position), uv: corner.uv, color: corner.color)
        }
        result.faces[id]!.corners = newCorners
        for i in face.corners.indices {
            let j = (i + 1) % face.corners.count
            result.addFace(
                [face.corners[i], face.corners[j], newCorners[j], newCorners[i]],
                material: face.materialIndex)
        }
        try result.validate()
        _ = try result.renderMesh()
        self = result
    }

    /// Insets a face towards its centroid. Fraction is dimensionless and must be in (0, 1).
    public mutating func inset(face id: FaceID, fraction: Float) throws {
        guard fraction > 0, fraction < 1 else {
            throw modelingError("topology.inset", "Inset fraction must be in (0, 1).")
        }
        try extrude(face: id, distance: 0, scale: 1 - fraction)
    }

    /// Catmull-Clark subdivision with boundary rules. Corner UVs interpolate within each face.
    public func subdivided(iterations: Int = 1) throws -> Self {
        guard (0...5).contains(iterations) else {
            throw modelingError(
                "subdivision.iterations", "Subdivision iterations must be between zero and five.")
        }
        var result = self
        for _ in 0..<iterations { result = try result.subdivideOnce() }
        return result
    }

    /// Chamfers every edge of a convex closed polyhedron by shrinking each face towards its centroid.
    /// Fraction controls face-relative width, not a constant world-space bevel radius.
    public func chamfered(fraction: Float = 0.1) throws -> Self {
        try validate(requireClosed: true)
        guard fraction.isFinite, fraction > 0, fraction < 0.5 else {
            throw modelingError("chamfer.fraction", "Chamfer fraction must be in (0, 0.5).")
        }
        let allPoints = vertexIDs.map { positions[$0]! }
        let center = allPoints.reduce(.zero, +) / Float(allPoints.count)
        for id in faceIDs {
            let face = faces[id]!
            let normal = faceNormal(face)
            let origin = positions[face.corners[0].vertex]!
            guard allPoints.allSatisfy({ simd_dot($0 - origin, normal) < 1e-5 }) else {
                throw modelingError(
                    "chamfer.convexOnly", "Face-relative chamfer requires a convex outward-oriented closed mesh.")
            }
        }
        var result = self
        result.faces = [:]
        result.positions = [:]
        var corners: [FaceID: [VertexID: MeshCorner]] = [:]
        for id in faceIDs {
            let face = faces[id]!
            let faceCenter =
                face.corners.reduce(SIMD3<Float>.zero) { $0 + positions[$1.vertex]! }
                / Float(face.corners.count)
            var newCorners: [MeshCorner] = []
            for corner in face.corners {
                let p = simd_mix(positions[corner.vertex]!, faceCenter, SIMD3(repeating: fraction))
                let created = MeshCorner(result.addVertex(p), uv: corner.uv, color: corner.color)
                corners[id, default: [:]][corner.vertex] = created
                newCorners.append(created)
            }
            result.faces[id] = MeshFace(id: id, corners: newCorners, materialIndex: face.materialIndex)
        }
        let uses = edgeUses()
        for edge in uses.keys.sorted() {
            let pair = uses[edge]!
            let f = pair[0].face
            let g = pair[1].face
            let a = pair[0].origin
            let b = a == edge.a ? edge.b : edge.a
            result.addFace(
                [corners[f]![b]!, corners[f]![a]!, corners[g]![a]!, corners[g]![b]!],
                material: faces[f]!.materialIndex)
        }
        for vertex in vertexIDs {
            let incident = faceIDs.filter { corners[$0]?[vertex] != nil }
            let normal = unitVector(positions[vertex]! - center)
            let x = orthogonal(to: normal)
            let y = simd_cross(normal, x)
            let ordered = incident.map { corners[$0]![vertex]! }.sorted { a, b in
                let pa = result.positions[a.vertex]! - positions[vertex]!
                let pb = result.positions[b.vertex]! - positions[vertex]!
                return atan2(simd_dot(pa, y), simd_dot(pa, x)) < atan2(simd_dot(pb, y), simd_dot(pb, x))
            }
            result.addFace(ordered, material: faces[incident[0]]!.materialIndex)
        }
        try result.validate(requireClosed: true)
        return result
    }

    /// Gives an open oriented surface thickness along averaged vertex normals and closes its boundary.
    /// Offset -1 places the original on the outside, +1 on the inside, and 0 centers the shell.
    /// This is a polygon shell operation, not an exact offset or a self-intersection repair solver.
    public func solidified(thickness: Float, offset: Float = 0, rimMaterial: UInt32? = nil) throws
        -> Self
    {
        try validate()
        guard thickness.isFinite, thickness > 0, offset.isFinite, (-1...1).contains(offset) else {
            throw modelingError(
                "solidify.parameters", "Thickness must be positive; offset must be in [-1, 1].")
        }
        let boundary = try halfEdges().filter { $0.oppositeFace == nil }
        guard !boundary.isEmpty else {
            throw modelingError(
                "solidify.closed",
                "Solidify accepts open surfaces; use explicit inner/outer solids for closed volumes.")
        }
        var normals: [VertexID: SIMD3<Float>] = [:]
        for id in faceIDs {
            let face = faces[id]!
            let normal = faceNormal(face)
            for corner in face.corners { normals[corner.vertex, default: .zero] += normal }
        }
        var result = self
        var inner: [VertexID: VertexID] = [:]
        for id in vertexIDs {
            guard let n = normals[id], simd_length_squared(n) > 1e-12 else {
                throw modelingError(
                    "solidify.normal", "Surface vertices need an unambiguous averaged normal.")
            }
            let normal = unitVector(n)
            result.positions[id] = positions[id]! + normal * thickness * (offset + 1) * 0.5
            inner[id] = result.addVertex(positions[id]! + normal * thickness * (offset - 1) * 0.5)
        }
        for id in faceIDs {
            let face = faces[id]!
            result.addFace(
                face.corners.reversed().map { MeshCorner(inner[$0.vertex]!, uv: $0.uv, color: $0.color) },
                material: face.materialIndex)
        }
        for edge in boundary {
            let face = faces[edge.face]!
            let a = face.corners.first { $0.vertex == edge.origin }!
            let b = face.corners.first { $0.vertex == edge.destination }!
            result.addFace(
                [MeshCorner(inner[a.vertex]!, uv: a.uv, color: a.color),
                 MeshCorner(inner[b.vertex]!, uv: b.uv, color: b.color), b, a],
                material: rimMaterial ?? face.materialIndex)
        }
        try result.validate(requireClosed: true)
        _ = try result.renderMesh()
        return result
    }

    public func renderMesh(smoothingAngle: Float = 0) throws -> MeshData {
        try validate()
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var materials: [UInt32] = []
        for id in faceIDs {
            let face = faces[id]!
            let normal = faceNormal(face)
            let x = orthogonal(to: normal)
            let y = simd_cross(normal, x)
            let origin = positions[face.corners[0].vertex]!
            let points = face.corners.map { positions[$0.vertex]! }
            let extent = points.map { simd_distance($0, origin) }.max() ?? 1
            let epsilon = GeometryTolerance().length(for: extent)
            guard
                points.count <= 4
                    || points.allSatisfy({ abs(simd_dot($0 - origin, normal)) <= epsilon * 10 })
            else {
                throw modelingError(
                    "topology.nonPlanarFace",
                    "Polygon faces must be planar; triangulate before applying nonplanar edits.",
                    path: "faces[\(id.rawValue)]")
            }
            let projected = points.map { SIMD2(simd_dot($0 - origin, x), simd_dot($0 - origin, y)) }
            let triangulation = try Profile2D(outer: projected).triangulated()
            let base = UInt32(vertices.count)
            for point in triangulation.vertices {
                guard let cornerIndex = projected.firstIndex(of: point) else {
                    throw modelingError("topology.corner", "Triangulation lost a corner.")
                }
                vertices.append(
                    MeshVertex(
                        position: points[cornerIndex], normal: normal,
                        textureCoordinate: face.corners[cornerIndex].uv, color: face.corners[cornerIndex].color))
            }
            indices += triangulation.indices.map { $0 + base }
            materials += Array(repeating: face.materialIndex, count: triangulation.indices.count / 3)
        }
        let mesh = MeshData(vertices: vertices, indices: indices, materialIndices: materials)
        return try mesh.recalculatingNormals(smoothingAngle: smoothingAngle).generatingTangents()
            .validated()
    }

    private func subdivideOnce() throws -> Self {
        try validate()
        guard faces.count < 100_000 else {
            throw modelingError("subdivision.budget", "Subdivision input exceeds 100000 faces.")
        }
        let uses = edgeUses()
        var facePoints: [FaceID: SIMD3<Float>] = [:]
        for id in faceIDs {
            facePoints[id] =
                faces[id]!.corners.reduce(SIMD3<Float>.zero) { $0 + positions[$1.vertex]! }
                / Float(faces[id]!.corners.count)
        }
        var output = self
        for vertex in vertexIDs {
            let incident = uses.filter { $0.key.a == vertex || $0.key.b == vertex }
            let boundary = incident.filter { $0.value.count == 1 }.keys.sorted()
            if boundary.count == 2 {
                let neighbors = boundary.map { $0.a == vertex ? $0.b : $0.a }
                output.positions[vertex] =
                    positions[vertex]! * 0.75 + (positions[neighbors[0]]! + positions[neighbors[1]]!) * 0.125
            } else if boundary.isEmpty && !incident.isEmpty {
                let adjacentFaces = Set(incident.values.flatMap { $0.map(\.face) }).sorted()
                let f =
                    adjacentFaces.reduce(SIMD3<Float>.zero) { $0 + facePoints[$1]! }
                    / Float(adjacentFaces.count)
                let r =
                    incident.keys.sorted().reduce(SIMD3<Float>.zero) {
                        $0 + (positions[$1.a]! + positions[$1.b]!) * 0.5
                    } / Float(incident.count)
                let n = Float(adjacentFaces.count)
                output.positions[vertex] = (f + r * 2 + positions[vertex]! * (n - 3)) / n
            }
        }
        var edgeIDs: [UndirectedEdge: VertexID] = [:]
        for edge in uses.keys.sorted() {
            let endpoints = positions[edge.a]! + positions[edge.b]!
            let adjacent = uses[edge]!
            let p =
                adjacent.count == 2
                ? (endpoints + facePoints[adjacent[0].face]! + facePoints[adjacent[1].face]!) * 0.25
                : endpoints * 0.5
            edgeIDs[edge] = output.addVertex(p)
        }
        output.faces = [:]
        for id in faceIDs {
            let face = faces[id]!
            let centerID = output.addVertex(facePoints[id]!)
            let centerUV =
                face.corners.reduce(SIMD2<Float>.zero) { $0 + $1.uv } / Float(face.corners.count)
            let centerRGBA = face.corners.reduce(SIMD4<Float>.zero) { $0 + $1.color.linearRGBA }
                / Float(face.corners.count)
            let centerColor = RGBAColor(linearSRGB: SIMD3(centerRGBA.x, centerRGBA.y, centerRGBA.z), alpha: centerRGBA.w)
            for i in face.corners.indices {
                let a = face.corners[i]
                let b = face.corners[(i + 1) % face.corners.count]
                let previous = face.corners[(i + face.corners.count - 1) % face.corners.count]
                let corners = [
                    a, MeshCorner(edgeIDs[UndirectedEdge(a.vertex, b.vertex)]!, uv: (a.uv + b.uv) * 0.5,
                                  color: a.color.interpolated(to: b.color, fraction: 0.5)),
                    MeshCorner(centerID, uv: centerUV, color: centerColor),
                    MeshCorner(
                        edgeIDs[UndirectedEdge(previous.vertex, a.vertex)]!, uv: (previous.uv + a.uv) * 0.5,
                        color: previous.color.interpolated(to: a.color, fraction: 0.5)),
                ]
                // Preserve the old face identity on the first child.
                if i == 0 {
                    output.faces[id] = MeshFace(id: id, corners: corners, materialIndex: face.materialIndex)
                } else {
                    output.addFace(corners, material: face.materialIndex)
                }
            }
        }
        try output.validate()
        return output
    }

    func faceNormal(_ face: MeshFace) -> SIMD3<Float> {
        var normal = SIMD3<Float>.zero
        for i in face.corners.indices {
            let a = positions[face.corners[i].vertex]!
            let b = positions[face.corners[(i + 1) % face.corners.count].vertex]!
            normal += simd_cross(a, b)
        }
        return unitVector(normal)
    }

    private mutating func addVertex(_ point: SIMD3<Float>) -> VertexID {
        let id = VertexID(nextVertex)
        nextVertex += 1
        positions[id] = point
        return id
    }
    private mutating func addFace(_ corners: [MeshCorner], material: UInt32) {
        let id = FaceID(nextFace)
        nextFace += 1
        faces[id] = MeshFace(id: id, corners: corners, materialIndex: material)
    }
    private struct EdgeUse {
        let origin: VertexID
        let face: FaceID
    }
    private func edgeUses() -> [UndirectedEdge: [EdgeUse]] {
        var result: [UndirectedEdge: [EdgeUse]] = [:]
        for id in faceIDs {
            let corners = faces[id]!.corners
            for i in corners.indices {
                let a = corners[i].vertex
                let b = corners[(i + 1) % corners.count].vertex
                result[UndirectedEdge(a, b), default: []].append(EdgeUse(origin: a, face: id))
            }
        }
        return result
    }
}

struct UndirectedEdge: Hashable, Comparable {
    let a: VertexID
    let b: VertexID
    init(_ x: VertexID, _ y: VertexID) {
        a = min(x, y)
        b = max(x, y)
    }
    static func < (x: Self, y: Self) -> Bool { x.a == y.a ? x.b < y.b : x.a < y.a }
}
