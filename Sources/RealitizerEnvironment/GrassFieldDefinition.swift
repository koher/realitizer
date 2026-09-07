import Foundation
import Realitizer
import simd

/// A rooted, upright blade in field-local coordinates. Dimensions are meters.
public struct GrassBlade: Equatable, Sendable {
    public let root: SIMD3<Float>
    public let height: Float
    public let width: Float
    public let heading: Float
    public let lean: SIMD2<Float>
    public let variation: Float

    public init(root: SIMD3<Float>, height: Float, width: Float, heading: Float,
                lean: SIMD2<Float> = .zero, variation: Float = 0.5) throws {
        guard root.isFinite, root.maxAbsComponent <= 100_000,
            height.isFinite, (0.01...10).contains(height),
            width.isFinite, (0.001...height).contains(width), heading.isFinite,
            lean.isFinite, simd_length(lean) <= height,
            variation.isFinite, (0...1).contains(variation)
        else { throw modelingError("grass.blade", "Grass blades require finite, bounded dimensions and variation in 0...1.") }
        self.root = root
        self.height = height
        self.width = width
        self.heading = heading.remainder(dividingBy: 2 * .pi)
        self.lean = lean
        self.variation = variation
    }
}

/// Wind direction is in the field's local XZ plane. Strength is maximum nominal tip travel in meters.
public struct GrassWind: Equatable, Sendable {
    public let direction: SIMD2<Float>
    public let strength: Float
    public let speed: Float
    public var boundsMargin: Float { strength * 2 }

    public init(direction: SIMD2<Float> = [1, 0.35], strength: Float = 0.24, speed: Float = 1) throws {
        guard direction.isFinite, simd_length(direction).isFinite, simd_length(direction) > 0.0001,
            strength.isFinite, (0...2).contains(strength), speed.isFinite, (0...10).contains(speed)
        else { throw modelingError("grass.wind", "Grass wind requires a nonzero direction, strength in 0...2 and speed in 0...10.") }
        self.direction = simd_normalize(direction)
        self.strength = strength
        self.speed = speed
    }

    /// CPU reference for the GPU modifier, useful for deterministic tools and bound tests.
    /// Roots remain fixed; the quadratic tip weight bends upper portions more strongly.
    public func offset(at position: SIMD3<Float>, heightFraction: Float, variation: Float, time: Float) throws -> SIMD3<Float> {
        guard position.isFinite, position.maxAbsComponent <= 100_000,
            heightFraction.isFinite, (0...1).contains(heightFraction),
            variation.isFinite, (0...1).contains(variation), time.isFinite, abs(time) <= 1_000_000
        else { throw modelingError("grass.sample", "Grass samples require finite positions, bounded time and fractions in 0...1.") }
        let t = time * speed
        let p = SIMD2(position.x, position.z)
        let gust = sin(simd_dot(p, SIMD2<Float>(0.31, 0.19)) - t * 1.13)
        let ripple = sin(simd_dot(p, SIMD2<Float>(-0.63, 0.47)) - t * 1.91 + variation * 6.2831853)
        let flutter = sin(t * 3.17 + variation * 17 + p.x * 0.11)
        let travel = (0.45 + 0.38 * gust + 0.17 * ripple) * strength
        let cross = SIMD2(-direction.y, direction.x) * (flutter * 0.12 * strength)
        let horizontal = (direction * travel + cross) * heightFraction * heightFraction
        return [horizontal.x, -abs(travel) * 0.18 * heightFraction * heightFraction, horizontal.y]
    }
}

/// Distance is measured to each chunk's bounds, in field-local meters.
public struct GrassDetail: Equatable, Sendable {
    public let nearDistance: Float
    public let farDistance: Float
    public let farDensityStride: Int
    public let hysteresis: Float

    public init(nearDistance: Float = 24, farDistance: Float = 85,
                farDensityStride: Int = 3, hysteresis: Float = 2) throws {
        guard nearDistance.isFinite, farDistance.isFinite, hysteresis.isFinite,
            nearDistance >= 1, farDistance <= 100_000,
            hysteresis >= 0, hysteresis < nearDistance / 2,
            farDistance > nearDistance + hysteresis + 1, (1...16).contains(farDensityStride)
        else { throw modelingError("grass.detail", "Grass detail requires ordered positive distances, bounded hysteresis and a stride in 1...16.") }
        self.nearDistance = nearDistance
        self.farDistance = farDistance
        self.farDensityStride = farDensityStride
        self.hysteresis = hysteresis
    }
}

/// Opaque geometry, partitioned into bounded chunks instead of one entity per blade.
public struct GrassFieldDefinition: Equatable, Sendable {
    public let blades: [GrassBlade]
    public let chunkSize: Float

    public init(blades: [GrassBlade], chunkSize: Float = 5) throws {
        guard blades.count <= 200_000, chunkSize.isFinite, (1...100).contains(chunkSize) else {
            throw modelingError("grass.budget", "Grass fields support at most 200,000 blades and chunk sizes in 1...100 meters.")
        }
        let occupied = Set(blades.map {
            SIMD2<Int32>(Int32(floor($0.root.x / chunkSize)), Int32(floor($0.root.z / chunkSize)))
        })
        guard occupied.count <= 1_024 else {
            throw modelingError("grass.chunks", "Grass fields support at most 1,024 occupied chunks; stream separate fields for larger worlds.")
        }
        self.blades = blades
        self.chunkSize = chunkSize
    }

    /// Jittered stratified scatter avoids a visible grid. The density mask is sampled in XZ.
    /// Invalid samples throw; zero density and fully excluded fields are valid empty results.
    public static func scatter(
        minimum: SIMD2<Float>, maximum: SIMD2<Float>, density: Float,
        height: ClosedRange<Float> = 0.35...0.75, width: ClosedRange<Float> = 0.035...0.075,
        seed: UInt64, chunkSize: Float = 5,
        surfaceHeight: (SIMD2<Float>) throws -> Float,
        mask: (SIMD2<Float>) throws -> Float = { _ in 1 }
    ) throws -> Self {
        guard minimum.isFinite, maximum.isFinite, minimum.x < maximum.x, minimum.y < maximum.y,
            density.isFinite, (0...1_000).contains(density),
            height.lowerBound.isFinite, height.upperBound.isFinite,
            height.lowerBound >= 0.01, height.upperBound <= 10,
            width.lowerBound.isFinite, width.upperBound.isFinite,
            width.lowerBound >= 0.001, width.upperBound <= height.lowerBound
        else { throw modelingError("grass.scatter", "Grass scatter requires finite ordered bounds, valid dimensions and density in 0...1,000.") }
        if density == 0 { return try Self(blades: [], chunkSize: chunkSize) }
        let size = maximum - minimum
        let resolution = (size * sqrt(density)).rounded(.up)
        guard resolution.isFinite, resolution.x * resolution.y <= 200_000 else {
            throw modelingError("grass.budget", "Grass scatter must sample no more than 200,000 cells; reduce density or split the field.")
        }
        let nx = max(1, Int(resolution.x)), nz = max(1, Int(resolution.y))
        // Correct for the rounded-up grid so density remains blades per square meter.
        let coverage = min(1, density * size.x * size.y / Float(nx * nz))
        var random = ModelingRandom(seed: seed)
        var blades: [GrassBlade] = []
        for z in 0..<nz {
            for x in 0..<nx {
                let p = minimum + SIMD2((Float(x) + random.unit()) / Float(nx),
                                        (Float(z) + random.unit()) / Float(nz)) * size
                let acceptance = random.unit()
                let h = height.lowerBound + random.unit() * (height.upperBound - height.lowerBound)
                let w = width.lowerBound + random.unit() * (width.upperBound - width.lowerBound)
                let heading = random.unit() * 2 * Float.pi
                let variation = random.unit()
                let lean = SIMD2(cos(heading + 1.2), sin(heading + 1.2)) * (h * (0.08 + random.unit() * 0.18))
                let probability = try mask(p)
                guard probability.isFinite, (0...1).contains(probability) else {
                    throw modelingError("grass.mask", "Grass density masks must return finite values in 0...1.")
                }
                guard acceptance < probability * coverage else { continue }
                blades.append(try GrassBlade(root: [p.x, surfaceHeight(p), p.y], height: h, width: w,
                                              heading: heading, lean: lean, variation: variation))
            }
        }
        return try Self(blades: blades, chunkSize: chunkSize)
    }

    public func chunks() -> [GrassChunk] {
        let groups = Dictionary(grouping: blades) { blade in
            SIMD2<Int32>(Int32(floor(blade.root.x / chunkSize)), Int32(floor(blade.root.z / chunkSize)))
        }
        return groups.keys.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.map {
            GrassChunk(coordinate: $0, blades: groups[$0]!)
        }
    }
}

public struct GrassChunk: Equatable, Sendable {
    public let coordinate: SIMD2<Int32>
    public let blades: [GrassBlade]

    /// Near blades use five vertices/three triangles. Far blades use three/one and
    /// a stable subset of the same roots; LOD never regenerates random positions.
    public func mesh(far: Bool = false, densityStride: Int = 3) throws -> MeshData {
        guard (1...16).contains(densityStride) else {
            throw modelingError("grass.stride", "Grass density stride must be in 1...16.")
        }
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        for (index, blade) in blades.enumerated() where !far || index % densityStride == 0 {
            let side = SIMD3<Float>(cos(blade.heading), 0, sin(blade.heading))
            let lean = SIMD3<Float>(blade.lean.x, 0, blade.lean.y)
            let normal = simd_normalize(simd_cross(side, SIMD3<Float>(0, 1, 0)) + [0, 0.65, 0])
            let first = UInt32(vertices.count)
            func vertex(_ y: Float, _ width: Float) -> MeshVertex {
                MeshVertex(position: blade.root + [0, blade.height * y, 0] + side * blade.width * width + lean * y * y,
                           normal: normal, textureCoordinate: [y, blade.variation])
            }
            vertices += [vertex(0, -0.5), vertex(0, 0.5)]
            if far {
                vertices.append(vertex(1, 0))
                indices += [first, first + 1, first + 2]
            } else {
                vertices += [vertex(0.52, -0.32), vertex(0.52, 0.32), vertex(1, 0)]
                indices += [first, first + 1, first + 2, first + 1, first + 3, first + 2,
                            first + 2, first + 3, first + 4]
            }
        }
        return try MeshData(vertices: vertices, indices: indices).validated()
    }
}

private extension SIMD3<Float> {
    var maxAbsComponent: Float { Swift.max(abs(x), Swift.max(abs(y), abs(z))) }
}
