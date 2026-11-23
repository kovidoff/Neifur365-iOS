# Neifur 365 (iOS) — Project Guidelines

## Communication
- Always respond, explain decisions, and summarize results in **Russian**.
- Explain trade-offs in plain user-facing terms and keep architecture clean and compact.

## Design & Code Quality
- Follow **Apple iOS Human Interface Guidelines** and native **Liquid Glass** (iOS 26/27): use native `TabView`, `NavigationStack`, `.toolbar`, `.searchable`, `.sheet`, `.contextMenu`, `.refreshable`, and system materials instead of recreating Android Material UI chrome.
- Keep `Neifur 365`'s dark color identity (`Nf.ink`, `Nf.surface`, `Nf.surfaceHi`, `Nf.line`, `Nf.violet`, `Nf.mint`, `Nf.amber`, `NfType`) harmonized with native iOS chrome.
- Target **iOS 16.0+** with Swift 5.9+ and SwiftUI; build with Xcode 26 (`macos-26` runner) for native Liquid Glass support on iOS 26/27 while keeping `#available` guards for newer APIs.
- Project structure is generated from `project.yml` via **XcodeGen**; never commit `.xcodeproj` or signing certificates.
- Never read/expose certificates (`.p12`, `.mobileprovision`) or user credentials.
