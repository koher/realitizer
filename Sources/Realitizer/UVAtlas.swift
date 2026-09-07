import simd

/// Deterministic, angle-bounded chart projection followed by a single square atlas pack.
/// This is automatic charting, not a conformal or artist-authored seam solver.
public struct UVUnwrapOptions: Sendable {
    /// Every triangle normal stays within this angle of its chart's seed normal.
    public var maximumNormalDeviation: Float
    /// Reserved border on every side of every island, in normalized atlas units.
    /// A four-pixel gutter at 1024 pixels is 4 / 1024. Adjacent islands have two gutters.
    public var padding: Float
    public var welding: TopologyWelding
    public var respectMaterialBoundaries: Bool

    public init(
        maximumNormalDeviation: Float = .pi / 4, padding: Float = 0.005,
        welding: TopologyWelding = .exactPositions, respectMaterialBoundaries: Bool = true
    ) {
        self.maximumNormalDeviation = maximumNormalDeviation
        self.padding = padding
        self.welding = welding
        self.respectMaterialBoundaries = respectMaterialBoundaries
    }
}

public struct UVIsland: Sendable {
    /// Triangle indices in the source mesh. The operation retains triangle order and material slots.
    public let triangles: [Int]
    /// Tight UV rectangle, excluding the reserved gutter.
    public let minimum: SIMD2<Float>
    public let maximum: SIMD2<Float>
}

public struct UVAtlas: Sendable {
    public let processing: MeshProcessingResult
    public let islands: [UVIsland]
    /// Shared UV units per projected model-space meter; islands are never independently stretched.
    public let scale: Float
}

extension MeshData {
    public func unwrappingUV(_ options: UVUnwrapOptions = .init()) throws -> Self {
        try MeshProcessor.unwrapUV(of: self, options: options).processing.mesh
    }
}

extension ModelGeometry {
    public func unwrappingUV(_ options: UVUnwrapOptions = .init()) throws -> Self {
        try applying(MeshProcessor.unwrapUV(of: mesh, options: options).processing)
    }
}

extension MeshProcessor {
    /// Charts connected triangles without projection overlap, then packs nonoverlapping rectangles.
    /// Seams duplicate vertices through the same checked map used by skin and morph processing.
    public static func unwrapUV(of mesh: MeshData, options: UVUnwrapOptions = .init()) throws
        -> UVAtlas
    {
        _ = try mesh.validated()
        guard options.maximumNormalDeviation.isFinite,
            (0..<Float.pi / 2).contains(options.maximumNormalDeviation),
            options.padding.isFinite, (0..<0.5).contains(options.padding)
        else {
            throw modelingError(
                "uv.options", "Chart angle must be in [0, pi/2) and padding in [0, 0.5).")
        }
        guard mesh.triangleCount <= 100_000 else {
            throw modelingError("uv.budget", "Automatic UV input is limited to 100000 triangles.")
        }
        let triangles = (0..<mesh.triangleCount).map { i in
            (0..<3).map { mesh.vertices[Int(mesh.indices[i * 3 + $0])].position }
        }
        let normals = triangles.map { unitVector(simd_cross($0[1] - $0[0], $0[2] - $0[0])) }
        let areas = triangles.map { simd_length(simd_cross($0[1] - $0[0], $0[2] - $0[0])) }
        let order = triangles.indices.sorted {
            areas[$0] == areas[$1] ? $0 < $1 : areas[$0] > areas[$1]
        }
        var weldLookup: [SIMD3<Float>: Int] = [:]
        let vertexIDs = mesh.vertices.enumerated().map { i, vertex -> Int in
            guard case .exactPositions = options.welding else { return i }
            if let id = weldLookup[vertex.position] { return id }
            weldLookup[vertex.position] = i
            return i
        }
        var edgeUses: [AtlasEdge: [(triangle: Int, origin: Int)]] = [:]
        for t in triangles.indices {
            for c in 0..<3 {
                let a = vertexIDs[Int(mesh.indices[t * 3 + c])]
                let b = vertexIDs[Int(mesh.indices[t * 3 + (c + 1) % 3])]
                edgeUses[AtlasEdge(a, b), default: []].append((t, a))
            }
        }
        var neighbors = [[Int]](repeating: [], count: triangles.count)
        for uses in edgeUses.values where uses.count == 2 && uses[0].origin != uses[1].origin {
            let a = uses[0].triangle
            let b = uses[1].triangle
            if options.respectMaterialBoundaries && !mesh.materialIndices.isEmpty
                && mesh.materialIndices[a] != mesh.materialIndices[b]
            {
                continue
            }
            neighbors[a].append(b)
            neighbors[b].append(a)
        }
        for i in neighbors.indices { neighbors[i].sort() }
        var assigned = [Bool](repeating: false, count: triangles.count)
        var charts: [AtlasChart] = []
        var overlapChecks = 0
        let threshold = cos(options.maximumNormalDeviation)
        for seed in order where !assigned[seed] {
            let normal = normals[seed]
            let origin = triangles[seed][0]
            let x = orthogonal(to: normal)
            let y = simd_cross(normal, x)
            func project(_ t: Int) -> [SIMD2<Float>] {
                triangles[t].map { SIMD2(simd_dot($0 - origin, x), simd_dot($0 - origin, y)) }
            }
            var chart = AtlasChart(origin: origin, x: x, y: y)
            var queue = [seed]
            var visited: Set<Int> = [seed]
            var cursor = 0
            while cursor < queue.count {
                let t = queue[cursor]
                cursor += 1
                guard !assigned[t], simd_dot(normal, normals[t]) >= threshold - 1e-6 else {
                    continue
                }
                let projected = project(t)
                var overlaps = false
                for existing in chart.projections {
                    overlapChecks += 1
                    guard overlapChecks <= 20_000_000 else {
                        throw modelingError(
                            "uv.chartBudget",
                            "Chart overlap checks exceeded the budget; split the input mesh.")
                    }
                    if atlasTrianglesOverlap(projected, existing) {
                        overlaps = true
                        break
                    }
                }
                if overlaps { continue }
                assigned[t] = true
                chart.triangles.append(t)
                chart.projections.append(projected)
                for point in projected {
                    chart.minimum = simd_min(chart.minimum, point)
                    chart.maximum = simd_max(chart.maximum, point)
                }
                for neighbor in neighbors[t]
                where !assigned[neighbor] && visited.insert(neighbor).inserted {
                    queue.append(neighbor)
                }
            }
            charts.append(chart)
        }
        let packingOrder = charts.indices.sorted { a, b in
            let sa = charts[a].size
            let sb = charts[b].size
            return sa.y == sb.y ? (sa.x == sb.x ? a < b : sa.x > sb.x) : sa.y > sb.y
        }
        func pack(_ scale: Float) -> [SIMD2<Float>]? {
            var origins = [SIMD2<Float>](repeating: .zero, count: charts.count)
            var x: Float = 0
            var y: Float = 0
            var rowHeight: Float = 0
            for index in packingOrder {
                let size = charts[index].size * scale + SIMD2(repeating: 2 * options.padding)
                if x + size.x > 1 {
                    x = 0
                    y += rowHeight
                    rowHeight = 0
                }
                guard size.x <= 1, y + size.y <= 1 else { return nil }
                origins[index] = SIMD2(x, y) + SIMD2(repeating: options.padding)
                x += size.x
                rowHeight = max(rowHeight, size.y)
            }
            return origins
        }
        guard pack(0) != nil else {
            throw modelingError(
                "uv.padding",
                "Island gutters do not fit in one atlas; reduce padding or split the mesh.")
        }
        let largest = charts.map { max($0.size.x, $0.size.y) }.max()!
        var lower: Float = 0
        var upper: Float = 1 / largest
        for _ in 0..<32 {
            let middle = (lower + upper) * 0.5
            if pack(middle) != nil { lower = middle } else { upper = middle }
        }
        guard lower.isFinite, lower > 0, let origins = pack(lower) else {
            throw modelingError(
                "uv.pack", "No positive atlas scale fits with the requested gutters.")
        }
        struct VertexKey: Hashable {
            let source: UInt32
            let chart: Int
        }
        var lookup: [VertexKey: UInt32] = [:]
        var vertices: [MeshVertex] = []
        var sources: [Int] = []
        var indices = mesh.indices
        var islands: [UVIsland] = []
        for (c, chart) in charts.enumerated() {
            for t in chart.triangles.sorted() {
                for corner in 0..<3 {
                    let source = mesh.indices[t * 3 + corner]
                    let key = VertexKey(source: source, chart: c)
                    if let index = lookup[key] {
                        indices[t * 3 + corner] = index
                        continue
                    }
                    var vertex = mesh.vertices[Int(source)]
                    let p = vertex.position - chart.origin
                    let projected = SIMD2(simd_dot(p, chart.x), simd_dot(p, chart.y))
                    vertex.textureCoordinate = (projected - chart.minimum) * lower + origins[c]
                    let index = UInt32(vertices.count)
                    lookup[key] = index
                    indices[t * 3 + corner] = index
                    vertices.append(vertex)
                    sources.append(Int(source))
                }
            }
            islands.append(
                UVIsland(
                    triangles: chart.triangles.sorted(), minimum: origins[c],
                    maximum: origins[c] + chart.size * lower))
        }
        let output = try MeshData(
            vertices: vertices, indices: indices, materialIndices: mesh.materialIndices
        )
        .generatingTangents()
        return try UVAtlas(
            processing: MeshProcessingResult(source: mesh, mesh: output, sourceIndices: sources),
            islands: islands, scale: lower)
    }
}

private struct AtlasEdge: Hashable {
    let a: Int, b: Int
    init(_ a: Int, _ b: Int) {
        self.a = min(a, b)
        self.b = max(a, b)
    }
}

private struct AtlasChart {
    let origin: SIMD3<Float>, x: SIMD3<Float>, y: SIMD3<Float>
    var triangles: [Int] = []
    var projections: [[SIMD2<Float>]] = []
    var minimum = SIMD2<Float>(repeating: .infinity)
    var maximum = SIMD2<Float>(repeating: -.infinity)
    var size: SIMD2<Float> { maximum - minimum }
}

/// Strict interior overlap by the separating-axis theorem. Shared edges/vertices are allowed.
func atlasTrianglesOverlap(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Bool {
    for polygon in [a, b] {
        for i in 0..<3 {
            let edge = polygon[(i + 1) % 3] - polygon[i]
            let axis = SIMD2(-edge.y, edge.x)
            let pa = a.map { simd_dot($0, axis) }
            let pb = b.map { simd_dot($0, axis) }
            let tolerance = simd_length_squared(edge) * 1e-6
            if min(pa.max()!, pb.max()!) - max(pa.min()!, pb.min()!) <= tolerance { return false }
        }
    }
    return true
}
