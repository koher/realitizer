import simd

private func requireAnimation(_ condition: Bool, _ code: String, _ message: String) throws {
    if !condition { throw modelingError(code, message) }
}

extension AnimationClipDefinition {
    /// Validates a portable timeline. Asset validation additionally checks hierarchy references.
    public func validate() throws {
        try requireAnimation(duration.isFinite && duration > 0, "clip.invalidDuration", "Clip duration must be positive and finite.")
        try requireAnimation(Set(channels.map(\.target)).count == channels.count
            && Set(scalarChannels.map(\.target)).count == scalarChannels.count
            && Set(events.map(\.id)).count == events.count,
            "clip.duplicateChannel", "Channels and event IDs must be unique.")
        func times(_ values: [Float]) throws {
            try requireAnimation(!values.isEmpty && values.allSatisfy { $0.isFinite && (0...duration).contains($0) }
                && zip(values, values.dropFirst()).allSatisfy { $0 < $1 },
                "clip.keyframes", "Keyframe times must be nonempty, strictly increasing and within the clip.")
        }
        for channel in channels {
            try times(channel.keyframes.map(\.time))
            for key in channel.keyframes { try key.transform.validate() }
        }
        for channel in scalarChannels {
            try times(channel.keyframes.map(\.time))
            let allowsHDR: Bool
            if case .material(_, .emissiveIntensity) = channel.target { allowsHDR = true } else { allowsHDR = false }
            try requireAnimation(channel.keyframes.allSatisfy {
                $0.value.isFinite && $0.value >= 0 && (allowsHDR || $0.value <= 1)
            }, "clip.scalarKeyframe", "Scalar values must be within the target's range.")
        }
        try requireAnimation(events.allSatisfy { $0.time.isFinite && (0...duration).contains($0.time) },
            "clip.invalidEventTime", "Event times must be within the clip.")
        if let rootMotionTarget {
            try requireAnimation(channels.contains { $0.target == rootMotionTarget },
                "clip.rootChannel", "Root motion requires a transform channel.")
        }
    }
}

extension ModelTransform {
    public func validate() throws {
        try requireAnimation(isFinite && abs(simd_length(rotation.vector) - 1) < 0.001
            && (0..<3).allSatisfy { abs(scale[$0]) > 1e-7 },
            "transform.invalid", "Transforms require finite, nonzero scales and unit quaternions.")
    }
}

extension AnimationGraphDefinition {
    /// Validates standalone graph inputs. Asset validation also checks model-specific targets.
    public func validate(clips: [AnimationClipDefinition]) throws {
        for clip in clips { try clip.validate() }
        let clipIDs = Set(clips.map(\.id))
        let stateIDs = Set(states.map(\.id))
        try requireAnimation(clipIDs.count == clips.count && stateIDs.count == states.count
            && Set(parameters.map(\.id)).count == parameters.count && stateIDs.contains(initialStateID),
            "graph.definition", "Graph IDs must be unique and the initial state must exist.")
        let kinds = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.kind) })
        func scalar(_ id: AnyRealitizerID) -> Bool { if case .scalar? = kinds[id] { true } else { false } }
        for parameter in parameters {
            if case .scalar(let value) = parameter.kind {
                try requireAnimation(value.isFinite, "graph.scalarDefault", "Scalar defaults must be finite.")
            }
        }
        for state in states {
            try requireAnimation(clipIDs.contains(state.clipID) && state.speed.isFinite && state.speed >= 0,
                "graph.state", "States require an existing clip and a finite nonnegative speed.")
            if let space = state.blendSpace {
                _ = try space.weights(at: .zero)
                try requireAnimation(scalar(space.xParameter) && (space.yParameter.map(scalar) ?? true)
                    && space.samples.allSatisfy { clipIDs.contains($0.clipID) },
                    "graph.blendSpace", "Blend spaces require scalar parameters and existing clips.")
            }
        }
        for transition in transitions {
            try requireAnimation(stateIDs.contains(transition.sourceStateID) && stateIDs.contains(transition.destinationStateID)
                && transition.duration.isFinite && transition.duration >= 0 && !transition.conditions.isEmpty,
                "graph.transition", "Transitions require existing states, conditions and a finite nonnegative duration.")
            for condition in transition.conditions {
                let valid: Bool
                switch condition {
                case .always: valid = true
                case .boolean(let id, _): if case .boolean? = kinds[id] { valid = true } else { valid = false }
                case .trigger(let id): valid = kinds[id] == .trigger
                case .scalarGreaterThan(let id, let threshold), .scalarLessThan(let id, let threshold):
                    valid = scalar(id) && threshold.isFinite
                }
                try requireAnimation(valid, "graph.parameterTypeMismatch", "Conditions must match declared parameter types and finite thresholds.")
            }
        }
        try requireAnimation(Set(layers.map(\.id)).count == layers.count, "graph.layer", "Layer IDs must be unique.")
        for layer in layers {
            try requireAnimation(clipIDs.contains(layer.clipID) && layer.weight.isFinite && (0...1).contains(layer.weight)
                && layer.speed.isFinite && layer.speed >= 0 && (layer.weightParameter.map(scalar) ?? true)
                && layer.mask.weights.values.allSatisfy { $0.isFinite && (0...1).contains($0) }
                && layer.scalarWeights.values.allSatisfy { $0.isFinite && (0...1).contains($0) },
                "graph.layer", "Layers require existing clips, valid weights, speeds and scalar parameters.")
            for transform in layer.referencePose?.transforms.values ?? [:].values { try transform.validate() }
        }
    }
}
