import simd

extension MeshData {
    /// Smooth seeded displacement, shared by coincident positions to preserve seams.
    /// Run before binding skin or authoring morph deltas because normals regenerate render corners.
    public func noiseDisplaced(amplitude: Float, frequency: Float = 1, seed: UInt64) throws -> Self {
        guard amplitude.isFinite, amplitude >= 0, frequency.isFinite, frequency > 0 else {
            throw modelingError(
                "noise.parameters", "Noise amplitude must be nonnegative and frequency positive and finite.")
        }
        var random = ModelingRandom(seed: seed)
        let phases = (0..<9).map { _ in random.unit() * 2 * Float.pi }
        return try deformed { p in
            let q = p * frequency
            let delta = SIMD3<Float>(
                sin(q.x + phases[0]) * cos(q.y + phases[1]) * sin(q.z + phases[2]),
                sin(q.y + phases[3]) * cos(q.z + phases[4]) * sin(q.x + phases[5]),
                sin(q.z + phases[6]) * cos(q.x + phases[7]) * sin(q.y + phases[8]))
            return p + delta * amplitude
        }
    }
}
