# Realitizer Development Guide

Realitizer is a code-first 3D modeling and animation library for RealityKit.

## Language

- Write every repository file in English, including documentation, source comments, diagnostics, test names, and examples.
- Write every commit message in English.
- Use ASCII names for files and directories.
- Review changed files and commit messages to ensure they contain only English repository content.

## Architecture

- `Realitizer` contains RealityKit-independent geometry, asset, rig, animation, validation, and diagnostic types.
- `RealitizerRealityKit` compiles definitions into RealityKit resources and exposes runtime handles.
- `RealitizerEnvironment` contains optional portable grass and wave definitions.
- `RealitizerEnvironmentRealityKit` contains optional environment renderers and shader preparation.
- Preview has no parameter editor; agents edit Swift inputs and use RenderPreview.
- `RealitizerPreview` provides the shared SwiftUI and RealityView authoring viewport.
- Keep game-specific art direction, gameplay state, and assets outside this repository.
- Keep documentation focused on current API usage and contracts; do not add pre-release migration guides or development backlogs.
- Keep public definitions deterministic and `Sendable` where their stored values allow it.
- Treat semantic identifiers as stable public contracts. Rendering optimization must not erase them.

## SwiftUI

- Keep `View` initializers cheap.
- Store shared mutable preview state in a `@MainActor @Observable` model.
- Split distinct viewport and status regions into separate `View` types with narrow inputs.
- Keep `@State` private.

## Verification

Run these commands before committing:

```sh
swift build
swift test
git diff --check
```

## Commits

- Use concise English imperative commit messages.
- Do not commit build products.
- Update tests and README examples when a public API changes.
