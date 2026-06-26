---
name: MyWispr Release Automator
description: Automates building, packaging, ad-hoc signing, tagging, and uploading new DMG releases to GitHub for the MyWispr project.
---

# MyWispr Release Automator

This skill provides a fully automated script to compile and release a new version of the MyWispr application to GitHub.

## How to Trigger

When the user asks to "build and release", "publish a new version", "bump version and push DMG", or similar commands:
1. Identify the version number to release (e.g. `0.4.5`).
2. Run the automated script `.agents/skills/build-release/scripts/release.sh`.

## Usage

Run the script from the repository root:
```bash
./.agents/skills/build-release/scripts/release.sh <version_number>
```

Example:
```bash
./.agents/skills/build-release/scripts/release.sh 0.4.5
```

## Actions Executed by the Script

The script automates the following steps:
1. **Version Bump**: Reads `Sources/MyWispr/Resources/Info.plist`, increments the build version (`CFBundleVersion`), and updates the version string (`CFBundleShortVersionString`).
2. **README Bump**: Automatically updates `README.md` download links, badges, and prepends a release entry to the Changelog.
3. **Commit & Push**: Commits and pushes the version updates to `main`.
4. **Compile**: Compiles the project in release mode (`swift build -c release`).
5. **Bundle**: Packages the compiled binary, `Info.plist`, and `MyWispr.icns` into a `.app` bundle structure.
6. **Codesign**: Signs the bundle with an ad-hoc local signature (`codesign --force --deep --sign - MyWispr.app`) to prevent macOS Gatekeeper from displaying the "damaged" warning.
7. **Package DMG**: Compresses the app bundle into a `.dmg` file (`MyWispr-<version>.dmg`) using `hdiutil`.
8. **Git Tag**: Creates a Git tag `v<version>` and pushes it to the remote repository.
9. **GitHub Release & Upload**: Uses the local Git credential helper to fetch credentials, creates or finds the GitHub Release for the tag, deletes any pre-existing asset of the same name, and uploads the new `.dmg` file as a release asset.
