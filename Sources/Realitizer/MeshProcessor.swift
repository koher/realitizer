import simd

/// Render-stage processing with explicit correspondence. Shape-building APIs return plain MeshData.
public enum MeshProcessor {
    public static func recalculateNormals(of mesh: MeshData, smoothingAngle: Float = .pi) throws
        -> MeshProcessingResult
    {
        _ = try mesh.validated()
        guard smoothingAngle.isFinite, (0...Float.pi).contains(smoothingAngle) else {
            throw modelingError("normals.angle", "Smoothing angle must be finite and in [0, pi].")
        }
        var normals: [SIMD3<Float>] = []
        var adjacent: [SIMD3<Float>: Set<Int>] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let points = (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])].position }
            normals.append(simd_cross(points[1] - points[0], points[2] - points[0]))
            for p in points { adjacent[p, default: []].insert(i / 3) }
        }
        struct CornerKey: Hashable {
            let source: Int
            let normal: SIMD3<Float>
        }
        let threshold = cos(smoothingAngle)
        var lookup: [CornerKey: UInt32] = [:]
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var sources: [Int] = []
        for (corner, index) in mesh.indices.enumerated() {
            var vertex = mesh.vertices[Int(index)]
            let face = unitVector(normals[corner / 3])
            let sum = adjacent[vertex.position, default: []].sorted().reduce(SIMD3<Float>.zero) {
                sum, neighbor in
                let candidate = normals[neighbor]
                return simd_dot(unitVector(candidate), face) >= threshold - 1e-6 ? sum + candidate : sum
            }
            vertex.normal = unitVector(sum, fallback: face)
            let key = CornerKey(source: Int(index), normal: vertex.normal)
            if let existing = lookup[key] {
                indices.append(existing)
            } else {
                let output = UInt32(vertices.count)
                lookup[key] = output
                vertex.tangent = SIMD4(orthogonal(to: vertex.normal), 1)
                vertices.append(vertex)
                sources.append(Int(index))
                indices.append(output)
            }
        }
        let result = try MeshData(
            vertices: vertices, indices: indices, materialIndices: mesh.materialIndices
        ).generatingTangents()
        return try MeshProcessingResult(source: mesh, mesh: result, sourceIndices: sources)
    }

    public static func projectUV(of mesh: MeshData, using projection: UVProjection) throws
        -> MeshProcessingResult
    {
        _ = try mesh.validated()
        var vertices = mesh.vertices
        var angularScale: Float = 1
        for i in vertices.indices {
            let p = vertices[i].position
            switch projection {
            case .planar(let horizontal, let vertical, let scale):
                guard horizontal != vertical, scale.isFinite else {
                    throw modelingError("uv.planar", "Planar axes must differ and scale must be finite.")
                }
                vertices[i].textureCoordinate = SIMD2(p[horizontal.rawValue], p[vertical.rawValue]) * scale
            case .cylindrical(let axis, let scale):
                guard scale.isFinite, scale.x != 0 else {
                    throw modelingError(
                        "uv.scale", "Cylindrical UV scale must be finite with nonzero horizontal scale.")
                }
                angularScale = scale.x
                let a = (axis.rawValue + 1) % 3
                let b = (axis.rawValue + 2) % 3
                vertices[i].textureCoordinate =
                    SIMD2(atan2(p[b], p[a]) / (2 * .pi) + 0.5, p[axis.rawValue]) * scale
            case .spherical:
                let n = unitVector(p)
                vertices[i].textureCoordinate = SIMD2(
                    atan2(n.z, n.x) / (2 * .pi) + 0.5, acos(min(max(n.y, -1), 1)) / .pi)
            }
        }
        var sources = Array(vertices.indices)
        var indices = mesh.indices
        if case .planar = projection {
            // No seam split is needed.
        } else {
            var shifted: [UInt32: UInt32] = [:]
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                let ids = Array(mesh.indices[i..<(i + 3)])
                let us = ids.map { vertices[Int($0)].textureCoordinate.x / angularScale }
                guard (us.max() ?? 0) - (us.min() ?? 0) > 0.5 else { continue }
                for j in 0..<3 where us[j] < 0.5 {
                    let source = ids[j]
                    if let existing = shifted[source] {
                        indices[i + j] = existing
                    } else {
                        let newIndex = UInt32(vertices.count)
                        var vertex = vertices[Int(source)]
                        vertex.textureCoordinate.x += angularScale
                        vertices.append(vertex)
                        sources.append(Int(source))
                        shifted[source] = newIndex
                        indices[i + j] = newIndex
                    }
                }
            }
        }
        let result = try MeshData(
            vertices: vertices, indices: indices, materialIndices: mesh.materialIndices
        ).generatingTangents()
        return try MeshProcessingResult(source: mesh, mesh: result, sourceIndices: sources)
    }
}
