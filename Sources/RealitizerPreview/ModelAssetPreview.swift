import Observation
import Realitizer
import RealitizerRealityKit
import RealityKit
import SwiftUI

/// Code-controlled framing and diagnostics. There is deliberately no parameter editor.
public struct ModelAssetPreviewOptions: Equatable, Sendable {
    public var configuration: ModelPreviewConfiguration
    public var camera: PreviewCamera
    public var display: PreviewDebugMode
    public var levelOfDetail: Int
    public var selectedJointID: AnyRealitizerID?
    public var lightIntensity: Float
    public var showsDiagnostics: Bool

    public init(
        configuration: ModelPreviewConfiguration = ModelPreviewConfiguration(),
        camera: PreviewCamera = .perspective, display: PreviewDebugMode = .shaded,
        levelOfDetail: Int = 0, selectedJointID: AnyRealitizerID? = nil,
        lightIntensity: Float = 3500, showsDiagnostics: Bool = true
    ) {
        self.configuration = configuration
        self.camera = camera
        self.display = display
        self.levelOfDetail = levelOfDetail
        self.selectedJointID = selectedJointID
        self.lightIntensity = lightIntensity
        self.showsDiagnostics = showsDiagnostics
    }

    public func validate(for asset: ModelAssetDefinition) throws {
        try configuration.validate(for: asset)
        guard levelOfDetail >= 0, lightIntensity.isFinite, lightIntensity >= 0,
            selectedJointID.map({ id in asset.rig?.joints.contains { $0.id == id } == true }) ?? true
        else {
            throw ModelValidationError(diagnostics: [
                ModelDiagnostic(
                    severity: .error, code: "preview.options", path: "preview",
                    message: "LOD and lighting must be nonnegative and the selected joint must exist.")
            ])
        }
    }
}

public enum PreviewCamera: String, Equatable, Sendable {
    case perspective, front, back, side, top, orthographic
}

/// Edit Swift inputs, then use RenderPreview to inspect one deterministic sample.
/// Input and option changes reset the viewport. Increment revision if only the
/// generator closure or a prebuilt asset's contents change at the same View identity.
@MainActor
public struct ModelAssetPreview<Parameters: Sendable & Equatable>: View {
    private let generator: ModelAssetGenerator<Parameters>
    private let input: AssetGenerationInput<Parameters>
    private let options: ModelAssetPreviewOptions
    private let revision: Int

    public init(
        generator: ModelAssetGenerator<Parameters>, input: AssetGenerationInput<Parameters>? = nil,
        options: ModelAssetPreviewOptions = ModelAssetPreviewOptions(), revision: Int = 0
    ) {
        self.generator = generator
        self.input = input ?? generator.defaultInput
        self.options = options
        self.revision = revision
    }

    public var body: some View {
        PreviewSession(generator: generator, input: input, options: options)
            .id(
                PreviewIdentity(
                    name: generator.name, version: generator.version, input: input,
                    options: options, revision: revision))
    }
}

extension ModelAssetPreview where Parameters == NoAssetParameters {
    public init(
        asset: ModelAssetDefinition, options: ModelAssetPreviewOptions = ModelAssetPreviewOptions(),
        revision: Int = 0
    ) {
        self.init(
            generator: ModelAssetGenerator(name: asset.name) { _ in asset }, options: options,
            revision: revision)
    }
}

struct PreviewIdentity<Parameters: Sendable & Equatable>: Hashable {
    let name: String
    let version: Int
    let input: AssetGenerationInput<Parameters>
    let options: ModelAssetPreviewOptions
    let revision: Int
    // Equality compares all inputs; a small hash avoids requiring Hashable on user parameters.
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(revision)
    }
}

@MainActor
private struct PreviewSession<Parameters: Sendable & Equatable>: View {
    @State private var model: ModelAssetPreviewModel<Parameters>
    init(
        generator: ModelAssetGenerator<Parameters>, input: AssetGenerationInput<Parameters>,
        options: ModelAssetPreviewOptions
    ) {
        _model = State(
            initialValue: ModelAssetPreviewModel(generator: generator, input: input, options: options))
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.options.showsDiagnostics {
                PreviewHeader(
                    name: model.generator.name, status: model.status, statistics: model.statistics)
            }
            ModelAssetViewport(model: model)
                .frame(minWidth: 200, minHeight: 240)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor @Observable
final class ModelAssetPreviewModel<Parameters: Sendable & Equatable> {
    let generator: ModelAssetGenerator<Parameters>
    let input: AssetGenerationInput<Parameters>
    let options: ModelAssetPreviewOptions
    private(set) var status = "Compiling"
    private(set) var diagnostic = ""
    private(set) var statistics: ModelStatistics?
    @ObservationIgnored private(set) var instance: RuntimeModelInstance?
    @ObservationIgnored private(set) var asset: ModelAssetDefinition?
    @ObservationIgnored let sceneRoot = Entity()
    @ObservationIgnored let overlay = Entity()
    @ObservationIgnored var cameraEntity: Entity = PerspectiveCamera()
    @ObservationIgnored private let key = Entity()
    @ObservationIgnored private let fill = Entity()
    @ObservationIgnored private var generation = 0

    init(
        generator: ModelAssetGenerator<Parameters>, input: AssetGenerationInput<Parameters>? = nil,
        options: ModelAssetPreviewOptions = ModelAssetPreviewOptions()
    ) {
        self.generator = generator
        self.input = input ?? generator.defaultInput
        self.options = options
    }

    var background: Color {
        let c = options.configuration.backgroundColor
        return Color(
            .sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue),
            opacity: Double(c.alpha))
    }

    func install<Content: RealityViewContentProtocol>(in content: inout Content) async {
        if let camera = content.entities.first(where: {
            $0.components[PerspectiveCameraComponent.self] != nil
        }) {
            cameraEntity = camera
        }
        await regenerate()
        content.add(sceneRoot)
        if !content.entities.contains(where: { $0 === cameraEntity }) { content.add(cameraEntity) }
        content.add(key)
        content.add(fill)
    }

    func regenerate(detached: Bool = true) async {
        generation += 1
        let request = generation
        status = "Compiling"
        diagnostic = ""
        let generator = generator
        let input = input
        do {
            let value: ModelAssetDefinition
            if detached {
                value = try await Task.detached(priority: .userInitiated) { try generator.generate(input) }
                    .value
            } else {
                value = try generator.generate(input)
            }
            guard request == generation, !Task.isCancelled else { return }
            try options.validate(for: value)
            let created = try RealityKitModelCompiler.compile(value).instantiate()
            try created.setLevelOfDetail(options.levelOfDetail)
            let config = options.configuration
            let clip = value.clips.first { $0.id == config.selectedClipID }
            if let state = config.graphStateID {
                let animator = try created.makeAnimator()
                for (id, scalar) in config.graphScalars { try animator.set(scalar, for: id) }
                for (id, boolean) in config.graphBooleans { try animator.set(boolean, for: id) }
                for (id, target) in config.constraintTargets {
                    try animator.setConstraintTarget(id, to: target)
                }
                _ = try animator.seek(state: state, time: config.sampleTime)
            } else {
                if let clip { try created.sample(clip.id, at: config.sampleTime) }
                if let pose = value.poses.first(where: { $0.id == config.selectedPoseID }) {
                    try created.apply(pose)
                }
                if let rig = value.rig, !config.constraintTargets.isEmpty {
                    let solved = try RigSolver.solve(
                        rig: rig, pose: created.currentPose, targets: config.constraintTargets)
                    try created.apply(solved.pose)
                }
            }
            let preparedOverlay = Entity()
            try PreviewDiagnostics.update(
                mode: options.display, instance: created, overlay: preparedOverlay,
                selectedJoint: options.selectedJointID, clip: clip)
            instance?.root.removeFromParent()
            overlay.children.removeAll()
            for child in Array(preparedOverlay.children) { overlay.addChild(child) }
            if overlay.parent == nil { sceneRoot.addChild(overlay) }
            sceneRoot.addChild(created.root)
            asset = value
            instance = created
            statistics = created.statistics
            updateCamera()
            key.look(at: .zero, from: [2.5, 4, 3], relativeTo: nil)
            fill.look(at: .zero, from: [-3, 1.5, -2], relativeTo: nil)
            key.components.set(
                DirectionalLightComponent(color: .white, intensity: options.lightIntensity))
            fill.components.set(
                DirectionalLightComponent(color: .white, intensity: options.lightIntensity * 0.4))
            status = "Ready"
        } catch {
            guard request == generation else { return }
            status = "Failed"
            diagnostic = String(describing: error)
        }
    }

    func updateCamera() {
        guard let asset else { return }
        let bounds = asset.bounds
        let center = bounds?.center ?? .zero
        let extent = bounds.map { max($0.size.x, $0.size.y, $0.size.z) } ?? 1
        let config = options.configuration
        let distance = max(extent * config.distanceScale, 0.1)
        let yaw = config.cameraYawRadians
        let pitch = min(max(config.cameraPitchRadians, -1.5), 1.5)
        let direction: SIMD3<Float>
        switch options.camera {
        case .front: direction = [0, 0, 1]
        case .back: direction = [0, 0, -1]
        case .side: direction = [1, 0, 0]
        case .top: direction = [0, 1, 0.0001]
        case .perspective, .orthographic:
            direction = [sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)]
        }
        cameraEntity.look(at: center, from: center + direction * distance, relativeTo: nil)
        if options.camera == .perspective {
            cameraEntity.components.set(PerspectiveCameraComponent())
            cameraEntity.components.remove(OrthographicCameraComponent.self)
        } else {
            var component = OrthographicCameraComponent()
            component.scale = max(extent * config.distanceScale, 0.1)
            cameraEntity.components.set(component)
            cameraEntity.components.remove(PerspectiveCameraComponent.self)
        }
    }
}

@MainActor
private struct ModelAssetViewport<Parameters: Sendable & Equatable>: View {
    let model: ModelAssetPreviewModel<Parameters>
    var body: some View {
        RealityView { content in
            content.camera = .virtual
            await model.install(in: &content)
        }
        .background(model.background)
        .overlay(alignment: .bottomLeading) {
            if !model.diagnostic.isEmpty {
                ScrollView {
                    Text(verbatim: model.diagnostic).font(.caption.monospaced())
                        .foregroundStyle(.red).textSelection(.enabled).padding(12)
                }
                .frame(maxHeight: 140).background(.regularMaterial)
            }
        }
    }
}

private struct PreviewHeader: View {
    let name: String
    let status: String
    let statistics: ModelStatistics?
    var body: some View {
        HStack {
            Text(verbatim: name).font(.headline)
            Spacer()
            if let statistics {
                Text(verbatim: "\(statistics.vertices) vertices / \(statistics.triangles) triangles")
                    .font(.caption.monospacedDigit())
            }
            Text(verbatim: status).font(.caption.weight(.semibold))
                .foregroundStyle(status == "Failed" ? .red : .green)
        }.padding(12).background(.regularMaterial)
    }
}
