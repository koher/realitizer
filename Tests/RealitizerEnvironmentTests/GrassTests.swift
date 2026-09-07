import Realitizer
import RealitizerEnvironment
import Testing
import simd

@Test func grassScatterIsStableMaskedAndBounded() throws {
    func field(seed: UInt64 = 18, mask: (SIMD2<Float>) -> Float = { $0.x < 0 ? 0 : 1 }) throws -> GrassFieldDefinition {
        try .scatter(minimum: [-5, -4], maximum: [5, 4], density: 20, seed: seed,
                     surfaceHeight: { $0.x * 0.1 + $0.y * 0.05 }, mask: mask)
    }
    let a = try field(), b = try field()
    #expect(a == b)
    #expect(a != (try field(seed: 19)))
    #expect(a.blades.count > 700 && a.blades.count < 900)
    #expect(try field(mask: { _ in 0 }).blades.isEmpty)
    #expect(a.chunks().flatMap(\.blades).count == a.blades.count)
    for blade in a.blades {
        #expect(blade.root.x >= 0 && blade.root.x < 5 && abs(blade.root.z) <= 4)
        #expect(abs(blade.root.y - (blade.root.x * 0.1 + blade.root.z * 0.05)) < 0.00001)
        #expect((0.35...0.75).contains(blade.height))
    }
}

@Test func grassGeometryUsesFiveAndThreeVertexLODsWithIdenticalRoots() throws {
    let field = try GrassFieldDefinition.scatter(minimum: [0, 0], maximum: [3, 3], density: 12,
                                                seed: 10, surfaceHeight: { _ in 0 })
    let chunk = try #require(field.chunks().first)
    let near = try chunk.mesh(), far = try chunk.mesh(far: true, densityStride: 3)
    #expect(near.vertices.count == chunk.blades.count * 5)
    #expect(near.triangleCount == chunk.blades.count * 3)
    #expect(far.vertices.count == ((chunk.blades.count + 2) / 3) * 3)
    #expect(far.triangleCount == far.vertices.count / 3)
    for i in stride(from: 0, to: chunk.blades.count, by: 3) {
        #expect(far.vertices[i] == near.vertices[i * 5])
        #expect(far.vertices[i + 1] == near.vertices[i * 5 + 1])
        #expect(far.vertices[i + 2] == near.vertices[i * 5 + 4])
    }
}

@Test func grassWindPinsRootsAndRemainsContinuousInsideBounds() throws {
    let wind = try GrassWind()
    for time in stride(from: Float(0), through: 40, by: 0.37) {
        #expect(try wind.offset(at: [2, 5, 1], heightFraction: 0, variation: 0.2, time: time) == .zero)
        let a = try wind.offset(at: [2, 5, 1], heightFraction: 1, variation: 0.2, time: time)
        let b = try wind.offset(at: [2, 5, 1], heightFraction: 1, variation: 0.2, time: time + 0.0001)
        #expect(simd_length(a) < wind.boundsMargin)
        #expect(simd_distance(a, b) < 0.001)
    }
    let zero = try GrassWind(strength: 0)
    #expect(try zero.offset(at: [1, 2, 3], heightFraction: 1, variation: 1, time: 8) == .zero)
    let frozen = try GrassWind(speed: 0)
    #expect(try frozen.offset(at: .zero, heightFraction: 1, variation: 0.5, time: 0)
            == frozen.offset(at: .zero, heightFraction: 1, variation: 0.5, time: 90))
}

@Test func grassRejectsInvalidInputWithoutUnboundedAllocation() throws {
    #expect(throws: (any Error).self) { try GrassWind(direction: .zero) }
    #expect(throws: (any Error).self) { try GrassWind(strength: .nan) }
    #expect(throws: (any Error).self) { try GrassDetail(nearDistance: 5, farDistance: 4) }
    #expect(throws: (any Error).self) { try GrassAppearance(rootColor: .init(red: 2, green: 0, blue: 0)) }
    #expect(throws: (any Error).self) { try GrassBlade(root: .zero, height: 0, width: 0.1, heading: 0) }
    #expect(throws: (any Error).self) { try GrassFieldDefinition(blades: [], chunkSize: .nan) }
    let sparse = try (0...1_024).map { try GrassBlade(root: [Float($0) * 2, 0, 0], height: 0.5, width: 0.05, heading: 0) }
    #expect(throws: (any Error).self) { try GrassFieldDefinition(blades: sparse, chunkSize: 1) }
    #expect(throws: (any Error).self) {
        try GrassFieldDefinition.scatter(minimum: .zero, maximum: [10_000, 10_000], density: 100,
                                         seed: 1, surfaceHeight: { _ in 0 })
    }
    #expect(throws: (any Error).self) {
        try GrassFieldDefinition.scatter(minimum: .zero, maximum: [1, 1], density: 10,
                                         seed: 1, surfaceHeight: { _ in 0 }, mask: { _ in .nan })
    }
    #expect(throws: (any Error).self) {
        try GrassFieldDefinition.scatter(minimum: .zero, maximum: [1, 1], density: 10,
                                         seed: 1, surfaceHeight: { _ in .infinity })
    }
}
