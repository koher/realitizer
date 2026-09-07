import Foundation

/// A semantic transform target animated by a pose or clip.
public enum AnimationTarget: Hashable, Sendable {
    case part(AnyRealitizerID)
    case joint(AnyRealitizerID)

    public static func part<ID: RealitizerID>(id: ID) -> Self {
        .part(id.erasedID)
    }

    public static func joint<ID: RealitizerID>(id: ID) -> Self {
        .joint(id.erasedID)
    }

    public var id: AnyRealitizerID {
        switch self {
        case .part(let id), .joint(let id):
            id
        }
    }
}

/// A reusable collection of local transforms.
public struct PoseDefinition: Sendable {
    public let id: AnyRealitizerID
    public var transforms: [AnimationTarget: ModelTransform]

    public init<ID: RealitizerID>(
        id: ID,
        transforms: [AnimationTarget: ModelTransform]
    ) {
        self.id = id.erasedID
        self.transforms = transforms
    }
}

/// The interpolation rule used between transform keyframes.
public enum TransformInterpolation: String, Sendable {
    case step
    case linear
    case smoothStep
}

/// One local transform sample in a channel.
public struct TransformKeyframe: Equatable, Sendable {
    public var time: Float
    public var transform: ModelTransform

    public init(time: Float, transform: ModelTransform) {
        self.time = time
        self.transform = transform
    }
}

/// A transform timeline for one semantic target.
public struct TransformAnimationChannel: Sendable {
    public var target: AnimationTarget
    public var keyframes: [TransformKeyframe]
    public var interpolation: TransformInterpolation

    public init(
        target: AnimationTarget,
        keyframes: [TransformKeyframe],
        interpolation: TransformInterpolation = .linear
    ) {
        self.target = target
        self.keyframes = keyframes
        self.interpolation = interpolation
    }

    public func sample(at time: Float) -> ModelTransform? {
        guard let first = keyframes.first else {
            return nil
        }
        guard time > first.time else {
            return first.transform
        }
        guard let last = keyframes.last, time < last.time else {
            return keyframes.last?.transform
        }

        for index in 1..<keyframes.count {
            let right = keyframes[index]
            guard time <= right.time else {
                continue
            }
            let left = keyframes[index - 1]
            let span = right.time - left.time
            guard span > 0 else {
                return right.transform
            }
            var progress = (time - left.time) / span
            switch interpolation {
            case .step:
                progress = 0
            case .linear:
                break
            case .smoothStep:
                progress = progress * progress * (3 - 2 * progress)
            }
            return left.transform.interpolated(to: right.transform, progress: progress)
        }
        return last.transform
    }
}

/// How elapsed time maps into a clip timeline.
public enum AnimationLoopMode: String, Sendable {
    case once
    case loop
}

/// A semantic event emitted at a specific clip time.
public struct AnimationEventDefinition: Sendable {
    public let id: AnyRealitizerID
    public var time: Float
    public var payload: String?

    public init<ID: RealitizerID>(id: ID, time: Float, payload: String? = nil) {
        self.id = id.erasedID
        self.time = time
        self.payload = payload
    }
}

/// One event occurrence reported while advancing a clip.
public struct AnimationEventOccurrence: Equatable, Sendable {
    public let eventID: AnyRealitizerID
    public let clipID: AnyRealitizerID
    public let elapsedTime: Float
    public let payload: String?

    public init(
        eventID: AnyRealitizerID,
        clipID: AnyRealitizerID,
        elapsedTime: Float,
        payload: String?
    ) {
        self.eventID = eventID
        self.clipID = clipID
        self.elapsedTime = elapsedTime
        self.payload = payload
    }
}

/// A deterministic transform animation with semantic events.
public struct AnimationClipDefinition: Sendable {
    public let id: AnyRealitizerID
    public var duration: Float
    public var loopMode: AnimationLoopMode
    public var channels: [TransformAnimationChannel]
    public var events: [AnimationEventDefinition]
    public var rigSignature: RigSignature? = nil
    public var scalarChannels: [ScalarAnimationChannel] = []
    public var rootMotionTarget: AnimationTarget? = nil

    public init<ID: RealitizerID>(
        id: ID,
        duration: Float,
        loopMode: AnimationLoopMode = .once,
        channels: [TransformAnimationChannel],
        events: [AnimationEventDefinition] = []
    ) {
        self.id = id.erasedID
        self.duration = duration
        self.loopMode = loopMode
        self.channels = channels
        self.events = events
    }

    public func localTime(for elapsedTime: Float) -> Float {
        guard duration > 0, elapsedTime.isFinite else {
            return 0
        }
        switch loopMode {
        case .once:
            return min(max(elapsedTime, 0), duration)
        case .loop:
            let positiveTime = max(elapsedTime, 0)
            let remainder = positiveTime.truncatingRemainder(dividingBy: duration)
            return positiveTime > 0 && remainder == 0 ? duration : remainder
        }
    }

    public func sample(at elapsedTime: Float) -> SampledAnimationPose {
        let time = localTime(for: elapsedTime)
        var transforms: [AnimationTarget: ModelTransform] = [:]
        for channel in channels {
            if let transform = channel.sample(at: time) {
                transforms[channel.target] = transform
            }
        }
        var result = SampledAnimationPose(
            clipID: id,
            localTime: time,
            transforms: transforms
        )
        for channel in scalarChannels { result.scalarValues[channel.target] = channel.sample(at: time) }
        return result
    }

    public func events(
        from previousElapsedTime: Float,
        to elapsedTime: Float,
        maximumOccurrences: Int = 10_000
    ) throws -> [AnimationEventOccurrence] {
        guard duration.isFinite, duration > 0, maximumOccurrences >= 0 else {
            throw modelingError(
                "animation.eventDomain",
                "Event queries require a positive finite duration and a nonnegative occurrence budget.")
        }
        guard duration > 0,
            previousElapsedTime.isFinite,
            elapsedTime.isFinite,
            elapsedTime != previousElapsedTime
        else {
            return []
        }

        if elapsedTime < previousElapsedTime {
            // Reverse uses [end, start), the mirror of forward's (start, end].
            return try events(
                from: elapsedTime.nextDown, to: previousElapsedTime.nextDown, maximumOccurrences: maximumOccurrences
            ).reversed()
        }

        let sortedEvents = events.sorted {
            $0.time == $1.time ? $0.id.rawValue < $1.id.rawValue : $0.time < $1.time
        }
        switch loopMode {
        case .once:
            let end = min(elapsedTime, duration)
            let occurrences = sortedEvents.compactMap { event -> AnimationEventOccurrence? in
                guard event.time > previousElapsedTime, event.time <= end else {
                    return nil
                }
                return occurrence(for: event, elapsedTime: event.time)
            }
            guard occurrences.count <= maximumOccurrences else {
                throw modelingError("animation.eventBudget", "Event query exceeds its occurrence budget.")
            }
            return occurrences
        case .loop:
            if sortedEvents.isEmpty { return [] }
            guard max(abs(previousElapsedTime), abs(elapsedTime)) / duration < Float(Int32.max) else {
                throw modelingError("animation.eventTime", "Event times exceed the supported cycle range.")
            }
            let startCycle = max(Int(floor(previousElapsedTime / duration)), 0)
            let endCycle = max(Int(floor(elapsedTime / duration)), 0)
            guard endCycle - startCycle <= maximumOccurrences / sortedEvents.count + 1 else {
                throw modelingError("animation.eventBudget", "Event query exceeds its occurrence budget.")
            }
            let occurrences = (startCycle...endCycle).flatMap { cycle -> [AnimationEventOccurrence] in
                sortedEvents.compactMap { event -> AnimationEventOccurrence? in
                    let absoluteTime = Float(cycle) * duration + event.time
                    guard absoluteTime > previousElapsedTime, absoluteTime <= elapsedTime else {
                        return nil
                    }
                    return occurrence(for: event, elapsedTime: absoluteTime)
                }
            }
            guard occurrences.count <= maximumOccurrences else {
                throw modelingError("animation.eventBudget", "Event query exceeds its occurrence budget.")
            }
            return occurrences
        }
    }

    private func occurrence(
        for event: AnimationEventDefinition,
        elapsedTime: Float
    ) -> AnimationEventOccurrence {
        AnimationEventOccurrence(
            eventID: event.id,
            clipID: id,
            elapsedTime: elapsedTime,
            payload: event.payload
        )
    }
}

/// The sampled transforms produced by an animation clip.
public struct SampledAnimationPose: Sendable {
    public let clipID: AnyRealitizerID
    public let localTime: Float
    public var transforms: [AnimationTarget: ModelTransform]
    public var scalarValues: [ScalarAnimationTarget: Float] = [:]

    public init(
        clipID: AnyRealitizerID,
        localTime: Float,
        transforms: [AnimationTarget: ModelTransform]
    ) {
        self.clipID = clipID
        self.localTime = localTime
        self.transforms = transforms
    }

    public func blended(with other: Self, progress: Float) -> Self {
        let amount = min(max(progress, 0), 1)
        let targets = Set(transforms.keys).union(other.transforms.keys)
        var result: [AnimationTarget: ModelTransform] = [:]
        for target in targets {
            switch (transforms[target], other.transforms[target]) {
            case (let left?, let right?):
                result[target] = left.interpolated(to: right, progress: amount)
            case (let left?, nil):
                result[target] = left
            case (nil, let right?):
                result[target] = right
            case (nil, nil):
                break
            }
        }
        var pose = Self(clipID: other.clipID, localTime: other.localTime, transforms: result)
        for target in Set(scalarValues.keys).union(other.scalarValues.keys) {
            let a = scalarValues[target] ?? 0
            let b = other.scalarValues[target] ?? 0
            pose.scalarValues[target] = a + (b - a) * amount
        }
        return pose
    }
}
