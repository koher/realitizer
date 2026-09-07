import Realitizer
import Testing

private enum PartID: String, RealitizerID {
    case body
}

private enum ClipID: String, RealitizerID {
    case idle
    case action
}

private enum EventID: String, RealitizerID {
    case pulse
}

private enum GraphID: String, RealitizerID {
    case locomotion
}

private enum StateID: String, RealitizerID {
    case idle
    case action
}

private enum ParameterID: String, RealitizerID {
    case act
}

@Test
func clipSamplesTransformsAndLoopingEventsDeterministically() throws {
    let clip = AnimationClipDefinition(
        id: ClipID.action,
        duration: 1,
        loopMode: .loop,
        channels: [
            TransformAnimationChannel(
                target: .part(id: PartID.body),
                keyframes: [
                    TransformKeyframe(time: 0, transform: .identity),
                    TransformKeyframe(
                        time: 1,
                        transform: ModelTransform(translation: [0, 2, 0])
                    ),
                ]
            )
        ],
        events: [AnimationEventDefinition(id: EventID.pulse, time: 0.25)]
    )

    let sample = clip.sample(at: 0.5)
    let events = try clip.events(from: 0.2, to: 2.3)

    #expect(sample.transforms[.part(id: PartID.body)]?.translation == [0, 1, 0])
    #expect(events.map(\.elapsedTime) == [0.25, 1.25, 2.25])
}

@Test
func stateGraphConsumesTriggerAndBlendsIntoDestination() throws {
    let idle = constantClip(id: ClipID.idle, height: 0)
    let action = constantClip(id: ClipID.action, height: 2)
    let graph = AnimationGraphDefinition(
        id: GraphID.locomotion,
        initialState: StateID.idle,
        parameters: [AnimationParameterDefinition(id: ParameterID.act, kind: .trigger)],
        states: [
            AnimationStateDefinition(id: StateID.idle, clip: ClipID.idle),
            AnimationStateDefinition(id: StateID.action, clip: ClipID.action),
        ],
        transitions: [
            AnimationTransitionDefinition(
                from: StateID.idle,
                to: StateID.action,
                duration: 0.2,
                conditions: [.triggeredBy(ParameterID.act)]
            )
        ]
    )
    var player = try AnimationGraphPlayer(graph: graph, clips: [idle, action])

    try player.activate(ParameterID.act)
    let frame = try player.advance(by: 0.1)

    #expect(frame.stateID == StateID.action.erasedID)
    #expect(frame.transitionProgress == 0.5)
    #expect(frame.pose.transforms[.part(id: PartID.body)]?.translation == [0, 1, 0])
}

private func constantClip(id: ClipID, height: Float) -> AnimationClipDefinition {
    AnimationClipDefinition(
        id: id,
        duration: 1,
        loopMode: .loop,
        channels: [
            TransformAnimationChannel(
                target: .part(id: PartID.body),
                keyframes: [
                    TransformKeyframe(
                        time: 0,
                        transform: ModelTransform(translation: [0, height, 0])
                    )
                ]
            )
        ]
    )
}
