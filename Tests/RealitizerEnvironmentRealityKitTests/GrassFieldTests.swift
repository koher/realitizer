@testable import RealitizerEnvironmentRealityKit
@testable import RealitizerRealityKit
import Foundation
import Metal
import Realitizer
import RealitizerEnvironment
import RealityKit
import Testing
import simd

@MainActor @Test func grassChunksCacheMeshesAndApplyDistanceLOD() throws {
    let library = try EnvironmentTestLibrary.result.get()
    let definition = try GrassFieldDefinition.scatter(minimum: .zero, maximum: [3, 3], density: 20,
                                                     seed: 35, surfaceHeight: { _ in 0 })
    let field = try GrassField(definition, wind: GrassWind(), detail: GrassDetail(),
                              appearance: GrassAppearance(), resources: EnvironmentResources(library: library))
    #expect(field.root.children.count == 1)
    try field.update(time: 0, cameraPosition: [1, 1, 1])
    let entity = try #require(field.root.children.first as? ModelEntity)
    let near = try #require(entity.model?.mesh)
    #expect(field.statistics.activeBlades == definition.blades.count)
    #expect(field.statistics.activeTriangles == definition.blades.count * 3)
    #expect(entity.model?.boundsMargin == field.wind.boundsMargin)
    #expect(entity.components[DynamicLightShadowComponent.self]?.castsShadow == false)
    try field.update(time: 1, cameraPosition: [1, 1, 1])
    #expect(entity.model?.mesh === near)
    let material = try #require(entity.model?.materials.first as? CustomMaterial)
    #expect(material.lightingModel == .unlit)
    #expect(material.custom.value.x == 1)
    try field.update(time: 2, cameraPosition: [40, 1, 1])
    let far = try #require(entity.model?.mesh)
    #expect(far !== near)
    #expect(field.statistics.activeTriangles == (definition.blades.count + 2) / 3)
    try field.update(time: 3, cameraPosition: [150, 1, 1])
    #expect(!entity.isEnabled && field.statistics.activeChunks == 0)
    try field.update(time: 4, cameraPosition: [1, 1, 1])
    #expect(entity.isEnabled && entity.model?.mesh === near)
    let statistics = field.statistics
    #expect(throws: GrassFieldError.invalidUpdate) { try field.update(time: .nan, cameraPosition: .zero) }
    #expect(field.statistics == statistics)
    let empty = try GrassField(GrassFieldDefinition(blades: []), wind: GrassWind(), detail: GrassDetail(),
                              appearance: GrassAppearance(), resources: EnvironmentResources(library: library))
    try empty.update(time: 0, cameraPosition: .zero)
    #expect(empty.root.children.isEmpty && empty.statistics.activeChunks == 0)
}

@MainActor @Test func grassLODUsesHysteresis() throws {
    let detail = try GrassDetail(nearDistance: 20, farDistance: 60, hysteresis: 2)
    #expect(GrassField.level(distance: 21, previous: .near, detail: detail) == .near)
    #expect(GrassField.level(distance: 21, previous: .far, detail: detail) == .far)
    #expect(GrassField.level(distance: 61, previous: .far, detail: detail) == .far)
    #expect(GrassField.level(distance: 61, previous: .hidden, detail: detail) == .hidden)
    #expect(GrassField.level(distance: 63, previous: .near, detail: detail) == .hidden)
}

@MainActor @Test func grassGPUWindMatchesCPUAndPinsRoots() throws {
    let library = try EnvironmentTestLibrary.result.get()
    let device = library.device
    let function = try #require(library.makeFunction(name: "realitizer_grass_wind_samples"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let queue = try #require(device.makeCommandQueue())
    let positions: [SIMD4<Float>] = [[0, 0, 0, 0], [1, 2, 3, 0], [-7, -20, 15, 0], [41, 5, -8, 0]]
    let weights: [SIMD2<Float>] = [[0, 0.1], [0.52, 0.5], [1, 0.75], [1, 0.98]]
    let wind = try GrassWind(direction: [0.8, -0.6], strength: 0.3, speed: 1.7)
    let output = try #require(device.makeBuffer(length: positions.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
    for time: Float in [0, 0.25, 12, 200] {
        var uniforms = SIMD4(time * wind.speed, wind.direction.x * wind.strength, wind.direction.y * wind.strength, 0)
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        positions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        weights.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setBuffer(output, offset: 0, index: 3)
        encoder.dispatchThreads(.init(width: positions.count, height: 1, depth: 1),
                                threadsPerThreadgroup: .init(width: positions.count, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let actual = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: positions.count)
        for index in positions.indices {
            let p = positions[index]
            let expected = try wind.offset(at: [p.x, p.y, p.z], heightFraction: weights[index].x,
                                           variation: weights[index].y, time: time)
            #expect(simd_distance(SIMD3(actual[index].x, actual[index].y, actual[index].z), expected) < 0.00002)
        }
    }
}

/// Native SwiftPM copies Metal source rather than invoking Xcode's resource compiler.
/// Compile a test-only library with the host SDK; production never launches a compiler.
@MainActor enum EnvironmentTestLibrary {
    static let result: Result<any MTLLibrary, any Error> = Result {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #if os(macOS)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RealitizerGrassTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Grass.metallib")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "metal", "-fmodules-cache-path=\(directory.path)/Cache",
                             package.appendingPathComponent("Sources/RealitizerEnvironmentRealityKit/Shaders/Grass.metal").path,
                             package.appendingPathComponent("Sources/RealitizerEnvironmentRealityKit/Shaders/Waves.metal").path,
                             "-o", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let diagnostics = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Metal compiler: \(String(decoding: diagnostics, as: UTF8.self))")
        return try device.makeLibrary(URL: output)
        #else
        // An iOS test runner must be built by Xcode with the package's resource bundle.
        return try EnvironmentResources.shared().library
        #endif
    }
}
