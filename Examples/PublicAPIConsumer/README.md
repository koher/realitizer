# Public API consumer

This separate Swift package depends on the repository through its public products. It does not use `@testable` imports. `VesselParameters` belongs to the consumer, and its preview has no editing controls: change the Swift inputs, then render the `#Preview` again.

`makeFinishedProp()` demonstrates a complete surface pipeline: select edges, apply a constant-width segmented bevel, finish normals, unwrap/pack UVs, and generate vertex colors with a checker texture. `makeHollowCylinder()` demonstrates subtraction; `makeArticulatedColumn()` demonstrates binding a modeled shape. Generate these definitions during asset loading, not in a frame loop. Vertex-colored rendering uses the Xcode-built `ModelRenderingResources` bundle, or an explicitly injected target-compatible library in a non-Xcode host.

Run portable and macOS runtime coverage with:

```sh
swift build
swift test
```

Run the bundled Metal integration test with Xcode and an installed iPhone 17e simulator:

```sh
xcodebuild test -scheme RealitizerConsumer -destination 'platform=iOS Simulator,name=iPhone 17e'
```

The iOS-only tests load the actual compiled resource bundles, instantiate the vertex-colored prop, construct grass and water, and check a completed wave update. A successful build alone does not prove these tests executed. If Xcode reports that it cannot create the test bundle instance before starting tests, treat the integration check as unverified; do not replace it with a source-compiled shader fallback.

For Preview, the selected Xcode scheme must contain the source's target and the `RealitizerPreview` product. An application that depends only on the runtime products cannot render the library's preview demo through its application scheme.
