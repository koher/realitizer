import simd

/// A closed set of reproducible distance-field operations. Negative values are inside.
public indirect enum DistanceField: Sendable, Codable {
    case sphere(center: SIMD3<Float>, radius: Float)
    case box(center: SIMD3<Float>, halfSize: SIMD3<Float>, rounding: Float)
    case capsule(start: SIMD3<Float>, end: SIMD3<Float>, radius: Float)
    case union(DistanceField, DistanceField)
    case intersection(DistanceField, DistanceField)
    case subtraction(DistanceField, DistanceField)
    case smoothUnion(DistanceField, DistanceField, radius: Float)

    public func value(at p: SIMD3<Float>) -> Float {
        switch self {
        case .sphere(let center, let radius): return simd_distance(p, center) - radius
        case .box(let center, let halfSize, let rounding):
            let q = simd_abs(p - center) - halfSize + SIMD3(repeating: rounding)
            return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y, q.z), 0) - rounding
        case .capsule(let start, let end, let radius):
            let axis = end - start
            let length = simd_length_squared(axis)
            let t = length > 0 ? min(max(simd_dot(p - start, axis) / length, 0), 1) : 0
            return simd_distance(p, start + axis * t) - radius
        case .union(let a, let b): return min(a.value(at: p), b.value(at: p))
        case .intersection(let a, let b): return max(a.value(at: p), b.value(at: p))
        case .subtraction(let a, let b): return max(a.value(at: p), -b.value(at: p))
        case .smoothUnion(let a, let b, let radius):
            let x = a.value(at: p)
            let y = b.value(at: p)
            guard radius > 0 else { return min(x, y) }
            let h = max(radius - abs(x - y), 0) / radius
            return min(x, y) - h * h * radius * 0.25
        }
    }

    public func mesh(in bounds: MeshBounds, resolution: Int = 32) throws -> MeshData {
        try validate()
        return try ImplicitSurface.mesh(in: bounds, resolution: resolution) { value(at: $0) }
    }

    public func validate() throws {
        var pending: [(DistanceField, Int)] = [(self, 0)]
        var operations = 0
        while let (field, depth) = pending.popLast() {
            operations += 1
            guard operations <= 1024, depth <= 32 else {
                throw modelingError(
                    "field.complexity", "Distance fields support up to 1024 operations and 32 nested levels.")
            }
            switch field {
            case .sphere(let center, let radius):
                guard center.isFinite, radius.isFinite, radius > 0 else {
                    throw modelingError("field.sphere", "Sphere center must be finite and radius positive.")
                }
            case .box(let center, let halfSize, let rounding):
                guard center.isFinite, halfSize.isFinite, min(halfSize.x, halfSize.y, halfSize.z) > 0,
                    rounding.isFinite, rounding >= 0, rounding <= min(halfSize.x, halfSize.y, halfSize.z)
                else {
                    throw modelingError(
                        "field.box", "Box extents must be positive and rounding must fit inside the box.")
                }
            case .capsule(let start, let end, let radius):
                guard start.isFinite, end.isFinite, radius.isFinite, radius > 0 else {
                    throw modelingError(
                        "field.capsule", "Capsule endpoints must be finite and radius positive.")
                }
            case .union(let a, let b), .intersection(let a, let b), .subtraction(let a, let b):
                pending += [(a, depth + 1), (b, depth + 1)]
            case .smoothUnion(let a, let b, let radius):
                guard radius.isFinite, radius > 0 else {
                    throw modelingError("field.smoothing", "Smooth union radius must be positive and finite.")
                }
                pending += [(a, depth + 1), (b, depth + 1)]
            }
        }
    }
}

public enum MeshBooleanOperation: String, Sendable, Codable {
    case union, intersection, subtraction
}

/// Deterministic marching tetrahedra with gradient normals. The extraction bounds must enclose the surface.
public enum ImplicitSurface {
    public static func mesh(
        in bounds: MeshBounds, resolution: Int = 32, maximumVertices: Int = 500_000,
        field: (SIMD3<Float>) -> Float
    ) throws -> MeshData {
        guard (4...128).contains(resolution), bounds.minimum.isFinite, bounds.maximum.isFinite,
            bounds.size.x > 0, bounds.size.y > 0, bounds.size.z > 0
        else {
            throw modelingError(
                "implicit.grid",
                "Resolution must be between 4 and 128 and bounds must have positive finite extent.")
        }
        guard maximumVertices > 0 else {
            throw modelingError("implicit.budget", "The output vertex budget must be positive.")
        }
        let n = resolution + 1
        let step = bounds.size / Float(resolution)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * n + y) * n + x }
        func point(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            bounds.minimum + SIMD3(Float(x), Float(y), Float(z)) * step
        }
        var values = Array(repeating: Float(0), count: n * n * n)
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let value = field(point(x, y, z))
                    guard value.isFinite else {
                        throw modelingError("implicit.nonFinite", "Distance field returned a non-finite value.")
                    }
                    if (x == 0 || y == 0 || z == 0 || x == resolution || y == resolution || z == resolution)
                        && value <= 0
                    {
                        throw modelingError(
                            "implicit.clipped", "Extraction bounds must lie outside the entire surface.")
                    }
                    values[index(x, y, z)] = value
                }
            }
        }
        let offsets = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        let tetrahedra = [
            [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
        ]
        let edgePairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
        let h = min(step.x, step.y, step.z) * 0.1
        func normal(_ p: SIMD3<Float>) throws -> SIMD3<Float> {
            let gradient = SIMD3(
                field(p + SIMD3(h, 0, 0)) - field(p - SIMD3(h, 0, 0)),
                field(p + SIMD3(0, h, 0)) - field(p - SIMD3(0, h, 0)),
                field(p + SIMD3(0, 0, h)) - field(p - SIMD3(0, 0, h)))
            guard gradient.isFinite, simd_length_squared(gradient) > 1e-20 else {
                throw modelingError("implicit.gradient", "Surface gradients must be finite and nonzero.")
            }
            return unitVector(gradient)
        }
        var vertices: [MeshVertex] = []
        for z in 0..<resolution {
            for y in 0..<resolution {
                for x in 0..<resolution {
                    let points = offsets.map { point(x + $0.0, y + $0.1, z + $0.2) }
                    let samples = offsets.map { values[index(x + $0.0, y + $0.1, z + $0.2)] }
                    for tetra in tetrahedra {
                        var polygon: [SIMD3<Float>] = []
                        for (a, b) in edgePairs {
                            let i = tetra[a]
                            let j = tetra[b]
                            let va = samples[i]
                            let vb = samples[j]
                            if (va < 0) == (vb < 0) { continue }
                            let p = simd_mix(points[i], points[j], SIMD3(repeating: va / (va - vb)))
                            if !polygon.contains(where: { simd_distance_squared($0, p) < h * h * 1e-10 }) {
                                polygon.append(p)
                            }
                        }
                        guard polygon.count >= 3 else { continue }
                        let center = polygon.reduce(.zero, +) / Float(polygon.count)
                        let n = try normal(center)
                        let u = orthogonal(to: n)
                        let v = simd_cross(n, u)
                        polygon.sort { a, b in
                            atan2(simd_dot(a - center, v), simd_dot(a - center, u))
                                < atan2(simd_dot(b - center, v), simd_dot(b - center, u))
                        }
                        for i in 1..<(polygon.count - 1) {
                            let tri = [polygon[0], polygon[i], polygon[i + 1]]
                            if simd_length(simd_cross(tri[1] - tri[0], tri[2] - tri[0])) <= 1e-12 { continue }
                            guard vertices.count <= maximumVertices - 3 else {
                                throw modelingError(
                                    "implicit.outputBudget", "Extracted surface exceeds the output vertex budget.")
                            }
                            for p in tri {
                                vertices.append(
                                    try MeshVertex(position: p, normal: normal(p), textureCoordinate: [p.x, p.z]))
                            }
                        }
                    }
                }
            }
        }
        return try MeshData(vertices: vertices, indices: vertices.indices.map(UInt32.init))
            .generatingTangents()
            .validated()
    }
}

extension MeshData {
    /// Voxel-resolution boolean for closed triangle meshes; intentionally not an exact CAD boolean.
    public func boolean(_ operation: MeshBooleanOperation, with other: Self, resolution: Int = 24)
        throws -> Self
    {
        try requireUncoloredForResampling()
        try other.requireUncoloredForResampling()
        try validateSamplingBudget(
            resolution: resolution, triangles: triangleCount + other.triangleCount)
        let left = try TriangleDistanceField(self)
        let right = try TriangleDistanceField(other)
        guard let a = bounds, let b = other.bounds else {
            throw modelingError("boolean.bounds", "Both operands must have bounds.")
        }
        let minimum = simd_min(a.minimum, b.minimum)
        let maximum = simd_max(a.maximum, b.maximum)
        let padding = simd_length(maximum - minimum) * 0.1
        return try ImplicitSurface.mesh(
            in: MeshBounds(
                minimum: minimum - SIMD3(repeating: padding), maximum: maximum + SIMD3(repeating: padding)),
            resolution: resolution
        ) { p in
            let a = left.value(at: p)
            let b = right.value(at: p)
            switch operation {
            case .union: return min(a, b)
            case .intersection: return max(a, b)
            case .subtraction: return max(a, -b)
            }
        }
    }

    public func remeshed(resolution: Int = 24) throws -> Self {
        try requireUncoloredForResampling()
        try validateSamplingBudget(resolution: resolution, triangles: triangleCount)
        let field = try TriangleDistanceField(self)
        guard let bounds else { throw modelingError("remesh.bounds", "Mesh must have bounds.") }
        let padding = simd_length(bounds.size) * 0.1
        return try ImplicitSurface.mesh(
            in: MeshBounds(
                minimum: bounds.minimum - SIMD3(repeating: padding),
                maximum: bounds.maximum + SIMD3(repeating: padding)
            ), resolution: resolution
        ) { field.value(at: $0) }
    }

    private func requireUncoloredForResampling() throws {
        guard vertices.allSatisfy({ simd_distance($0.color.linearRGBA, .one) < 1e-6 }) else {
            throw modelingError("remesh.vertexColor", "Resampling does not infer color correspondence. Apply colors afterward, or explicitly clear them with coloring { _ in .white }.")
        }
    }
}

private func validateSamplingBudget(resolution: Int, triangles: Int) throws {
    guard (4...128).contains(resolution),
        triangles <= 50_000_000 / ((resolution + 1) * (resolution + 1) * (resolution + 1))
    else {
        throw modelingError(
            "boolean.samplingBudget",
            "Voxel operations exceed the triangle/grid sampling budget; simplify operands or lower resolution."
        )
    }
}

private struct TriangleDistanceField {
    let triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]
    init(_ mesh: MeshData) throws {
        let topology = try EditableMesh(renderMesh: mesh, welding: .exactPositions)
        try topology.validate(requireClosed: true)
        guard mesh.triangleCount <= 10000 else {
            throw modelingError(
                "boolean.budget", "Voxel boolean operands are limited to 10000 triangles.")
        }
        triangles = stride(from: 0, to: mesh.indices.count, by: 3).map {
            (
                mesh.vertices[Int(mesh.indices[$0])].position,
                mesh.vertices[Int(mesh.indices[$0 + 1])].position,
                mesh.vertices[Int(mesh.indices[$0 + 2])].position
            )
        }
    }
    func value(at p: SIMD3<Float>) -> Float {
        var distance = Float.infinity
        var solidAngle: Float = 0
        for (a, b, c) in triangles {
            distance = min(distance, pointTriangleDistance(p, a, b, c))
            let x = a - p
            let y = b - p
            let z = c - p
            let lx = simd_length(x)
            let ly = simd_length(y)
            let lz = simd_length(z)
            let denominator =
                lx * ly * lz + simd_dot(x, y) * lz + simd_dot(y, z) * lx + simd_dot(z, x) * ly
            solidAngle += 2 * atan2(simd_dot(x, simd_cross(y, z)), denominator)
        }
        return abs(solidAngle) > 2 * .pi ? -distance : distance
    }
}

func pointTriangleDistance(
    _ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
) -> Float {
    let ab = b - a
    let ac = c - a
    let n = unitVector(simd_cross(ab, ac))
    let projected = p - n * simd_dot(p - a, n)
    if simd_dot(simd_cross(ab, projected - a), n) >= 0
        && simd_dot(simd_cross(c - b, projected - b), n) >= 0
        && simd_dot(simd_cross(a - c, projected - c), n) >= 0
    {
        return abs(simd_dot(p - a, n))
    }
    func edge(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> Float {
        let d = y - x
        let t = min(max(simd_dot(p - x, d) / max(simd_length_squared(d), 1e-20), 0), 1)
        return simd_distance(p, x + d * t)
    }
    return min(edge(a, b), edge(b, c), edge(c, a))
}
