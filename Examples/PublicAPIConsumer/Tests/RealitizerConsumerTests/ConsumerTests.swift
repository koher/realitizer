import Foundation
import RealitizerConsumer
import Testing
import simd

@Test func publicSurfaceFinishingPipelineDefinesAColoredBeveledProp() throws {
    let prop = try makeFinishedProp()
    let mesh = prop.parts[0].geometry.mesh
    #expect(mesh.triangleCount > 12)
    #expect(mesh.vertices.allSatisfy { $0.textureCoordinate.x >= 0 && $0.textureCoordinate.x <= 1 })
    #expect(prop.materials[0].vertexColorMode == .multiply)
    #expect(mesh.vertices.contains { $0.color != mesh.vertices[0].color })
}

@Test func publicModelingPipelineCreatesAHollowCylinderAndABoundColumn() throws {
    let hollow = try makeHollowCylinder()
    #expect(hollow.triangleCount > 0)
    #expect(hollow.vertices.allSatisfy { simd_length(SIMD2($0.position.x, $0.position.z)) > 0.25 })
    // The polygonal ring has a volume near pi * (0.5^2 - 0.3^2) * 1.
    #expect(abs(hollow.signedVolume - .pi * 0.16) < 0.06)
    let column = try makeArticulatedColumn()
    #expect(column.parts.count == 1)
    #expect(column.parts[0].geometry.skin != nil)
    #expect(column.parts[0].geometry.morphTargets.count == 1)
}

@MainActor @Test func publicProductsCompileAndInstantiate() throws {
    let instance = try compileConsumerAsset()
    #expect(instance.definition.name == "Vessel")
    #expect(instance.statistics.vertices > 0)
}

#if os(iOS)
    @MainActor @Test func codeOwnedResourceExampleRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResourceExample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prop.reality")
        try await bakeResourceProp(to: url)
        let compiled = try await loadResourceProp(from: url)
        let instance = try compiled.instantiate()
        #expect(instance.definition.name == "Resource prop")
        #expect(instance.statistics.vertices > 100)
        #expect(instance.definition.parts[0].geometry.mesh.vertices.allSatisfy { $0.color.green > 0 })
        let rigid = try await loadRigidResourceProp(from: url)
        let first = try rigid.instantiate(), second = try rigid.instantiate()
        #expect(first.root !== second.root)
        let body = rigid.definition.parts[0].id
        let handle = try first.part(body)
        try first.setLevelOfDetail(10, part: body)
        #expect(try first.levelOfDetail(for: body) == 0)
        #expect(try first.part(body) === handle)
        #expect(try second.levelOfDetail(for: body) == 0)
        let inspected = try rigid.inspect()
        #expect(inspected.definition.parts[0].geometry.mesh == compiled.definition.parts[0].geometry.mesh)
    }

    @MainActor @Test func xcodeCompilesAndLoadsBundledVertexColorShaders() throws {
        let instance = try compileBundledFinishedProp()
        #expect(instance.definition.name == "Finished prop")
        #expect(instance.statistics.vertices > 0)
    }

    @MainActor @Test func xcodeCompilesAndLoadsBundledEnvironmentShaders() throws {
        try exerciseBundledEnvironment()
    }
#endif
