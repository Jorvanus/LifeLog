# Project: LifeLog

## Overview
- **Product Bundle ID**: `com.aaronbaxter.LifeLog`
- **Platform**: iOS (`1,2` - iPhone & iPad)
- **Deployment Target**: iOS 27.0
- **Swift Version**: Swift 6.0 with Strict Concurrency set to `complete`
- **Marketing Version**: 1.22.0 (Build 48)

## Architecture & Code Conventions
- **UI Framework**: SwiftUI
- **Concurrency**: Adhere strictly to Swift 6 Concurrency standards (`async/await`, `@MainActor`, Sendable protocols). Avoid legacy completion handlers or unsafe thread operations.
- **Data Protection & Storage**: Default data protection uses `NSFileProtectionComplete`. Keep local storage (e.g., SQLite/SwiftData) background-compatible.
- **Entitlements**: HealthKit integration enabled (`com.apple.developer.healthkit`).
- **Asset Generation**: Asset catalog Swift symbol extensions are enabled (`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`). Rely on auto-generated image/color symbols rather than manual string names where possible.
- **Localization**: String Catalog symbol generation is enabled (`STRING_CATALOG_GENERATE_SYMBOLS`).

## Asset & Design Guidelines
- **App Icon**: Located in `AppIcon` asset catalog.
- **Visual Style**: Minimalist, clean line-art activity artwork with transparent/adaptive backgrounds supporting both Light and Dark modes.
- **Vector Assets**: Preserve vector data for vector icons (`.svg` or `.pdf`).

## Target & Test Structure
- `LifeLog`: Main iOS Application target
- `LifeLogTests`: Unit testing suite
- `LifeLogUITests`: UI testing suite

## Agent Workflow Instructions
1. Always respect strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) when generating or refactoring Swift code.
2. Ensure new UI views support previewing via modern `#Preview` blocks.
3. Keep project changes compatible with XcodeGen structure defined in `project.yml`.
