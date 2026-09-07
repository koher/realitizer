import Foundation
import simd

/// Cross-sections are expressed in the local xy plane. Their transforms place them in space.
public struct LoftSection: Equatable, Sendable, Codable {
    public var profile: [SIMD2<Float>]
    public var transform: ModelTransform
    public init(profile: [SIMD2<Float>], transform: ModelTransform) {
        self.profile = profile
        self.transform = transform
    }
}

public enum CurveSampling {
    public static func cubicBezier(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, segments: Int = 24
    ) throws -> [SIMD3<Float>] {
        guard [a, b, c, d].allSatisfy(\.isFinite), (1...65536).contains(segments) else {
            throw modelingError(
                "curve.invalid", "Control points must be finite and segments must be between 1 and 65536.")
        }
        return (0...segments).map { i in
            let t = Float(i) / Float(segments)
            let u = 1 - t
            return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
        }
    }

    public static func resample(_ path: [SIMD3<Float>], count: Int) throws -> [SIMD3<Float>] {
        guard path.count >= 2, path.allSatisfy(\.isFinite), (2...65536).contains(count) else {
            throw modelingError(
                "curve.resample", "A finite path and at least two output samples are required.")
        }
        var distances: [Float] = [0]
        for i in 1..<path.count {
            distances.append(distances.last! + simd_distance(path[i - 1], path[i]))
        }
        guard let length = distances.last, length > 0 else {
            throw modelingError("curve.zeroLength", "Path length must be positive.")
        }
        var segment = 1
        return (0..<count).map { i in
            let distance = length * Float(i) / Float(count - 1)
            while segment < path.count - 1 && distances[segment] < distance { segment += 1 }
            let span = distances[segment] - distances[segment - 1]
            let t = span > 0 ? (distance - distances[segment - 1]) / span : 0
            return simd_mix(path[segment - 1], path[segment], SIMD3(repeating: t))
        }
    }
}

extension MeshBuilder {
    /// Extrudes a concave outline, optionally with holes, along positive z.
    public static func extrude(_ profile: Profile2D, depth: Float) throws -> MeshData {
        guard depth.isFinite, depth > 0 else {
            throw modelingError("extrude.depth", "Extrusion depth must be finite and positive.")
        }
        let cap = try profile.triangulated()
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        for (z, normal) in [(Float(0), SIMD3<Float>(0, 0, -1)), (depth, SIMD3<Float>(0, 0, 1))] {
            let offset = UInt32(vertices.count)
            vertices += cap.vertices.map {
                MeshVertex(position: SIMD3($0, z), normal: normal, textureCoordinate: $0)
            }
            for i in stride(from: 0, to: cap.indices.count, by: 3) {
                let triangle = Array(cap.indices[i..<(i + 3)])
                indices += (z == 0 ? triangle.reversed() : triangle).map { $0 + offset }
            }
        }
        let rings =
            [signedArea(profile.outer) > 0 ? profile.outer : profile.outer.reversed()]
            + profile.holes.map { signedArea($0) < 0 ? $0 : $0.reversed() }
        for ring in rings {
            var u: Float = 0
            for i in ring.indices {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                let length = simd_distance(a, b)
                let normal = unitVector(SIMD3(b.y - a.y, a.x - b.x, 0))
                let offset = UInt32(vertices.count)
                let points = [SIMD3(a, 0), SIMD3(b, 0), SIMD3(b, depth), SIMD3(a, depth)]
                let uv: [SIMD2<Float>] = [[u, 0], [u + length, 0], [u + length, depth], [u, depth]]
                vertices += zip(points, uv).map {
                    MeshVertex(position: $0.0, normal: normal, textureCoordinate: $0.1)
                }
                indices += [0, 1, 2, 0, 2, 3].map { $0 + offset }
                u += length
            }
        }
        return try MeshData(vertices: vertices, indices: indices).generatingTangents().validated()
    }

    /// Revolves an ordered (radius, height) polyline around y. Axis endpoints close the surface.
    public static func revolve(profile: [SIMD2<Float>], segments: Int = 32) throws -> MeshData {
        guard profile.count >= 2, profile.allSatisfy({ $0.isFinite && $0.x >= 0 }),
            (3...65536).contains(segments)
        else {
            throw modelingError(
                "revolve.profile", "Revolution requires nonnegative radii and at least three segments.")
        }
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var distance: Float = 0
        for j in 0..<(profile.count - 1) {
            let a = profile[j]
            let b = profile[j + 1]
            let length = simd_distance(a, b)
            guard length > 1e-8 else {
                throw modelingError("revolve.duplicate", "Profile points must be distinct.")
            }
            if a.x == 0 && b.x == 0 { continue }
            let normal2 = SIMD2(b.y - a.y, a.x - b.x) / length
            let offset = UInt32(vertices.count)
            for i in 0...segments {
                let u = Float(i) / Float(segments)
                let angle = Float(i % segments) / Float(segments) * 2 * .pi
                let n = SIMD3(normal2.x * cos(angle), normal2.y, normal2.x * sin(angle))
                for (p, v) in [(a, distance), (b, distance + length)] {
                    vertices.append(
                        MeshVertex(
                            position: [p.x * cos(angle), p.y, p.x * sin(angle)], normal: n,
                            textureCoordinate: [u, v]))
                }
            }
            for i in 0..<segments {
                let k = offset + UInt32(i * 2)
                if a.x > 0 { indices += [k, k + 1, k + 2] }
                if b.x > 0 { indices += [k + 2, k + 1, k + 3] }
            }
            distance += length
        }
        return try MeshData(vertices: vertices, indices: indices).generatingTangents().validated()
    }

    /// Parallel-transports a profile frame along an open path; rejects zero-length and reversing spans.
    public static func sweep(
        _ profile: Profile2D, along path: [SIMD3<Float>], scales: [Float] = [], twist: Float = 0,
        capped: Bool = true
    ) throws -> MeshData {
        guard profile.holes.isEmpty, path.count >= 2, path.allSatisfy(\.isFinite), twist.isFinite,
            scales.isEmpty || (scales.count == path.count && scales.allSatisfy({ $0.isFinite && $0 > 0 }))
        else {
            throw modelingError(
                "sweep.input",
                "Sweep requires an open finite path, a hole-free profile, and positive scales for every path point."
            )
        }
        _ = try profile.triangulated()
        var tangent = unitVector(path[1] - path[0])
        var x = orthogonal(to: tangent)
        var sections: [LoftSection] = []
        for i in path.indices {
            if i > 0 && simd_distance(path[i], path[i - 1]) < 1e-8 {
                throw modelingError("sweep.zeroSpan", "Path spans must have positive length.")
            }
            let next =
                i == path.count - 1 ? unitVector(path[i] - path[i - 1]) : unitVector(path[i + 1] - path[i])
            let t =
                i == 0 || i == path.count - 1 ? next : unitVector(unitVector(path[i] - path[i - 1]) + next)
            if simd_dot(tangent, t) < -0.9999 {
                throw modelingError("sweep.reversal", "A sweep path cannot reverse direction at a point.")
            }
            x = simd_quatf(from: tangent, to: t).act(x)
            let angle = twist * Float(i) / Float(path.count - 1)
            let rotatedX = simd_quatf(angle: angle, axis: t).act(x)
            let y = unitVector(simd_cross(t, rotatedX))
            let rotation = simd_quatf(simd_float3x3(columns: (rotatedX, y, t)))
            sections.append(
                LoftSection(
                    profile: profile.outer,
                    transform: ModelTransform(
                        scale: SIMD3(repeating: scales.isEmpty ? 1 : scales[i]), rotation: rotation,
                        translation: path[i])))
            tangent = t
        }
        return try loft(sections, capped: capped)
    }

    public static func loft(_ sections: [LoftSection], capped: Bool = true) throws -> MeshData {
        guard sections.count >= 2, let first = sections.first, first.profile.count >= 3,
            sections.allSatisfy({
                $0.profile.count == first.profile.count && $0.profile.allSatisfy(\.isFinite)
                    && $0.transform.isFinite
            })
        else {
            throw modelingError(
                "loft.sections",
                "At least two sections with matching vertex counts and finite transforms are required."
            )
        }
        let count = first.profile.count
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        var v: Float = 0
        for (j, section) in sections.enumerated() {
            if j > 0 {
                v += simd_distance(section.transform.translation, sections[j - 1].transform.translation)
            }
            for i in 0...count {
                let p = section.profile[i % count]
                vertices.append(
                    MeshVertex(
                        position: section.transform.applying(to: SIMD3(p, 0)), normal: [0, 1, 0],
                        textureCoordinate: [Float(i) / Float(count), v]))
            }
        }
        for j in 0..<(sections.count - 1) {
            for i in 0..<count {
                let a = UInt32(j * (count + 1) + i)
                let b = a + UInt32(count + 1)
                indices += [a, a + 1, b + 1, a, b + 1, b]
            }
        }
        if signedArea(first.profile) < 0 {
            for i in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(i + 1, i + 2) }
        }
        var surface = try MeshData(vertices: vertices, indices: indices).recalculatingNormals(
            smoothingAngle: .pi)
        if capped {
            for (section, flip) in [(sections[0], true), (sections[sections.count - 1], false)] {
                let cap = try Profile2D(outer: section.profile).triangulated()
                let normal: SIMD3<Float> = flip ? [0, 0, -1] : [0, 0, 1]
                let capVertices = cap.vertices.map {
                    MeshVertex(position: SIMD3($0, 0), normal: normal, textureCoordinate: $0)
                }
                var capIndices = cap.indices
                if flip {
                    for i in stride(from: 0, to: capIndices.count, by: 3) { capIndices.swapAt(i + 1, i + 2) }
                }
                var builder = MeshBuilder()
                builder.append(surface)
                builder.append(
                    MeshData(vertices: capVertices, indices: capIndices), transform: section.transform)
                surface = try builder.build()
            }
        }
        return try surface.generatingTangents().validated()
    }

    /// A rectangular parametric surface. The evaluator controls the silhouette and UVs remain in [0, 1].
    public static func surface(
        uSegments: Int, vSegments: Int, position: (SIMD2<Float>) -> SIMD3<Float>
    ) throws
        -> MeshData
    {
        guard (1...2048).contains(uSegments), (1...2048).contains(vSegments) else {
            throw modelingError("surface.resolution", "Surface subdivisions must be between 1 and 2048.")
        }
        var vertices: [MeshVertex] = []
        for v in 0...vSegments {
            for u in 0...uSegments {
                let uv = SIMD2(Float(u) / Float(uSegments), Float(v) / Float(vSegments))
                vertices.append(
                    MeshVertex(position: position(uv), normal: [0, 1, 0], textureCoordinate: uv))
            }
        }
        var indices: [UInt32] = []
        for v in 0..<vSegments {
            for u in 0..<uSegments {
                let a = UInt32(v * (uSegments + 1) + u)
                let b = a + UInt32(uSegments + 1)
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return try MeshData(vertices: vertices, indices: indices).recalculatingNormals()
            .generatingTangents()
            .validated()
    }
}
