import Realitizer
import Testing
import simd

private let state = AnyRealitizerID("idle")
private let go = AnyRealitizerID("go")

@Test func colorsHaveExplicitSRGBAndRawTextureContracts() throws {
    let linear = RGBAColor(linearSRGB: [0.5, 0.5, 0.5], alpha: 0.5)
    #expect(abs(linear.red - 0.735357) < 0.00001)
    #expect(simd_distance(linear.linearSRGB, [0.5, 0.5, 0.5]) < 0.00001)
    #expect(linear.alpha == 0.5)
    let color = try TextureImage.generate(width: 1, height: 1) { _ in linear }
    #expect(color.pixels == [188, 188, 188, 128] && color.encoding == .sRGB)
    let raw = try TextureImage.generateData(width: 1, height: 1) { _ in [0.5, 0.5, 0.5, 1] }
    #expect(raw.pixels == [128, 128, 128, 255] && raw.encoding == .raw)
    let normal = try TextureImage.normalMap(size: 1) { _ in 0 }
    #expect(normal.pixels == [128, 128, 255, 255] && normal.encoding == .raw)
    var material = MaterialDefinition(id: state, baseColor: .white)
    material.normalTexture = color
    #expect(throws: ModelValidationError.self) { try material.validate() }
    material.normalTexture = normal
    try material.validate()
}

@Test func graphRejectsUndeclaredAndWrongKindInputsWithoutChangingState() throws {
    let clip = AnimationClipDefinition(id: state, duration: 1, channels: [])
    let graph = AnimationGraphDefinition(id: go, initialState: state, parameters: [
        AnimationParameterDefinition(id: go, kind: .trigger),
        AnimationParameterDefinition(id: AnyRealitizerID("speed"), kind: .scalar(defaultValue: 0)),
        AnimationParameterDefinition(id: AnyRealitizerID("enabled"), kind: .boolean(defaultValue: false))
    ], states: [AnimationStateDefinition(id: state, clip: state)])
    var player = try AnimationGraphPlayer(graph: graph, clips: [clip])
    #expect(throws: ModelValidationError.self) { try player.set(true, for: go) }
    #expect(throws: ModelValidationError.self) { try player.set(Float(1), for: go) }
    #expect(throws: ModelValidationError.self) { try player.set(Float.nan, for: AnyRealitizerID("speed")) }
    #expect(throws: ModelValidationError.self) { try player.activate(AnyRealitizerID("missing")) }
    #expect(throws: ModelValidationError.self) { try player.activate(AnyRealitizerID("enabled")) }
    #expect(player.currentStateID == state && player.elapsedTimeInState == 0)
}

@Test func failedGraphAdvancePreservesPendingTriggersAndElapsedTime() throws {
    let destination = AnyRealitizerID("next")
    let idle = AnimationClipDefinition(id: state, duration: 1, channels: [])
    let busy = AnimationClipDefinition(id: destination, duration: 1, loopMode: .loop, channels: [],
        events: [AnimationEventDefinition(id: go, time: 0.5)])
    let graph = AnimationGraphDefinition(id: go, initialState: state,
        parameters: [AnimationParameterDefinition(id: go, kind: .trigger)],
        states: [AnimationStateDefinition(id: state, clip: state), AnimationStateDefinition(id: destination, clip: destination)],
        transitions: [AnimationTransitionDefinition(from: state, to: destination, conditions: [.triggeredBy(go)])])
    var player = try AnimationGraphPlayer(graph: graph, clips: [idle, busy])
    try player.activate(go)
    #expect(throws: ModelValidationError.self) { try player.advance(by: 20_000) }
    #expect(player.currentStateID == state && player.elapsedTimeInState == 0)
    let frame = try player.advance(by: 0.1)
    #expect(frame.stateID == destination && player.elapsedTimeInState == 0.1)
}

@Test func standaloneGraphValidatesClipsTransitionsAndScaledTime() throws {
    let clip = AnimationClipDefinition(id: state, duration: 1, channels: [])
    var graph = AnimationGraphDefinition(id: go, initialState: state,
        states: [AnimationStateDefinition(id: state, clip: state, speed: .greatestFiniteMagnitude)])
    var player = try AnimationGraphPlayer(graph: graph, clips: [clip])
    #expect(throws: ModelValidationError.self) { try player.advance(by: 2) }
    #expect(player.elapsedTimeInState == 0)
    graph.transitions = [AnimationTransitionDefinition(from: state, to: AnyRealitizerID("missing"))]
    #expect(throws: ModelValidationError.self) { try graph.validate(clips: [clip]) }
    graph.transitions = []
    var invalid = clip
    invalid.events = [AnimationEventDefinition(id: go, time: .nan)]
    #expect(throws: ModelValidationError.self) { try AnimationGraphPlayer(graph: graph, clips: [invalid]) }
}

@Test func dedicatedStructParametersPreserveTypesAndValidateWithoutAnEditor() throws {
    struct Parameters: Sendable { var count = 2; var hollow = true; var radius: Float = 1 }
    enum Failure: Error { case radius }
    let generator = ModelAssetGenerator(name: "Typed", parameters: Parameters(), validate: {
        guard $0.radius.isFinite && $0.radius > 0 else { throw Failure.radius }
    }) { input in
        #expect(input.parameters.count == 2 && input.parameters.hollow)
        return ModelAssetDefinition(name: "Typed", materials: [], parts: [])
    }
    _ = try generator.generate()
    var input = generator.defaultInput
    input.parameters.radius = .nan
    #expect(throws: Failure.self) { try generator.generate(input) }
}
