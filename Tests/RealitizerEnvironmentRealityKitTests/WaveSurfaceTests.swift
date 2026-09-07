@testable import RealitizerEnvironmentRealityKit
@testable import RealitizerRealityKit
import Metal
import Realitizer
import RealitizerEnvironment
import Testing
import simd

@MainActor @Test func gpuWavesMatchPortableSamplesAndKeepResources() throws {
    let mesh = try MeshBuilder.surface(uSegments: 16, vSegments: 16) { [($0.x - 0.5) * 20, 0, (0.5 - $0.y) * 20] }
        .coloring { RGBAColor(sRGB: [($0.position.x + 10) / 20, 0.3, 0.5]) }
    let field = try WaveField(waves: [
        DirectionalWave(direction: [1, 0.3], amplitude: 0.2, wavelength: 8, speed: 1),
        DirectionalWave(direction: [-0.4, 1], amplitude: 0.07, wavelength: 3, speed: -0.5, phase: 0.8),
    ])
    let surface = try WaveSurfaceMesh(mesh: mesh, field: field, resources: EnvironmentResources(library: EnvironmentTestLibrary.result.get()))
    let resource = surface.resource
    #expect(MemoryLayout<DynamicVertex>.stride == 96)
    #expect(MemoryLayout<DynamicVertex>.offset(of: \.color) == 80)
    #expect(MemoryLayout<DynamicVertex>.offset(of: \.normal) == 16)
    #expect(MemoryLayout<DynamicVertex>.offset(of: \.uv) == 32)
    #expect(MemoryLayout<DynamicVertex>.offset(of: \.tangent) == 48)
    #expect(MemoryLayout<DynamicVertex>.offset(of: \.bitangent) == 64)
    for time: Float in [0, 0.25, 10] {
        let command = try surface.update(time: time)
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(surface.resource === resource)
        let actual = readWaveVertices(surface)
        for i in mesh.vertices.indices {
            let reference = try field.vertex(at: mesh.vertices[i].position, time: time)
            #expect(simd_distance(actual[i].position, reference.position) < 0.0001)
            #expect(simd_distance(actual[i].normal, reference.normal) < 0.0001)
            #expect(abs(simd_dot(actual[i].normal, actual[i].tangent)) < 0.0001)
            #expect(actual[i].uv == mesh.vertices[i].textureCoordinate)
            #expect(actual[i].color == mesh.vertices[i].color.linearRGBA)
            #expect(simd_dot(simd_cross(actual[i].normal, actual[i].tangent), actual[i].bitangent) * mesh.vertices[i].tangent.w > 0.999)
            let bounds = surface.lowLevelMesh.parts.first!.bounds
            #expect(all(actual[i].position .>= bounds.min) && all(actual[i].position .<= bounds.max))
        }
    }
    let before = readWaveVertices(surface).map(\.position)
    #expect(throws: WaveSurfaceError.self) { try surface.update(time: .nan) }
    #expect(readWaveVertices(surface).map(\.position) == before)
}

@MainActor @Test func gpuWaveFadePreservesTheHorizonAndRejectsInvalidSurfaces() throws {
    let mesh = try MeshBuilder.surface(uSegments: 20, vSegments: 20) { [($0.x - 0.5) * 40, -2, (0.5 - $0.y) * 40] }
    let field = try WaveField(waves: [DirectionalWave(direction: [1, 0.3], amplitude: 0.2, wavelength: 8, speed: 1)])
    let surface = try WaveSurfaceMesh(mesh: mesh, field: field, radialFade: 5...15, resources: EnvironmentResources(library: EnvironmentTestLibrary.result.get()))
    try surface.update(time: 1).waitUntilCompleted()
    let actual = readWaveVertices(surface)
    for i in mesh.vertices.indices {
        let rest = mesh.vertices[i].position
        let radius = simd_length(SIMD2(rest.x, rest.z))
        if radius >= 15 {
            #expect(actual[i].position == rest)
            #expect(simd_distance(actual[i].normal, [0, 1, 0]) < 0.0001)
        } else if radius <= 5 {
            #expect(simd_distance(actual[i].position, try field.vertex(at: rest, time: 1).position) < 0.0001)
        } else {
            func point(_ p: SIMD3<Float>) throws -> SIMD3<Float> {
                let t = max(0, min(1, (15 - simd_length(SIMD2(p.x, p.z))) / 10))
                return p + (try field.vertex(at: p, time: 1).position - p) * t * t * (3 - 2 * t)
            }
            let dx = try point(rest + [0.001, 0, 0]) - point(rest - [0.001, 0, 0])
            let dz = try point(rest + [0, 0, 0.001]) - point(rest - [0, 0, 0.001])
            #expect(simd_distance(actual[i].normal, simd_normalize(simd_cross(dz, dx))) < 0.002)
        }
    }
    #expect(throws: WaveSurfaceError.self) { try WaveSurfaceMesh(mesh: mesh, field: field, radialFade: 1...1) }
    #expect(throws: WaveSurfaceError.self) { try WaveSurfaceMesh(mesh: MeshBuilder.box(size: [1, 1, 1]), field: field) }
    let calm = try WaveSurfaceMesh(mesh: mesh, field: WaveField(waves: []), resources: EnvironmentResources(library: EnvironmentTestLibrary.result.get()))
    try calm.update(time: 0).waitUntilCompleted()
    #expect(readWaveVertices(calm).map(\.position) == mesh.vertices.map(\.position))
}

@MainActor private func readWaveVertices(_ surface: WaveSurfaceMesh) -> [DynamicVertex] {
    var result: [DynamicVertex] = []
    surface.lowLevelMesh.withUnsafeBytes(bufferIndex: 0) { result = Array($0.bindMemory(to: DynamicVertex.self)) }
    return result
}
