import simd

extension MeshBuilder {
    /// Incremental, outward-wound convex hull. Input must span a three-dimensional volume.
    public static func convexHull(points input: [SIMD3<Float>], tolerance: GeometryTolerance = GeometryTolerance())
        throws -> MeshData
    {
        guard (4...4096).contains(input.count), input.allSatisfy(\.isFinite) else {
            throw modelingError("hull.input", "Convex hulls require 4...4096 finite points.")
        }
        var seen: Set<SIMD3<Float>> = []
        let points = input.filter { seen.insert($0).inserted }
        guard points.count >= 4 else {
            throw modelingError("hull.uniquePoints", "Convex hulls require at least four unique points.")
        }
        let extent = simd_length(points.reduce(points[0], simd_max) - points.reduce(points[0], simd_min))
        let epsilon = tolerance.length(for: extent)
        let a = 0
        let b = points.indices.max {
            simd_distance_squared(points[a], points[$0]) < simd_distance_squared(points[a], points[$1])
        }!
        let axis = unitVector(points[b] - points[a])
        let c = points.indices.max {
            simd_length_squared(simd_cross(points[$0] - points[a], axis))
                < simd_length_squared(simd_cross(points[$1] - points[a], axis))
        }!
        let normal = unitVector(simd_cross(points[b] - points[a], points[c] - points[a]))
        let d = points.indices.max {
            abs(simd_dot(points[$0] - points[a], normal)) < abs(simd_dot(points[$1] - points[a], normal))
        }!
        guard Set([a, b, c, d]).count == 4, abs(simd_dot(points[d] - points[a], normal)) > epsilon else {
            throw modelingError("hull.coplanar", "Convex hull points must enclose a nonzero volume.")
        }
        let interior = (points[a] + points[b] + points[c] + points[d]) / 4
        func oriented(_ face: SIMD3<Int>) -> SIMD3<Int> {
            let p = points[face.x]
            let n = simd_cross(points[face.y] - p, points[face.z] - p)
            return simd_dot(n, interior - p) > 0 ? SIMD3(face.x, face.z, face.y) : face
        }
        var faces = [SIMD3(a, b, c), SIMD3(a, d, b), SIMD3(b, d, c), SIMD3(c, d, a)].map(oriented)
        for index in points.indices where ![a, b, c, d].contains(index) {
            let visible = Set(
                faces.indices.filter { i in
                    let f = faces[i]
                    let p = points[f.x]
                    return simd_dot(unitVector(simd_cross(points[f.y] - p, points[f.z] - p)), points[index] - p)
                        > epsilon
                })
            if visible.isEmpty { continue }
            var horizon: [SIMD2<Int>: SIMD2<Int>] = [:]
            for i in visible.sorted() {
                let f = faces[i]
                for edge in [SIMD2(f.x, f.y), SIMD2(f.y, f.z), SIMD2(f.z, f.x)] {
                    let key = SIMD2(min(edge.x, edge.y), max(edge.x, edge.y))
                    if horizon.removeValue(forKey: key) == nil { horizon[key] = edge }
                }
            }
            faces = faces.enumerated().filter { !visible.contains($0.offset) }.map(\.element)
            for key in horizon.keys.sorted(by: { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }) {
                let edge = horizon[key]!
                faces.append(oriented(SIMD3(edge.x, edge.y, index)))
            }
        }
        var builder = MeshBuilder()
        for face in faces { builder.addTriangle(points[face.x], points[face.y], points[face.z]) }
        return try builder.build().generatingTangents()
    }
}
