# macOS Menu Bar Speech-to-Text App

## Summary
Build a macOS-only menu bar app with a settings window. The app records microphone audio when the user triggers a configurable shortcut, sends audio to a selectable transcription adapter, then inserts the resulting text into the active app. The default adapter is Codex CLI-backed, with support for an advanced custom-command option.

## Key Changes
- App shell
  - Native macOS menu bar app with a lightweight settings window.
  - Background-resident interaction model with manual controls in the menu bar.
- Settings model
  - Persisted activation shortcut.
  - Recording mode selection for `toggle` and `hold-to-talk`.
  - Transcription engine selection and engine-specific command configuration.
- Recording and transcription flow
  - Microphone capture to a temporary audio file.
  - Adapter-driven transcription command execution with Codex CLI as the default engine.
  - Text insertion into the active app with clipboard fallback.
- Public interfaces/types
  - Stable settings schema for shortcut, mode, engine, and command templates.
  - Adapter-style transcription service contract.

## Test Plan
- Record and reload settings across app restarts.
- Verify toggle and hold-to-talk shortcut behavior.
- Validate transcript command execution and error handling.
- Insert transcribed text into another macOS app, then fall back to clipboard when needed.

## Assumptions and Defaults
- v1 targets macOS only.
- Codex CLI is configured as a command template that can be adjusted in settings.
- Accessibility permission may be required for direct typing and paste automation.
