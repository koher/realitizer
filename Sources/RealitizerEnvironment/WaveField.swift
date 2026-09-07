import Foundation
import Realitizer
import simd

/// One directional Gerstner wave. Distances are meters, time is seconds, angles are radians.
public struct DirectionalWave: Equatable, Sendable {
    public let direction: SIMD2<Float>
    public let amplitude: Float
    public let wavelength: Float
    public let speed: Float
    public let steepness: Float
    public let phase: Float

    public init(
        direction: SIMD2<Float>, amplitude: Float, wavelength: Float,
        speed: Float, steepness: Float = 0.3, phase: Float = 0
    ) throws {
        guard direction.isFinite, simd_length(direction).isFinite, simd_length(direction) > 0.00001,
            amplitude.isFinite, (0...100_000).contains(amplitude),
            wavelength.isFinite, (0.01...1_000_000).contains(wavelength),
            speed.isFinite, abs(speed) <= 100_000, phase.isFinite,
            steepness.isFinite, (0...1).contains(steepness)
        else { throw modelingError("wave.parameters", "Wave parameters must be finite with a nonzero direction and positive wavelength.") }
        self.direction = simd_normalize(direction)
        self.amplitude = amplitude
        self.wavelength = wavelength
        self.speed = speed
        self.steepness = steepness
        self.phase = phase
    }
}

/// A deterministic bounded sum of waves with analytic normals and tangents.
/// Feed the same rest positions on every update; never deform an already deformed mesh.
public struct WaveField: Equatable, Sendable {
    public let waves: [DirectionalWave]
    public var maximumVerticalDisplacement: Float { waves.reduce(0) { $0 + $1.amplitude } }

    public init(waves: [DirectionalWave]) throws {
        guard waves.count <= 16,
            waves.reduce(Float(0), { $0 + $1.steepness * $1.amplitude * 2 * .pi / $1.wavelength }) < 0.9
        else { throw modelingError("wave.folding", "Use at most 16 waves with combined horizontal steepness below 0.9 to prevent folding.") }
        self.waves = waves
    }

    public func vertex(at rest: SIMD3<Float>, time: Float) throws -> MeshVertex {
        guard rest.isFinite, time.isFinite else {
            throw modelingError("wave.sample", "Wave sample positions and time must be finite.")
        }
        let sample = evaluate(rest, time: time)
        guard sample.position.isFinite, sample.normal.isFinite, sample.tangent.isFinite else {
            throw modelingError("wave.overflow", "Wave evaluation overflowed its finite numeric range.")
        }
        return sample
    }

    /// Updates only position/normal/tangent, preserving the caller's UVs and topology.
    public func updateVertices(
        _ vertices: inout [MeshVertex], restPositions: [SIMD3<Float>], time: Float
    ) throws {
        guard vertices.count == restPositions.count, time.isFinite,
            restPositions.allSatisfy(\.isFinite)
        else { throw modelingError("wave.vertices", "Wave updates require matching rest positions and finite time.") }
        // Validate the range before mutating so invalid input never leaves a partial update.
        guard restPositions.allSatisfy({ rest in
            waves.allSatisfy { wave in
                (2 * Float.pi / wave.wavelength * (simd_dot(wave.direction, SIMD2(rest.x, rest.z)) - wave.speed * time)
                    + wave.phase).isFinite
            }
        }) else { throw modelingError("wave.overflow", "Wave evaluation overflowed its finite numeric range.") }
        for i in vertices.indices {
            let v = evaluate(restPositions[i], time: time)
            vertices[i].position = v.position
            vertices[i].normal = v.normal
            vertices[i].tangent = SIMD4(SIMD3(v.tangent.x, v.tangent.y, v.tangent.z), vertices[i].tangent.w)
        }
    }

    private func evaluate(_ rest: SIMD3<Float>, time: Float) -> MeshVertex {
        var p = rest
        var dx = SIMD3<Float>(1, 0, 0)
        var dz = SIMD3<Float>(0, 0, 1)
        for wave in waves {
            let d = wave.direction
            let k = 2 * Float.pi / wave.wavelength
            let angle = k * (simd_dot(d, SIMD2(rest.x, rest.z)) - wave.speed * time) + wave.phase
            let s = sin(angle), c = cos(angle)
            let horizontal = wave.steepness * wave.amplitude
            p += [horizontal * d.x * c, wave.amplitude * s, horizontal * d.y * c]
            dx += [-horizontal * k * d.x * d.x * s, wave.amplitude * k * d.x * c, -horizontal * k * d.x * d.y * s]
            dz += [-horizontal * k * d.x * d.y * s, wave.amplitude * k * d.y * c, -horizontal * k * d.y * d.y * s]
        }
        let normal = simd_normalize(simd_cross(dz, dx))
        return MeshVertex(position: p, normal: normal, tangent: SIMD4(simd_normalize(dx), -1))
    }
}
