import Foundation
import simd

public enum UVProjection: Equatable, Sendable, Codable {
    case planar(horizontal: ModelingAxis, vertical: ModelingAxis, scale: SIMD2<Float>)
    case cylindrical(axis: ModelingAxis, scale: SIMD2<Float>)
    case spherical
}

extension MeshData {
    /// A local, reproducible shape-building step. Bind skin and author morphs after this operation.
    /// Reconstructing polygon topology does not preserve custom normals or render-vertex correspondence.
    public func modifyingTopology(
        welding: TopologyWelding, smoothingAngle: Float = 0,
        _ operation: (inout EditableMesh) throws -> Void
    ) throws -> Self {
        var topology = try EditableMesh(renderMesh: self, welding: welding)
        try operation(&topology)
        return try topology.renderMesh(smoothingAngle: smoothingAngle)
    }

    public var triangleCount: Int { indices.count / 3 }
    public var surfaceArea: Float {
        guard indices.allSatisfy({ Int($0) < vertices.count }) else { return .nan }
        return stride(from: 0, to: indices.count - indices.count % 3, by: 3).reduce(0) { sum, i in
            let a = vertices[Int(indices[i])].position
            let b = vertices[Int(indices[i + 1])].position
            let c = vertices[Int(indices[i + 2])].position
            return sum + simd_length(simd_cross(b - a, c - a)) * 0.5
        }
    }
    /// Signed volume is meaningful for a closed, consistently oriented mesh.
    public var signedVolume: Float {
        guard indices.allSatisfy({ Int($0) < vertices.count }) else { return .nan }
        return stride(from: 0, to: indices.count - indices.count % 3, by: 3).reduce(0) { sum, i in
            let a = vertices[Int(indices[i])].position
            let b = vertices[Int(indices[i + 1])].position
            let c = vertices[Int(indices[i + 2])].position
            return sum + simd_dot(a, simd_cross(b, c)) / 6
        }
    }

    /// Splits render corners at hard edges while retaining UV and material boundaries.
    public func recalculatingNormals(smoothingAngle: Float = .pi) throws -> Self {
        try MeshProcessor.recalculateNormals(of: self, smoothingAngle: smoothingAngle).mesh
    }

    /// Derives tangent frames from UVs without changing topology or authored normals.
    /// Missing or numerically parallel UV directions use a deterministic perpendicular basis.
    public func generatingTangents() throws -> Self {
        guard indices.count.isMultiple(of: 3), indices.allSatisfy({ Int($0) < vertices.count }),
            vertices.allSatisfy({ $0.textureCoordinate.isFinite })
        else {
            throw modelingError(
                "tangents.input", "Tangents require valid triangles and finite UV coordinates.")
        }
        var tangents = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
        var bitangents = tangents
        for i in stride(from: 0, to: indices.count, by: 3) {
            let ids = (0..<3).map { Int(indices[i + $0]) }
            let a = vertices[ids[0]]
            let b = vertices[ids[1]]
            let c = vertices[ids[2]]
            let d1 = b.textureCoordinate - a.textureCoordinate
            let d2 = c.textureCoordinate - a.textureCoordinate
            let determinant = cross2(d1, d2)
            if abs(determinant) < 1e-12 { continue }
            let e1 = b.position - a.position
            let e2 = c.position - a.position
            let t = (e1 * d2.y - e2 * d1.y) / determinant
            let bt = (e2 * d1.x - e1 * d2.x) / determinant
            for id in ids {
                tangents[id] += t
                bitangents[id] += bt
            }
        }
        var result = self
        for i in vertices.indices {
            let n = vertices[i].normal
            let t = orthonormalTangent(tangents[i], normal: n)
            result.vertices[i].tangent = SIMD4(t, simd_dot(simd_cross(n, t), bitangents[i]) < 0 ? -1 : 1)
        }
        return result
    }

    public func projectingUV(_ projection: UVProjection) throws -> Self {
        try MeshProcessor.projectUV(of: self, using: projection).mesh
    }

    public func deformed(smoothingAngle: Float = .pi, by map: (SIMD3<Float>) -> SIMD3<Float>) throws
        -> Self
    {
        var result = self
        for i in result.vertices.indices { result.vertices[i].position = map(vertices[i].position) }
        return try result.recalculatingNormals(smoothingAngle: smoothingAngle).generatingTangents()
            .validated()
    }

    public func twisted(around axis: ModelingAxis, radiansPerMeter: Float) throws -> Self {
        guard radiansPerMeter.isFinite else {
            throw modelingError("deform.twist", "Twist must be finite.")
        }
        return try deformed { p in
            simd_quatf(angle: p[axis.rawValue] * radiansPerMeter, axis: axis.vector).act(p)
        }
    }

    public func tapered(along axis: ModelingAxis, from start: Float, to end: Float) throws -> Self {
        guard start.isFinite, end.isFinite, start > 0, end > 0, let bounds else {
            throw modelingError(
                "deform.taper", "Taper scales must be positive and the mesh must have bounds.")
        }
        let length = bounds.size[axis.rawValue]
        guard length > 0 else {
            throw modelingError("deform.taperAxis", "The taper axis must have positive extent.")
        }
        return try deformed { p in
            let t = (p[axis.rawValue] - bounds.minimum[axis.rawValue]) / length
            let scale = start + (end - start) * t
            var q = p * scale
            q[axis.rawValue] = p[axis.rawValue]
            return q
        }
    }

    /// Bends the y axis in the xy plane, keeping z unchanged. Curvature is radians per meter.
    public func bent(curvature: Float) throws -> Self {
        guard curvature.isFinite else {
            throw modelingError("deform.bend", "Bend curvature must be finite.")
        }
        if abs(curvature) < 1e-8 { return self }
        return try deformed { p in
            let angle = p.y * curvature
            let radius = 1 / curvature
            return SIMD3(radius - (radius - p.x) * cos(angle), (radius - p.x) * sin(angle), p.z)
        }
    }

    public func mirrored(across axis: ModelingAxis) -> Self {
        var scale = SIMD3<Float>.one
        scale[axis.rawValue] = -1
        return transformed(by: ModelTransform(scale: scale))
    }

    public func repeated(at transforms: [ModelTransform]) throws -> Self {
        guard !transforms.isEmpty, transforms.count <= 65536, transforms.allSatisfy(\.isFinite) else {
            throw modelingError(
                "array.transforms", "An array requires between 1 and 65536 finite transforms.")
        }
        var builder = MeshBuilder()
        for transform in transforms { builder.append(self, transform: transform) }
        return try builder.build()
    }

    public func linearArray(count: Int, offset: SIMD3<Float>) throws -> Self {
        guard (1...65536).contains(count) else {
            throw modelingError("array.count", "Array count must be between 1 and 65536.")
        }
        return try repeated(at: (0..<count).map { ModelTransform(translation: offset * Float($0)) })
    }

    public func radialArray(count: Int, axis: ModelingAxis = .y, angle: Float = 2 * .pi) throws
        -> Self
    {
        guard (1...65536).contains(count), angle.isFinite else {
            throw modelingError(
                "array.radial", "Radial array parameters must be finite with a positive count.")
        }
        return try repeated(
            at: (0..<count).map {
                ModelTransform(
                    rotation: simd_quatf(angle: angle * Float($0) / Float(count), axis: axis.vector))
            })
    }
}
