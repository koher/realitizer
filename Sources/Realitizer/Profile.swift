import Foundation
import simd

/// A planar outline in counterclockwise order. Holes are clockwise.
public struct Profile2D: Equatable, Sendable, Codable {
    public var outer: [SIMD2<Float>]
    public var holes: [[SIMD2<Float>]]

    public init(outer: [SIMD2<Float>], holes: [[SIMD2<Float>]] = []) {
        self.outer = outer
        self.holes = holes
    }

    public static func circle(radius: Float, segments: Int = 24) throws -> Self {
        guard radius.isFinite, radius > 0, (3...65536).contains(segments) else {
            throw modelingError("profile.circle", "Radius must be positive and segments must be between 3 and 65536.")
        }
        return Self(
            outer: (0..<segments).map {
                let angle = Float($0) / Float(segments) * 2 * .pi
                return SIMD2(cos(angle), sin(angle)) * radius
            })
    }

    public static func rectangle(width: Float, height: Float) throws -> Self {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw modelingError("profile.rectangle", "Rectangle dimensions must be finite and positive.")
        }
        return Self(outer: [
            [-width / 2, -height / 2], [width / 2, -height / 2], [width / 2, height / 2], [-width / 2, height / 2],
        ])
    }

    /// Ear clipping with visible bridges for holes. Output vertices include bridge duplicates.
    public func triangulated() throws -> PlanarTriangulation {
        let rings = [outer] + holes
        guard rings.allSatisfy({ $0.count >= 3 && $0.allSatisfy(\.isFinite) }) else {
            throw modelingError("profile.invalidRing", "Every ring requires at least three finite points.")
        }
        let extent = rings.flatMap { $0 }.map { simd_length($0) }.max() ?? 1
        let epsilon = GeometryTolerance().length(for: extent)
        for ring in rings {
            guard abs(signedArea(ring)) > epsilon * epsilon else {
                throw modelingError("profile.zeroArea", "A ring has no usable area.")
            }
            for i in ring.indices {
                let next = (i + 1) % ring.count
                guard simd_distance(ring[i], ring[next]) > epsilon else {
                    throw modelingError("profile.duplicatePoint", "Consecutive ring points must be distinct.")
                }
                for j in ring.indices where j > i && j != next && (j + 1) % ring.count != i {
                    if segmentsIntersect(ring[i], ring[next], ring[j], ring[(j + 1) % ring.count], epsilon: epsilon) {
                        throw modelingError("profile.selfIntersection", "Profile boundaries must not intersect.")
                    }
                }
            }
        }
        for a in rings.indices {
            for b in rings.indices where b > a {
                for i in rings[a].indices {
                    for j in rings[b].indices {
                        if segmentsIntersect(
                            rings[a][i], rings[a][(i + 1) % rings[a].count], rings[b][j],
                            rings[b][(j + 1) % rings[b].count], epsilon: epsilon)
                        {
                            throw modelingError("profile.crossingRings", "Rings must not intersect or touch.")
                        }
                    }
                }
            }
        }
        for (index, hole) in holes.enumerated() {
            guard containsPoint(hole[0], in: outer),
                !holes.enumerated().contains(where: { $0.offset != index && containsPoint(hole[0], in: $0.element) })
            else {
                throw modelingError("profile.invalidHole", "Holes must be inside the outline and may not be nested.")
            }
        }
        var polygon = signedArea(outer) > 0 ? outer : outer.reversed()
        let orderedHoles = holes.map { signedArea($0) < 0 ? $0 : $0.reversed() }
            .sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for hole in orderedHoles {
            let h = hole.indices.max { hole[$0].x < hole[$1].x }!
            let point = hole[h]
            let candidate = polygon.indices.sorted {
                simd_distance_squared(polygon[$0], point) < simd_distance_squared(polygon[$1], point)
            }.first { index in
                let end = polygon[index]
                let middle = (point + end) * 0.5
                guard containsPoint(middle, in: outer), !holes.contains(where: { containsPoint(middle, in: $0) }) else {
                    return false
                }
                for ring in [polygon] + orderedHoles {
                    for i in ring.indices {
                        let a = ring[i]
                        let b = ring[(i + 1) % ring.count]
                        if a == point || b == point || a == end || b == end { continue }
                        if segmentsIntersect(point, end, a, b, epsilon: epsilon) { return false }
                    }
                }
                return true
            }
            guard let index = candidate else {
                throw modelingError("profile.holeBridge", "No valid bridge could be found for a hole.")
            }
            let walk = (0..<hole.count).map { hole[(h + $0) % hole.count] }
            polygon.insert(contentsOf: walk + [point, polygon[index]], at: index + 1)
        }
        var remaining = Array(polygon.indices)
        var triangles: [UInt32] = []
        let areaTolerance = epsilon * epsilon
        while remaining.count > 3 {
            var clipped = false
            for i in remaining.indices {
                let a = remaining[(i + remaining.count - 1) % remaining.count]
                let b = remaining[i]
                let c = remaining[(i + 1) % remaining.count]
                let pa = polygon[a]
                let pb = polygon[b]
                let pc = polygon[c]
                guard cross2(pb - pa, pc - pb) > areaTolerance else { continue }
                let occupied = remaining.contains { p in
                    let v = polygon[p]
                    if v == pa || v == pb || v == pc { return false }
                    return cross2(pb - pa, v - pa) >= -areaTolerance
                        && cross2(pc - pb, v - pb) >= -areaTolerance
                        && cross2(pa - pc, v - pc) >= -areaTolerance
                }
                if !occupied {
                    triangles.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
                    remaining.remove(at: i)
                    clipped = true
                    break
                }
            }
            if !clipped {
                // Collinear corners can be removed without changing the surface.
                if let i = remaining.indices.first(where: { i in
                    let a = polygon[remaining[(i + remaining.count - 1) % remaining.count]]
                    let b = polygon[remaining[i]]
                    let c = polygon[remaining[(i + 1) % remaining.count]]
                    return abs(cross2(b - a, c - b)) <= areaTolerance && a != c
                }) {
                    remaining.remove(at: i)
                } else {
                    throw modelingError(
                        "profile.triangulation", "The profile could not be triangulated at this tolerance.")
                }
            }
        }
        if remaining.count == 3 { triangles.append(contentsOf: remaining.map(UInt32.init)) }
        return PlanarTriangulation(vertices: polygon, indices: triangles)
    }
}

public struct PlanarTriangulation: Equatable, Sendable {
    public let vertices: [SIMD2<Float>]
    public let indices: [UInt32]
}

func signedArea(_ points: [SIMD2<Float>]) -> Float {
    points.indices.reduce(0) { $0 + cross2(points[$1], points[($1 + 1) % points.count]) } * 0.5
}

func containsPoint(_ point: SIMD2<Float>, in polygon: [SIMD2<Float>]) -> Bool {
    var inside = false
    for i in polygon.indices {
        let a = polygon[i]
        let b = polygon[(i + 1) % polygon.count]
        if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
    }
    return inside
}

func segmentsIntersect(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>, epsilon: Float)
    -> Bool
{
    let ab = b - a
    let cd = d - c
    let tolerance = epsilon * max(simd_length(ab), simd_length(cd))
    let x = cross2(ab, c - a)
    let y = cross2(ab, d - a)
    let z = cross2(cd, a - c)
    let w = cross2(cd, b - c)
    if ((x > tolerance && y < -tolerance) || (x < -tolerance && y > tolerance))
        && ((z > tolerance && w < -tolerance) || (z < -tolerance && w > tolerance))
    {
        return true
    }
    func onSegment(_ p: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Bool {
        abs(cross2(v - u, p - u)) <= tolerance && simd_dot(p - u, p - v) <= epsilon * epsilon
    }
    return onSegment(c, a, b) || onSegment(d, a, b) || onSegment(a, c, d) || onSegment(b, c, d)
}
