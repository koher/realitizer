/// The storage and default value for an animation parameter.
public enum AnimationParameterKind: Equatable, Sendable {
    case boolean(defaultValue: Bool)
    case scalar(defaultValue: Float)
    case trigger
}

/// A semantic input consumed by an animation state graph.
public struct AnimationParameterDefinition: Sendable {
    public let id: AnyRealitizerID
    public var kind: AnimationParameterKind

    public init<ID: RealitizerID>(id: ID, kind: AnimationParameterKind) {
        self.id = id.erasedID
        self.kind = kind
    }
}

/// A condition that guards an animation transition.
public enum AnimationCondition: Equatable, Sendable {
    case always
    case boolean(AnyRealitizerID, equals: Bool)
    case scalarGreaterThan(AnyRealitizerID, Float)
    case scalarLessThan(AnyRealitizerID, Float)
    case trigger(AnyRealitizerID)

    public static func boolEquals<ID: RealitizerID>(_ id: ID, _ value: Bool) -> Self {
        .boolean(id.erasedID, equals: value)
    }

    public static func greaterThan<ID: RealitizerID>(_ id: ID, _ value: Float) -> Self {
        .scalarGreaterThan(id.erasedID, value)
    }

    public static func lessThan<ID: RealitizerID>(_ id: ID, _ value: Float) -> Self {
        .scalarLessThan(id.erasedID, value)
    }

    public static func triggeredBy<ID: RealitizerID>(_ id: ID) -> Self {
        .trigger(id.erasedID)
    }

    var parameterID: AnyRealitizerID? {
        switch self {
        case .always:
            nil
        case .boolean(let id, _), .scalarGreaterThan(let id, _),
            .scalarLessThan(let id, _), .trigger(let id):
            id
        }
    }
}

/// A named state that plays one clip.
public struct AnimationStateDefinition: Sendable {
    public let id: AnyRealitizerID
    public var clipID: AnyRealitizerID
    public var speed: Float
    public var blendSpace: BlendSpaceDefinition? = nil

    public init<ID: RealitizerID, ClipID: RealitizerID>(
        id: ID,
        clip: ClipID,
        speed: Float = 1
    ) {
        self.id = id.erasedID
        clipID = clip.erasedID
        self.speed = speed
    }
}

/// A deterministic ordered transition between animation states.
public struct AnimationTransitionDefinition: Sendable {
    public var sourceStateID: AnyRealitizerID
    public var destinationStateID: AnyRealitizerID
    public var duration: Float
    public var conditions: [AnimationCondition]
    public var easing: TransformInterpolation = .linear
    public var interruptible: Bool = false
    public var preserveNormalizedTime: Bool = false

    public init<SourceID: RealitizerID, DestinationID: RealitizerID>(
        from source: SourceID,
        to destination: DestinationID,
        duration: Float = 0.15,
        conditions: [AnimationCondition] = [.always]
    ) {
        sourceStateID = source.erasedID
        destinationStateID = destination.erasedID
        self.duration = duration
        self.conditions = conditions
    }
}

/// A portable state graph evaluated without a rendering engine.
public struct AnimationGraphDefinition: Sendable {
    public let id: AnyRealitizerID
    public var initialStateID: AnyRealitizerID
    public var parameters: [AnimationParameterDefinition]
    public var states: [AnimationStateDefinition]
    public var transitions: [AnimationTransitionDefinition]
    /// Evaluated in array order after the base state/crossfade. Masks make ownership explicit.
    public var layers: [AnimationLayerDefinition] = []

    public init<ID: RealitizerID, StateID: RealitizerID>(
        id: ID,
        initialState: StateID,
        parameters: [AnimationParameterDefinition] = [],
        states: [AnimationStateDefinition],
        transitions: [AnimationTransitionDefinition] = []
    ) {
        self.id = id.erasedID
        initialStateID = initialState.erasedID
        self.parameters = parameters
        self.states = states
        self.transitions = transitions
    }
}

/// One deterministic state graph evaluation result.
public struct AnimationFrame: Sendable {
    public let stateID: AnyRealitizerID
    public var pose: SampledAnimationPose
    public let events: [AnimationEventOccurrence]
    public let transitionProgress: Float?
    public var rootMotion: ModelTransform = .identity

    public init(
        stateID: AnyRealitizerID,
        pose: SampledAnimationPose,
        events: [AnimationEventOccurrence],
        transitionProgress: Float?
    ) {
        self.stateID = stateID
        self.pose = pose
        self.events = events
        self.transitionProgress = transitionProgress
    }
}

/// Mutable per-instance state for a portable animation graph.
public struct AnimationGraphPlayer: Sendable {
    public let graph: AnimationGraphDefinition
    private let clips: [AnyRealitizerID: AnimationClipDefinition]
    public private(set) var currentStateID: AnyRealitizerID
    public private(set) var elapsedTimeInState: Float = 0
    private var booleans: [AnyRealitizerID: Bool] = [:]
    private var scalars: [AnyRealitizerID: Float] = [:]
    private var triggers: Set<AnyRealitizerID> = []
    private var transition: ActiveTransition?
    private var totalTime: Float = 0
    private let referencePose: PoseDefinition
    private var lastBasePose: SampledAnimationPose?
    private let referenceScalars: [ScalarAnimationTarget: Float]
    private var layerWeights: [AnyRealitizerID: Float] = [:]

    public init(
        graph: AnimationGraphDefinition,
        clips: [AnimationClipDefinition],
        referencePose: PoseDefinition = PoseDefinition(id: AnyRealitizerID(rawValue: "reference"), transforms: [:]),
        referenceScalars: [ScalarAnimationTarget: Float] = [:]
    ) throws {
        try graph.validate(clips: clips)
        self.graph = graph
        self.referencePose = referencePose
        let scalarTargets = Set(clips.flatMap { $0.scalarChannels.map(\.target) })
        self.referenceScalars = referenceScalars.filter { scalarTargets.contains($0.key) }
        guard Set(clips.map(\.id)).count == clips.count, Set(graph.states.map(\.id)).count == graph.states.count,
            Set(graph.parameters.map(\.id)).count == graph.parameters.count,
            clips.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }),
            graph.states.allSatisfy({ state in
                state.speed.isFinite && state.speed >= 0 && clips.contains(where: { $0.id == state.clipID })
            })
        else {
            throw modelingError(
                "graph.definition",
                "Graph states, parameters and clips require unique identifiers and valid durations, speeds and references."
            )
        }
        var clipsByID: [AnyRealitizerID: AnimationClipDefinition] = [:]
        for clip in clips {
            clipsByID[clip.id] = clip
        }
        self.clips = clipsByID
        currentStateID = graph.initialStateID

        for parameter in graph.parameters {
            switch parameter.kind {
            case .boolean(let defaultValue):
                booleans[parameter.id] = defaultValue
            case .scalar(let defaultValue):
                scalars[parameter.id] = defaultValue
            case .trigger:
                break
            }
        }

        guard state(for: currentStateID) != nil else {
            throw AnimationRuntimeError.missingState(currentStateID)
        }
        guard let initialState = state(for: currentStateID), self.clips[initialState.clipID] != nil else {
            throw AnimationRuntimeError.missingClipForState(currentStateID)
        }
    }

    public mutating func set<ID: RealitizerID>(_ value: Bool, for id: ID) throws {
        guard booleans[id.erasedID] != nil else {
            throw modelingError("graph.parameterType", "Expected a declared Boolean parameter.")
        }
        booleans[id.erasedID] = value
    }

    public mutating func set<ID: RealitizerID>(_ value: Float, for id: ID) throws {
        guard scalars[id.erasedID] != nil, value.isFinite else {
            throw modelingError("graph.parameterType", "Expected a declared scalar parameter and a finite value.")
        }
        scalars[id.erasedID] = value
    }

    public mutating func activate<ID: RealitizerID>(_ id: ID) throws {
        guard graph.parameters.contains(where: { $0.id == id.erasedID && $0.kind == .trigger }) else {
            throw modelingError("graph.parameterType", "Expected a declared trigger parameter.")
        }
        triggers.insert(id.erasedID)
    }

    public mutating func setLayerWeight<ID: RealitizerID>(_ weight: Float, for id: ID) throws {
        guard weight.isFinite, (0...1).contains(weight), graph.layers.contains(where: { $0.id == id.erasedID }) else {
            throw modelingError("graph.layerWeight", "Layer overrides require a declared layer and weight in [0, 1].")
        }
        layerWeights[id.erasedID] = weight
    }

    /// Failed evaluation leaves times, transitions and pending triggers unchanged.
    public mutating func advance(by deltaTime: Float) throws -> AnimationFrame {
        var candidate = self
        let frame = try candidate.advanceInPlace(by: deltaTime)
        self = candidate
        return frame
    }

    private mutating func advanceInPlace(by deltaTime: Float) throws -> AnimationFrame {
        guard deltaTime.isFinite, deltaTime >= 0 else {
            throw AnimationRuntimeError.invalidDeltaTime(deltaTime)
        }
        guard scalars.values.allSatisfy(\.isFinite), (elapsedTimeInState + deltaTime).isFinite,
            (totalTime + deltaTime).isFinite
        else { throw modelingError("graph.numericInput", "Graph parameters and accumulated time must remain finite.") }

        if transition == nil || transition?.interruptible == true,
            let next = graph.transitions.first(where: {
                $0.sourceStateID == currentStateID && conditionsPass($0.conditions)
            })
        {
            try begin(next)
        }

        guard let currentState = state(for: currentStateID),
            let currentClip = clips[currentState.clipID]
        else {
            throw AnimationRuntimeError.missingClipForState(currentStateID)
        }

        let previousElapsedTime = elapsedTimeInState
        elapsedTimeInState += deltaTime * currentState.speed
        guard elapsedTimeInState.isFinite else {
            throw modelingError("graph.timeOverflow", "Scaled animation time must remain finite.")
        }
        let currentPose = try sample(currentState, at: elapsedTimeInState)
        let events = try currentClip.events(from: previousElapsedTime, to: elapsedTimeInState)
        let rootMotion = try motion(currentState, from: previousElapsedTime, to: elapsedTimeInState)
        totalTime += deltaTime

        if var active = transition {
            active.elapsedTime += deltaTime
            active.sourceElapsedTime += deltaTime * active.sourceSpeed
            let sourcePose = try active.frozenPose ?? sample(active.sourceState, at: active.sourceElapsedTime)
            let progress = active.duration <= 0 ? 1 : min(active.elapsedTime / active.duration, 1)
            let amount: Float
            switch active.easing {
            case .linear: amount = progress
            case .step: amount = progress >= 1 ? 1 : 0
            case .smoothStep: amount = progress * progress * (3 - 2 * progress)
            }
            let pose = sourcePose.blended(with: currentPose, progress: amount)
            lastBasePose = pose
            transition = progress >= 1 ? nil : active
            var frame = AnimationFrame(
                stateID: currentStateID,
                pose: try applyLayers(to: pose),
                events: events,
                transitionProgress: progress
            )
            let sourceMotion = try motion(
                active.sourceState, from: active.sourceElapsedTime - deltaTime * active.sourceSpeed,
                to: active.sourceElapsedTime)
            frame.rootMotion = sourceMotion.interpolated(to: rootMotion, progress: amount)
            return frame
        }

        lastBasePose = currentPose
        var frame = AnimationFrame(
            stateID: currentStateID,
            pose: try applyLayers(to: currentPose),
            events: events,
            transitionProgress: nil
        )
        frame.rootMotion = rootMotion
        return frame
    }

    /// Repositions the state machine for deterministic authoring without replaying prior events.
    public mutating func seek<State: RealitizerID>(state id: State, time: Float = 0) throws -> AnimationFrame {
        var candidate = self
        let frame = try candidate.seekInPlace(state: id, time: time)
        self = candidate
        return frame
    }

    private mutating func seekInPlace<State: RealitizerID>(state id: State, time: Float) throws -> AnimationFrame {
        guard time.isFinite, time >= 0, let state = state(for: id.erasedID) else {
            throw AnimationRuntimeError.missingState(id.erasedID)
        }
        currentStateID = id.erasedID
        elapsedTimeInState = time
        totalTime = time
        transition = nil
        triggers.removeAll()
        let base = try sample(state, at: time)
        lastBasePose = base
        return AnimationFrame(
            stateID: currentStateID, pose: try applyLayers(to: base), events: [], transitionProgress: nil)
    }

    private func motion(_ state: AnimationStateDefinition, from start: Float, to end: Float) throws -> ModelTransform {
        guard let reference = clips[state.clipID] else { throw AnimationRuntimeError.missingClipForState(state.id) }
        guard let space = state.blendSpace else { return try reference.rootMotion(from: start, to: end) }
        let weights = try space.weights(
            at: SIMD2(scalars[space.xParameter] ?? 0, space.yParameter.flatMap { scalars[$0] } ?? 0))
        var result: ModelTransform?
        var total: Float = 0
        for i in space.samples.indices where weights[i] > 0 {
            guard let clip = clips[space.samples[i].clipID] else {
                throw AnimationRuntimeError.missingClipForState(state.id)
            }
            let delta = try clip.rootMotion(
                from: start / reference.duration * clip.duration, to: end / reference.duration * clip.duration)
            total += weights[i]
            result = result.map { $0.interpolated(to: delta, progress: weights[i] / total) } ?? delta
        }
        return result ?? .identity
    }

    private func sample(_ state: AnimationStateDefinition, at time: Float) throws -> SampledAnimationPose {
        guard time.isFinite else { throw modelingError("graph.timeOverflow", "Animation time must remain finite.") }
        guard let clip = clips[state.clipID] else { throw AnimationRuntimeError.missingClipForState(state.id) }
        func completed(_ clip: AnimationClipDefinition, _ time: Float) -> SampledAnimationPose {
            var result = clip.sample(at: time)
            for (target, value) in referenceScalars where result.scalarValues[target] == nil {
                result.scalarValues[target] = value
            }
            for (target, rest) in referencePose.transforms where result.transforms[target] == nil {
                result.transforms[target] = rest
            }
            if let target = clip.rootMotionTarget {
                result.transforms[target] =
                    clip.channels.first(where: { $0.target == target })?.sample(at: 0)
                    ?? referencePose.transforms[target]
            }
            return result
        }
        guard let space = state.blendSpace else { return completed(clip, time) }
        let weights = try space.weights(
            at: SIMD2(scalars[space.xParameter] ?? 0, space.yParameter.flatMap { scalars[$0] } ?? 0))
        var total: Float = 0
        var result: SampledAnimationPose?
        for i in space.samples.indices where weights[i] > 0 {
            guard let source = clips[space.samples[i].clipID] else {
                throw AnimationRuntimeError.missingClipForState(state.id)
            }
            let pose = completed(source, time / clip.duration * source.duration)
            total += weights[i]
            result = result.map { $0.blended(with: pose, progress: weights[i] / total) } ?? pose
        }
        return result ?? completed(clip, time)
    }

    private func applyLayers(to sample: SampledAnimationPose) throws -> SampledAnimationPose {
        var result = sample
        for layer in graph.layers {
            guard let clip = clips[layer.clipID] else { throw AnimationRuntimeError.missingClipForState(layer.id) }
            let weight = layerWeights[layer.id] ?? layer.weightParameter.flatMap { scalars[$0] } ?? layer.weight
            let time = totalTime * layer.speed
            guard time.isFinite else { throw modelingError("graph.timeOverflow", "Layer time must remain finite.") }
            let sampled = clip.sample(at: time)
            let base = PoseDefinition(id: sample.clipID, transforms: result.transforms)
            let overlay = PoseDefinition(id: layer.id, transforms: sampled.transforms)
            result.transforms = try base.blended(
                with: overlay, weight: min(max(weight, 0), 1), mask: layer.mask, mode: layer.mode,
                reference: layer.referencePose ?? referencePose
            ).transforms
            for (target, maskWeight) in layer.scalarWeights {
                guard let value = sampled.scalarValues[target] else { continue }
                let reference = referenceScalars[target] ?? 0
                let current = result.scalarValues[target] ?? reference
                let amount = min(max(weight, 0), 1) * maskWeight
                let blended =
                    layer.mode == .override
                    ? current + (value - current) * amount : current + (value - reference) * amount
                if case .material(_, .emissiveIntensity) = target {
                    result.scalarValues[target] = max(0, blended)
                } else {
                    result.scalarValues[target] = min(max(blended, 0), 1)
                }
            }
        }
        return result
    }

    private func state(for id: AnyRealitizerID) -> AnimationStateDefinition? {
        graph.states.first { $0.id == id }
    }

    private func conditionsPass(_ conditions: [AnimationCondition]) -> Bool {
        conditions.allSatisfy { condition in
            switch condition {
            case .always:
                true
            case .boolean(let id, let expected):
                booleans[id] == expected
            case .scalarGreaterThan(let id, let value):
                (scalars[id] ?? 0) > value
            case .scalarLessThan(let id, let value):
                (scalars[id] ?? 0) < value
            case .trigger(let id):
                triggers.contains(id)
            }
        }
    }

    private mutating func begin(_ definition: AnimationTransitionDefinition) throws {
        guard let sourceState = state(for: currentStateID),
            let sourceClip = clips[sourceState.clipID]
        else {
            throw AnimationRuntimeError.missingClipForState(currentStateID)
        }
        guard state(for: definition.destinationStateID) != nil else {
            throw AnimationRuntimeError.missingState(definition.destinationStateID)
        }

        for condition in definition.conditions {
            if case .trigger(let id) = condition {
                triggers.remove(id)
            }
        }
        let frozenPose = transition == nil ? nil : lastBasePose
        transition = ActiveTransition(
            sourceClip: sourceClip,
            sourceState: sourceState,
            sourceElapsedTime: elapsedTimeInState,
            sourceSpeed: sourceState.speed,
            elapsedTime: 0,
            duration: definition.duration,
            easing: definition.easing,
            interruptible: definition.interruptible,
            frozenPose: frozenPose
        )
        let phase = sourceClip.duration > 0 ? elapsedTimeInState / sourceClip.duration : 0
        currentStateID = definition.destinationStateID
        let destinationDuration = state(for: currentStateID).flatMap { clips[$0.clipID]?.duration } ?? 0
        elapsedTimeInState = definition.preserveNormalizedTime ? phase * destinationDuration : 0
    }
}

private struct ActiveTransition: Sendable {
    let sourceClip: AnimationClipDefinition
    let sourceState: AnimationStateDefinition
    var sourceElapsedTime: Float
    let sourceSpeed: Float
    var elapsedTime: Float
    let duration: Float
    let easing: TransformInterpolation
    let interruptible: Bool
    let frozenPose: SampledAnimationPose?
}

/// Failures detected while evaluating an animation graph.
public enum AnimationRuntimeError: Error, Equatable, Sendable {
    case invalidDeltaTime(Float)
    case missingState(AnyRealitizerID)
    case missingClipForState(AnyRealitizerID)
}
