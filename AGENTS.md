# Neifur 365 (iOS) — Project Guidelines

## Communication
- Always respond, explain decisions, and summarize results in **Russian**.
- Explain trade-offs in plain user-facing terms and keep architecture clean and compact.

## Design & Code Quality
- Match `Neifur 365`'s dark aesthetic (`Nf.ink`, `Nf.surface`, `Nf.surfaceHi`, `Nf.line`, `Nf.violet`, `Nf.mint`, `Nf.amber`, `NfType`, `NfPressableStyle`).
- Target **iOS 16.0+** with Swift 5.9+ and SwiftUI; avoid iOS 17+ only APIs without `#available` guards.
- Project structure is generated from `project.yml` via **XcodeGen**; never commit `.xcodeproj` or signing certificates.
- Never read/expose certificates (`.p12`, `.mobileprovision`) or user credentials.
