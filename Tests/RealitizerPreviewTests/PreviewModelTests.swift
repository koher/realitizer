import Realitizer
import RealitizerRealityKit
import RealityKit
import Testing
import simd

@testable import RealitizerPreview

@Test func previewStudyGeneratesFromCodeAtExtremesAndMultipleSeeds() throws {
    for maximum in [false, true] {
        for seed: UInt64 in [0, 42] {
            var input = previewStudyGenerator.defaultInput
            input.seed = seed
            input.parameters.height = maximum ? 2.2 : 1.2
            input.parameters.width = maximum ? 0.28 : 0.12
            let asset = try previewStudyGenerator.generate(input)
            #expect(asset.validationReport().diagnostics.isEmpty)
            #expect(asset.parts.first?.geometry.skin != nil)
        }
    }
}

@MainActor @Test func codeConfiguredPreviewSupportsEveryDiagnosticMode() async throws {
    for mode in PreviewDebugMode.allCases {
        var options = previewStudyOptions
        options.display = mode
        options.levelOfDetail = 1
        options.camera = .orthographic
        let model = ModelAssetPreviewModel(generator: previewStudyGenerator, options: options)
        await model.regenerate(detached: false)
        #expect(model.status == "Ready", "\(mode.rawValue): \(model.diagnostic)")
        let instance = try #require(model.instance)
        #expect(try instance.levelOfDetail(for: AnyRealitizerID("surface")) == 1)
        #expect(model.cameraEntity.components[OrthographicCameraComponent.self] != nil)
        if mode == .rig { #expect(model.overlay.children.count >= 4) }
        if mode == .rig || mode == .collisions {
            for part in instance.definition.parts { #expect(try !instance.meshEntity(part.id).isEnabled) }
        }
    }
}

@MainActor @Test func codeConfiguredGraphSampleIsDeterministic() async throws {
    var options = previewStudyOptions
    options.configuration.selectedClipID = nil
    options.configuration.graphStateID = AnyRealitizerID("sway")
    options.configuration.sampleTime = 0.65
    let model = ModelAssetPreviewModel(generator: previewStudyGenerator, options: options)
    await model.regenerate(detached: false)
    let first = try #require(model.instance)
    let pose = first.currentPose.transforms
    await model.regenerate()
    #expect(model.status == "Ready")
    #expect(model.instance !== first)
    #expect(model.instance?.currentPose.transforms == pose)
}

@MainActor @Test func previewReportsGenerationFailureWithoutPlaceholderGeometry() async {
    let generator = ModelAssetGenerator(name: "Invalid") { _ in
        _ = try MeshBuilder.box(size: [-1, 1, 1])
        return ModelAssetDefinition(name: "Unreachable", materials: [], parts: [])
    }
    let model = ModelAssetPreviewModel(generator: generator)
    await model.regenerate(detached: false)
    #expect(model.status == "Failed" && !model.diagnostic.isEmpty && model.instance == nil)
}

@MainActor @Test func previewErrorsAreSeparateFromGameAssetValidation() async throws {
    let asset = try previewStudyGenerator.generate()
    var options = previewStudyOptions
    options.configuration.selectedClipID = AnyRealitizerID("missing")
    #expect(asset.validationReport().diagnostics.isEmpty)
    #expect(throws: ModelValidationError.self) { try options.validate(for: asset) }
    let model = ModelAssetPreviewModel(generator: previewStudyGenerator, options: options)
    await model.regenerate(detached: false)
    #expect(model.status == "Failed" && model.instance == nil)
}

@Test func codeInputOptionAndContentRevisionChangesReplacePreviewIdentity() {
    let input = previewStudyGenerator.defaultInput
    let initial = PreviewIdentity(
        name: "study", version: 1, input: input, options: previewStudyOptions, revision: 0)
    var changedInput = input
    changedInput.parameters.height = 2
    #expect(
        initial
            != PreviewIdentity(
                name: "study", version: 1, input: changedInput, options: previewStudyOptions, revision: 0))
    var options = previewStudyOptions
    options.configuration.sampleTime = 1
    #expect(
        initial
            != PreviewIdentity(name: "study", version: 1, input: input, options: options, revision: 0))
    #expect(
        initial
            != PreviewIdentity(
                name: "study", version: 1, input: input, options: previewStudyOptions, revision: 1))
}
