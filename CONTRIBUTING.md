# Maintenance Policy

Realitizer is maintained exclusively by its maintainer. Issues, pull requests and other external contributions, including feature requests and unsolicited patches, are not accepted.

If you need changes or fixes, please fork the repository and maintain your own version.

This maintenance policy does not restrict the rights granted by the MIT License. You may use, modify and distribute your own fork under that license; this repository is not obligated to merge or support it.

## Maintainer workflow

Use Swift 6.3 or newer and the required Apple SDKs. Make focused changes, add regression coverage, run `swift build`, `swift test` and `git diff --check`, and update the relevant API documentation. All repository files, diagnostics and commit messages must be written in English.
