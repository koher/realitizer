import Realitizer
import RealitizerPreview
import RealitizerRealityKit
import RealitizerEnvironment
import RealitizerEnvironmentRealityKit
import RealityKit
import SwiftUI

public struct VesselParameters: Equatable, Sendable {
    public var height: Float = 1
    public var ribs = 12
    public var polished = true
    public init() {}
}

public let vessel = ModelAssetGenerator(name: "Vessel", parameters: VesselParameters(), validate: {
    guard $0.height.isFinite && (0.6...1.4).contains($0.height) && (8...32).contains($0.ribs) else {
        throw ConsumerError.invalidParameters
    }
}) { input in
    let mesh = try MeshBuilder.revolve(
        profile: [[0, 0], [0.3, 0], [0.4, input.parameters.height * 0.6],
                  [0.22, input.parameters.height], [0, input.parameters.height]],
        segments: input.parameters.ribs)
    return ModelAssetDefinition(name: "Vessel", materials: [
        MaterialDefinition(id: AnyRealitizerID("ceramic"), baseColor: RGBAColor(sRGB: [0.1, 0.6, 0.5]),
            roughness: input.parameters.polished ? 0.25 : 0.8)
    ], parts: [ModelPartDefinition(id: AnyRealitizerID("body"), mesh: mesh, material: AnyRealitizerID("ceramic"))])
}

public enum ConsumerError: Error { case invalidParameters }

@MainActor public func compileConsumerAsset() throws -> RuntimeModelInstance {
    try RealityKitModelCompiler.compile(vessel.generate()).instantiate()
}

/// This intentionally uses the production bundle: no injected test library or @testable imports.
@MainActor public func exerciseBundledEnvironment() throws {
    let resources = try EnvironmentResources.shared()
    let field = try GrassFieldDefinition.scatter(minimum: [-1, -1], maximum: [1, 1],
        density: 10, seed: 7, surfaceHeight: { _ in 0 })
    let grass = try GrassField(field, wind: GrassWind(), detail: GrassDetail(),
        appearance: GrassAppearance(rootColor: .init(sRGB: [0.3, 0.5, 0.1]),
            tipColor: .init(sRGB: [0.4, 0.6, 0.2])), resources: resources)
    try grass.update(time: 1, cameraPosition: [0, 2, 3])
    let mesh = try MeshBuilder.surface(uSegments: 4, vSegments: 4) { [$0.x, 0, -$0.y] }
    let waves = try WaveField(waves: [DirectionalWave(direction: [1, 0], amplitude: 0.02, wavelength: 4, speed: 1)])
    let water = try WaveSurfaceMesh(mesh: mesh, field: waves, resources: resources)
    let command = try water.update(time: 1)
    command.waitUntilCompleted() // Integration check only, never the gameplay loop.
    if command.error != nil { throw command.error! }
}

#Preview("Public API Consumer") {
    ModelAssetPreview(generator: vessel)
}
