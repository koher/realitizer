import Realitizer
import RealitizerEnvironment
import Testing
import simd

@Test func waveNormalsMatchFiniteDifferences() throws {
    let field = try WaveField(waves: [
        DirectionalWave(direction: [1, 0.3], amplitude: 0.3, wavelength: 8, speed: 1.5),
        DirectionalWave(direction: [-0.6, 1], amplitude: 0.12, wavelength: 4, speed: 0.8),
    ])
    let p = SIMD3<Float>(1.3, -4, 2.2)
    let a = try field.vertex(at: p, time: 1.7)
    let dx = try field.vertex(at: p + [0.001, 0, 0], time: 1.7).position
        - field.vertex(at: p - [0.001, 0, 0], time: 1.7).position
    let dz = try field.vertex(at: p + [0, 0, 0.001], time: 1.7).position
        - field.vertex(at: p - [0, 0, 0.001], time: 1.7).position
    #expect(simd_distance(a.normal, simd_normalize(simd_cross(dz, dx))) < 0.001)
    #expect(abs(a.position.y - p.y) <= field.maximumVerticalDisplacement)
    #expect(abs(simd_dot(a.normal, SIMD3(a.tangent.x, a.tangent.y, a.tangent.z))) < 0.0001)
    #expect(a == (try field.vertex(at: p, time: 1.7)))
    #expect(a != (try field.vertex(at: p, time: 2.1)))
}

@Test func waveUpdatesPreserveUVTopologyAndRestCoordinates() throws {
    let field = try WaveField(waves: [DirectionalWave(direction: [1, 0], amplitude: 0.2, wavelength: 4, speed: 1)])
    let mesh = try MeshBuilder.surface(uSegments: 8, vSegments: 8) { [($0.x - 0.5) * 8, 0, (0.5 - $0.y) * 8] }
    let rest = mesh.vertices.map(\.position)
    var vertices = mesh.vertices
    try field.updateVertices(&vertices, restPositions: rest, time: 4)
    let first = vertices
    try field.updateVertices(&vertices, restPositions: rest, time: 4)
    #expect(vertices == first)
    #expect(vertices.map(\.textureCoordinate) == mesh.vertices.map(\.textureCoordinate))
    #expect(vertices.map(\.tangent.w) == mesh.vertices.map(\.tangent.w))
    #expect(MeshData(vertices: vertices, indices: mesh.indices).validationDiagnostics().isEmpty)
    #expect(throws: Error.self) { try field.updateVertices(&vertices, restPositions: [], time: 4) }
    #expect(vertices == first)
    #expect(throws: Error.self) { try field.updateVertices(&vertices, restPositions: rest, time: .infinity) }
    #expect(vertices == first)
}

@Test func invalidAndFoldingWavesAreRejected() throws {
    #expect(throws: Error.self) { try DirectionalWave(direction: .zero, amplitude: 1, wavelength: 4, speed: 1) }
    #expect(throws: Error.self) { try DirectionalWave(direction: [1, 0], amplitude: -1, wavelength: 4, speed: 1) }
    #expect(throws: Error.self) { try DirectionalWave(direction: [1, 0], amplitude: 1, wavelength: 0, speed: 1) }
    #expect(throws: Error.self) {
        try WaveField(waves: [DirectionalWave(direction: [1, 0], amplitude: 2, wavelength: 1, speed: 1)])
    }
    let empty = try WaveField(waves: [])
    #expect(try empty.vertex(at: [1, 2, 3], time: 4).position == [1, 2, 3])
    #expect(throws: Error.self) { try empty.vertex(at: [.nan, 0, 0], time: 0) }
}
