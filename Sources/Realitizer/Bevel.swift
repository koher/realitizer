import simd

/// An undirected edge in one EditableMesh, not a semantic cross-generation asset identifier.
public struct MeshEdge: Hashable, Comparable, Sendable {
    public let start: VertexID
    public let end: VertexID
    public init(_ a: VertexID, _ b: VertexID) {
        start = min(a, b)
        end = max(a, b)
    }
    public static func < (a: Self, b: Self) -> Bool {
        a.start == b.start ? a.end < b.end : a.start < b.start
    }
}

public struct EdgeSample: Sendable {
    public let id: MeshEdge
    public let center: SIMD3<Float>
    public let length: Float
    public let adjacentFaces: [FaceID]
    /// Unsigned angle between face normals. Nil at an open boundary.
    public let angle: Float?
}

extension EditableMesh {
    public func selectEdges(where predicate: (EdgeSample) throws -> Bool) throws -> [MeshEdge] {
        var uses: [MeshEdge: [FaceID]] = [:]
        for half in try halfEdges() {
            uses[MeshEdge(half.origin, half.destination), default: []].append(half.face)
        }
        return try uses.keys.sorted().filter { edge in
            let adjacent = uses[edge]!.sorted()
            let a = positions[edge.start]!
            let b = positions[edge.end]!
            let angle: Float? =
                adjacent.count == 2
                ? acos(
                    min(
                        1,
                        max(
                            -1,
                            simd_dot(
                                faceNormal(faces[adjacent[0]]!), faceNormal(faces[adjacent[1]]!)))))
                : nil
            return try predicate(
                EdgeSample(
                    id: edge, center: (a + b) * 0.5, length: simd_distance(a, b),
                    adjacentFaces: adjacent, angle: angle))
        }
    }

    /// Offsets selected edges by a constant distance along their adjacent faces, in model-space meters.
    /// Nil selects all noncoplanar edges. One segment makes a flat bevel; more make circular edge bands.
    /// Requires a closed, oriented, planar-faced manifold. Concave edges/faces are allowed.
    /// Oversized, intersecting or numerically degenerate results throw; widths are never silently clamped.
    /// Corner patches are mitered/triangulated, not spherical fillets. The returned topology has new local IDs.
    public func beveled(
        edges selection: [MeshEdge]? = nil, width: Float, segments: Int = 1,
        material: UInt32? = nil
    ) throws -> Self {
        try validate(requireClosed: true)
        guard width.isFinite, width > 0, (1...32).contains(segments) else {
            throw modelingError(
                "bevel.options", "Width must be finite and positive, and segments in 1...32.")
        }
        guard faces.count <= 10_000 else {
            throw modelingError("bevel.budget", "Bevel input is limited to 10000 polygon faces.")
        }
        if selection?.isEmpty == true { return self }
        let prepared = try coalescingBevelFaces(excluding: Set(selection ?? []))
        return try prepared.applyingBevel(
            edges: selection, width: width, segments: segments, material: material)
    }

    private func applyingBevel(
        edges selection: [MeshEdge]?, width: Float, segments: Int,
        material: UInt32?
    ) throws -> Self {
        let selected = Set(try selection ?? selectEdges { ($0.angle ?? 0) > 0.0001 })
        if selected.isEmpty { return self }
        guard selection == nil || selected.count == selection!.count else {
            throw modelingError("bevel.selection", "Selected edges must be distinct.")
        }
        let sourceBounds = try renderMesh().bounds!
        let epsilon = GeometryTolerance().length(for: simd_length(sourceBounds.size))
        let normals = Dictionary(uniqueKeysWithValues: faceIDs.map { ($0, faceNormal(faces[$0]!)) })
        var sides: [MeshEdge: [BevelSide]] = [:]
        for id in faceIDs {
            let face = faces[id]!
            let normal = normals[id]!
            let points = face.corners.map { positions[$0.vertex]! }
            guard points.allSatisfy({ abs(simd_dot($0 - points[0], normal)) <= epsilon }) else {
                throw modelingError("bevel.nonPlanar", "Bevel requires planar polygon faces.")
            }
            var inset: [SIMD3<Float>] = []
            for i in points.indices {
                let previous = (i + points.count - 1) % points.count
                let next = (i + 1) % points.count
                let incoming = unitVector(points[i] - points[previous])
                let outgoing = unitVector(points[next] - points[i])
                let n0 = simd_cross(normal, incoming)
                let n1 = simd_cross(normal, outgoing)
                let w0 =
                    selected.contains(
                        MeshEdge(face.corners[previous].vertex, face.corners[i].vertex))
                    ? width : 0
                let w1 =
                    selected.contains(MeshEdge(face.corners[i].vertex, face.corners[next].vertex))
                    ? width : 0
                let cosine = simd_dot(n0, n1)
                let determinant = 1 - cosine * cosine
                let delta: SIMD3<Float>
                if determinant < 1e-8 {
                    guard cosine > 0, abs(w0 - w1) <= epsilon else {
                        throw modelingError(
                            "bevel.collinear", "Collinear corners need matching edge offsets.")
                    }
                    delta = n0 * w0
                } else {
                    delta = (n0 * (w0 - cosine * w1) + n1 * (w1 - cosine * w0)) / determinant
                }
                inset.append(points[i] + delta)
            }
            for i in points.indices {
                let next = (i + 1) % points.count
                let a = face.corners[i]
                let b = face.corners[next]
                sides[MeshEdge(a.vertex, b.vertex), default: []].append(
                    BevelSide(face: id, a: a, b: b, start: inset[i], end: inset[next]))
            }
        }
        guard selected.allSatisfy({ sides[$0] != nil }) else {
            throw modelingError(
                "bevel.selection", "Every selected edge must exist in this topology.")
        }
        for edge in selected {
            let pair = sides[edge]!
            guard
                simd_length_squared(simd_cross(normals[pair[0].face]!, normals[pair[1].face]!))
                    > 1e-8
            else {
                throw modelingError(
                    "bevel.flatEdge", "Selected edges must separate noncoplanar, nonopposing faces."
                )
            }
        }
        // Unselected edges keep one shared span. Trim their ends consistently and let corner patches
        // connect neighboring offsets. This also handles edge selections ending on a side face.
        for edge in sides.keys.sorted() where !selected.contains(edge) {
            var pair = sides[edge]!
            let origin = positions[edge.start]!
            let end = positions[edge.end]!
            let direction = unitVector(end - origin)
            let length = simd_distance(origin, end)
            let lower = pair.map {
                simd_dot(($0.a.vertex == edge.start ? $0.start : $0.end) - origin, direction)
            }.max()!
            let upper = pair.map {
                simd_dot(($0.a.vertex == edge.end ? $0.start : $0.end) - origin, direction)
            }.min()!
            guard lower >= -epsilon, upper <= length + epsilon, upper - lower > epsilon else {
                throw modelingError(
                    "bevel.width",
                    "The requested bevel collapses or reverses an edge; reduce width.")
            }
            let a = origin + direction * lower
            let b = origin + direction * upper
            for i in pair.indices {
                pair[i].start = pair[i].a.vertex == edge.start ? a : b
                pair[i].end = pair[i].a.vertex == edge.start ? b : a
            }
            sides[edge] = pair
        }
        var builder = BevelBuilder(epsilon: epsilon)
        var faceSides: [FaceID: [VertexID: BevelSide]] = [:]
        for edge in sides.keys.sorted() {
            for side in sides[edge]! {
                let direction = unitVector(positions[side.b.vertex]! - positions[side.a.vertex]!)
                guard simd_dot(side.end - side.start, direction) > epsilon else {
                    throw modelingError(
                        "bevel.width",
                        "The requested bevel collapses or reverses an edge; reduce width.")
                }
                faceSides[side.face, default: [:]][side.a.vertex] = side
            }
        }
        for id in faceIDs {
            let face = faces[id]!
            var corners: [MeshCorner] = []
            for i in face.corners.indices {
                let current = face.corners[i]
                let previous = face.corners[(i + face.corners.count - 1) % face.corners.count]
                let before = faceSides[id]![previous.vertex]!
                let after = faceSides[id]![current.vertex]!
                corners.append(builder.corner(at: before.end, source: current))
                corners.append(builder.corner(at: after.start, source: current))
            }
            try builder.addFace(corners, material: face.materialIndex, expectedNormal: normals[id])
        }
        for edge in sides.keys.sorted() where selected.contains(edge) {
            let pair = sides[edge]!
            let a = pair[0]
            let b = pair[1]
            let direction = unitVector(positions[a.b.vertex]! - positions[a.a.vertex]!)
            let first = bevelArc(
                from: a.start, to: b.end, origin: positions[a.a.vertex]!,
                axis: direction, firstNormal: normals[a.face]!, secondNormal: normals[b.face]!,
                segments: segments)
            let last = bevelArc(
                from: a.end, to: b.start, origin: positions[a.b.vertex]!,
                axis: direction, firstNormal: normals[a.face]!, secondNormal: normals[b.face]!,
                segments: segments)
            var starts: [MeshCorner] = []
            var ends: [MeshCorner] = []
            for i in 0...segments {
                let t = Float(i) / Float(segments)
                var ca = a.a
                var cb = a.b
                ca.color = a.a.color.interpolated(to: b.b.color, fraction: t)
                cb.color = a.b.color.interpolated(to: b.a.color, fraction: t)
                ca.uv = a.a.uv * (1 - t) + b.b.uv * t
                cb.uv = a.b.uv * (1 - t) + b.a.uv * t
                starts.append(builder.corner(at: first[i], source: ca))
                ends.append(builder.corner(at: last[i], source: cb))
            }
            for i in 0..<segments {
                let slot = material ?? faces[a.face]!.materialIndex
                try builder.addFace([ends[i], starts[i], starts[i + 1]], material: slot)
                try builder.addFace([ends[i], starts[i + 1], ends[i + 1]], material: slot)
            }
        }
        try builder.closeCorners(material: material)
        let result = try builder.mesh()
        try result.validate(requireClosed: true)
        let rendered = try result.renderMesh()
        try validateBevelIntersections(rendered)
        return result
    }

    /// Remove triangulation diagonals before mitering. Preserve source vertex IDs, boundary
    /// attributes and material seams; do not turn a region with holes into an invalid polygon.
    private func coalescingBevelFaces(excluding selection: Set<MeshEdge>) throws -> Self {
        try validate(requireClosed: true)
        var result = self
        var changed = true
        while changed {
            changed = false
            let halves = try result.halfEdges()
            var processed: Set<FaceID> = []
            for half in halves {
                guard let opposite = half.oppositeFace, half.face < opposite,
                    !processed.contains(half.face), !processed.contains(opposite),
                    !selection.contains(MeshEdge(half.origin, half.destination)),
                    let a = result.faces[half.face], let b = result.faces[opposite],
                    a.materialIndex == b.materialIndex,
                    simd_dot(result.faceNormal(a), result.faceNormal(b)) > 1 - 1e-7
                else { continue }
                let planeOrigin = result.positions[a.corners[0].vertex]!
                let normal = result.faceNormal(a)
                let extent =
                    a.corners.map { simd_distance(result.positions[$0.vertex]!, planeOrigin) }.max()
                    ?? 1
                guard
                    b.corners.allSatisfy({
                        abs(simd_dot(result.positions[$0.vertex]! - planeOrigin, normal))
                            <= GeometryTolerance().length(for: extent)
                    })
                else { continue }
                let shared = Set(a.corners.map(\.vertex)).intersection(b.corners.map(\.vertex))
                guard
                    shared.allSatisfy({ id in
                        let x = a.corners.first { $0.vertex == id }!
                        let y = b.corners.first { $0.vertex == id }!
                        return x.uv == y.uv && x.color == y.color
                    })
                else { continue }
                var directed: [VertexID: MeshCorner] = [:]
                var duplicate = false
                for face in [a, b] {
                    for i in face.corners.indices {
                        let x = face.corners[i]
                        let y = face.corners[(i + 1) % face.corners.count]
                        let reversedInOther = (face.id == a.id ? b : a).corners.indices.contains {
                            j in
                            let other = face.id == a.id ? b : a
                            return other.corners[j].vertex == y.vertex
                                && other.corners[(j + 1) % other.corners.count].vertex == x.vertex
                        }
                        if reversedInOther { continue }
                        if directed[x.vertex] != nil { duplicate = true }
                        directed[x.vertex] = y
                    }
                }
                guard !duplicate, let start = directed.keys.min() else { continue }
                var current = start
                var ring: [MeshCorner] = []
                repeat {
                    guard let next = directed.removeValue(forKey: current) else { break }
                    ring.append(next)
                    current = next.vertex
                } while current != start
                guard current == start, directed.isEmpty, ring.count >= 3 else { continue }
                result.faces[a.id] = MeshFace(
                    id: a.id, corners: ring, materialIndex: a.materialIndex)
                result.faces.removeValue(forKey: b.id)
                processed.insert(a.id)
                processed.insert(b.id)
                changed = true
            }
        }
        return result
    }
}

private struct BevelSide {
    let face: FaceID
    let a: MeshCorner, b: MeshCorner
    var start: SIMD3<Float>, end: SIMD3<Float>
}

private func bevelArc(
    from a: SIMD3<Float>, to b: SIMD3<Float>, origin: SIMD3<Float>, axis: SIMD3<Float>,
    firstNormal: SIMD3<Float>, secondNormal: SIMD3<Float>, segments: Int
) -> [SIMD3<Float>] {
    guard segments > 1 else { return [a, b] }
    let da = simd_dot(a - origin, axis)
    let db = simd_dot(b - origin, axis)
    let pa = a - origin - axis * da
    let pb = b - origin - axis * db
    let dn = firstNormal - secondNormal
    let radius = simd_dot(pb - pa, dn) / simd_length_squared(dn)
    let center = pa + firstNormal * radius
    let ra = pa - center
    let rb = pb - center
    let angle = atan2(simd_dot(simd_cross(ra, rb), axis), simd_dot(ra, rb))
    return (0...segments).map { i in
        if i == 0 { return a }
        if i == segments { return b }
        let t = Float(i) / Float(segments)
        return origin + center + simd_quatf(angle: angle * t, axis: axis).act(ra) + axis
            * (da * (1 - t) + db * t)
    }
}

private struct BevelBuilder {
    let epsilon: Float
    var points: [SIMD3<Float>] = []
    var owners: [VertexID] = []
    var groups: [VertexID: [Int]] = [:]
    var polygons: [[MeshCorner]] = []
    var materials: [UInt32] = []

    mutating func corner(at point: SIMD3<Float>, source: MeshCorner) -> MeshCorner {
        let index: Int
        if let existing = groups[source.vertex]?.first(where: {
            simd_distance(points[$0], point) <= epsilon
        }) {
            index = existing
        } else {
            index = points.count
            points.append(point)
            owners.append(source.vertex)
            groups[source.vertex, default: []].append(index)
        }
        return MeshCorner(VertexID(index), uv: source.uv, color: source.color)
    }

    mutating func addFace(
        _ values: [MeshCorner], material: UInt32, expectedNormal: SIMD3<Float>? = nil
    ) throws {
        var corners: [MeshCorner] = []
        for corner in values where corner.vertex != corners.last?.vertex { corners.append(corner) }
        if corners.first?.vertex == corners.last?.vertex { corners.removeLast() }
        guard corners.count >= 3 else {
            throw modelingError("bevel.degenerate", "The bevel produced a collapsed face.")
        }
        if let normal = expectedNormal {
            let origin = points[corners[0].vertex.rawValue]
            var area = SIMD3<Float>.zero
            for i in corners.indices {
                area += simd_cross(
                    points[corners[i].vertex.rawValue] - origin,
                    points[corners[(i + 1) % corners.count].vertex.rawValue] - origin)
            }
            guard simd_dot(area, normal) > epsilon * epsilon else {
                throw modelingError(
                    "bevel.width", "The requested bevel reverses or collapses a face; reduce width."
                )
            }
        }
        polygons.append(corners)
        materials.append(material)
    }

    mutating func closeCorners(material: UInt32?) throws {
        struct Boundary {
            let a: MeshCorner, b: MeshCorner
            let material: UInt32
        }
        var uses: [MeshEdge: [Boundary]] = [:]
        for (f, corners) in polygons.enumerated() {
            for i in corners.indices {
                let a = corners[i]
                let b = corners[(i + 1) % corners.count]
                uses[MeshEdge(a.vertex, b.vertex), default: []].append(
                    Boundary(a: a, b: b, material: materials[f]))
            }
        }
        var boundary: [VertexID: Boundary] = [:]
        for edge in uses.keys.sorted() where uses[edge]!.count == 1 {
            let use = uses[edge]![0]
            guard owners[use.a.vertex.rawValue] == owners[use.b.vertex.rawValue],
                boundary[use.b.vertex] == nil
            else {
                throw modelingError(
                    "bevel.corner", "The bevel corner cannot be closed as a simple boundary.")
            }
            boundary[use.b.vertex] = Boundary(a: use.b, b: use.a, material: use.material)
        }
        while let first = boundary.keys.min() {
            var current = first
            var ring: [MeshCorner] = []
            let slot = material ?? boundary[first]!.material
            repeat {
                guard let edge = boundary.removeValue(forKey: current) else {
                    throw modelingError(
                        "bevel.corner", "The bevel corner boundary is not a closed loop.")
                }
                ring.append(edge.a)
                current = edge.b.vertex
            } while current != first
            if ring.count == 3 {
                try addFace(ring, material: slot)
            } else {
                let count = Float(ring.count)
                let center =
                    ring.reduce(SIMD3<Float>.zero) { $0 + points[$1.vertex.rawValue] } / count
                let color = ring.reduce(SIMD4<Float>.zero) { $0 + $1.color.linearRGBA } / count
                let uv = ring.reduce(SIMD2<Float>.zero) { $0 + $1.uv } / count
                let centerCorner = MeshCorner(
                    VertexID(points.count), uv: uv,
                    color: RGBAColor(linearSRGB: SIMD3(color.x, color.y, color.z), alpha: color.w))
                points.append(center)
                owners.append(owners[ring[0].vertex.rawValue])
                for i in ring.indices {
                    try addFace(
                        [centerCorner, ring[i], ring[(i + 1) % ring.count]], material: slot)
                }
            }
        }
    }

    func mesh() throws -> EditableMesh {
        var result = try EditableMesh(
            positions: points, polygons: polygons.map { $0.map { $0.vertex.rawValue } },
            materialIndices: materials)
        for (i, corners) in polygons.enumerated() { result.faces[FaceID(i)]!.corners = corners }
        return result
    }
}

/// A sweep broad phase limits exact tests to overlapping bounds. This rejects crossing faces,
/// rather than returning a manifold-looking mesh with hidden self-intersections.
private func validateBevelIntersections(_ mesh: MeshData) throws {
    let triangles = (0..<mesh.triangleCount).map { t in
        (0..<3).map { mesh.vertices[Int(mesh.indices[t * 3 + $0])].position }
    }
    let minimum = triangles.map { $0.reduce(SIMD3<Float>(repeating: .infinity), simd_min) }
    let maximum = triangles.map { $0.reduce(SIMD3<Float>(repeating: -.infinity), simd_max) }
    let order = triangles.indices.sorted {
        minimum[$0].x == minimum[$1].x ? $0 < $1 : minimum[$0].x < minimum[$1].x
    }
    var checks = 0
    for i in order.indices {
        let a = order[i]
        var j = i + 1
        while j < order.count && minimum[order[j]].x <= maximum[a].x {
            let b = order[j]
            j += 1
            if minimum[a].y > maximum[b].y || minimum[b].y > maximum[a].y
                || minimum[a].z > maximum[b].z || minimum[b].z > maximum[a].z
            {
                continue
            }
            checks += 1
            guard checks <= 5_000_000 else {
                throw modelingError(
                    "bevel.intersectionBudget",
                    "Bevel intersection validation exceeded its budget; split the mesh.")
            }
            if bevelTrianglesCross(triangles[a], triangles[b]) {
                throw modelingError(
                    "bevel.selfIntersection",
                    "Output triangles \(a) and \(b) intersect; reduce width or change the selection."
                )
            }
        }
    }
}

private func bevelTrianglesCross(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Bool {
    let normal = unitVector(simd_cross(a[1] - a[0], a[2] - a[0]))
    let extent = max(simd_distance(a[0], a[1]), simd_distance(a[0], a[2]))
    if b.allSatisfy({ abs(simd_dot($0 - a[0], normal)) <= extent * 1e-6 }) {
        let x = orthogonal(to: normal)
        let y = simd_cross(normal, x)
        func project(_ points: [SIMD3<Float>]) -> [SIMD2<Float>] {
            points.map { SIMD2(simd_dot($0 - a[0], x), simd_dot($0 - a[0], y)) }
        }
        return atlasTrianglesOverlap(project(a), project(b))
    }
    let otherNormal = unitVector(simd_cross(b[1] - b[0], b[2] - b[0]))
    let tolerance = GeometryTolerance().length(for: max(extent, simd_distance(b[0], b[1])))
    let distancesA = a.map { simd_dot($0 - b[0], otherNormal) }
    let distancesB = b.map { simd_dot($0 - a[0], normal) }
    // Faces meeting only at an existing boundary are not crossings. This scale-aware
    // plane test also avoids unstable near-parallel segment/triangle intersections.
    guard distancesA.min()! < -tolerance, distancesA.max()! > tolerance,
        distancesB.min()! < -tolerance, distancesB.max()! > tolerance
    else { return false }
    for (edges, triangle) in [(a, b), (b, a)] {
        let e1 = triangle[1] - triangle[0]
        let e2 = triangle[2] - triangle[0]
        for i in 0..<3 {
            let origin = edges[i]
            let direction = edges[(i + 1) % 3] - origin
            let h = simd_cross(direction, e2)
            let determinant = simd_dot(e1, h)
            if abs(determinant) <= 1e-7 * simd_length(direction) * simd_length(e1) * simd_length(e2)
            {
                continue
            }
            let s = origin - triangle[0]
            let q = simd_cross(s, e1)
            let u = simd_dot(s, h) / determinant
            let v = simd_dot(direction, q) / determinant
            let t = simd_dot(e2, q) / determinant
            if u > 1e-6 && v > 1e-6 && u + v < 1 - 1e-6 && t > 1e-6 && t < 1 - 1e-6 { return true }
        }
    }
    return false
}
