import Realitizer

/// Deterministic presentation settings used by the shared preview viewport.
public struct ModelPreviewConfiguration: Equatable, Sendable {
    public var backgroundColor: RGBAColor
    public var cameraYawRadians: Float
    public var cameraPitchRadians: Float
    public var distanceScale: Float
    public var selectedClipID: AnyRealitizerID?
    public var sampleTime: Float = 0
    public var selectedPoseID: AnyRealitizerID? = nil
    public var graphStateID: AnyRealitizerID? = nil
    public var graphScalars: [AnyRealitizerID: Float] = [:]
    public var graphBooleans: [AnyRealitizerID: Bool] = [:]
    public var constraintTargets: [AnyRealitizerID: RigConstraintTarget] = [:]

    public init(
        backgroundColor: RGBAColor = RGBAColor(red: 0.055, green: 0.065, blue: 0.085),
        cameraYawRadians: Float = 0.65,
        cameraPitchRadians: Float = -0.3,
        distanceScale: Float = 1.6,
        selectedClipID: AnyRealitizerID? = nil
    ) {
        self.backgroundColor = backgroundColor
        self.cameraYawRadians = cameraYawRadians
        self.cameraPitchRadians = cameraPitchRadians
        self.distanceScale = distanceScale
        self.selectedClipID = selectedClipID
    }
}

extension ModelPreviewConfiguration {
    /// Preview-only failures never invalidate the game asset itself.
    public func validate(for asset: ModelAssetDefinition) throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid {
                throw ModelValidationError(diagnostics: [
                    ModelDiagnostic(
                        severity: .error, code: "preview.configuration", path: "preview", message: message)
                ])
            }
        }
        try require(
            backgroundColor.isFinite
                && [
                    backgroundColor.red, backgroundColor.green, backgroundColor.blue, backgroundColor.alpha,
                ].allSatisfy { (0...1).contains($0) }
                && cameraYawRadians.isFinite && cameraPitchRadians.isFinite && distanceScale.isFinite
                && distanceScale > 0
                && sampleTime.isFinite && sampleTime >= 0,
            "Preview colors, camera and sample time must be valid.")
        try require(
            selectedClipID.map { id in asset.clips.contains { $0.id == id } } ?? true,
            "Selected clip does not exist.")
        try require(
            selectedPoseID.map { id in asset.poses.contains { $0.id == id } } ?? true,
            "Selected pose does not exist.")
        if let id = graphStateID {
            try require(
                asset.animationGraph?.states.contains { $0.id == id } == true,
                "Selected graph state does not exist.")
        }
        try require(
            [selectedClipID, selectedPoseID, graphStateID].compactMap { $0 }.count <= 1,
            "Select one clip, pose or graph state per deterministic sample.")
        try require(
            graphStateID != nil || (graphScalars.isEmpty && graphBooleans.isEmpty),
            "Graph parameters require a selected graph state.")
        let parameters = asset.animationGraph?.parameters ?? []
        for (id, value) in graphScalars {
            try require(
                value.isFinite
                    && parameters.contains { if case .scalar = $0.kind { $0.id == id } else { false } },
                "Scalar preview inputs must match declared parameters.")
        }
        for id in graphBooleans.keys {
            try require(
                parameters.contains { if case .boolean = $0.kind { $0.id == id } else { false } },
                "Boolean preview inputs must match declared parameters.")
        }
        for (id, target) in constraintTargets {
            guard let constraint = asset.rig?.constraints.first(where: { $0.id == id }) else {
                try require(false, "Constraint preview targets must reference a declared constraint.")
                continue
            }
            try target.validate(for: constraint)
        }
    }
}
