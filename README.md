# ColorMatching-macOS

A native macOS app for composing **illumination-dependent images**: given a few grayscale source images and a palette of printable colors with measured brightness under different lighting conditions, it generates a single color image optimized so that each source is reproduced as closely as possible under its assigned light.

The classic use case: print one image that, viewed under red light, shows the red-channel picture; under green light, the green picture; under low-pressure sodium, yet another — all from a single print using a finite palette of inks.

## How it works

- Each **palette color** has a measured *response vector*: its apparent brightness under each illuminant (red, green, blue, LPS, optionally white).
- Each **source image** represents the desired brightness under one lighting condition.
- At each output cell, the solver builds a target vector from the source pixels and picks the palette color whose measured response best matches it — using **weighted squared error**.

This mirrors the algorithm in the [`color_matching`](https://github.com/viamin/color_matching) backend (`WeightedSquaredError`), so client and server agree on selection. A color missing a measurement for any active channel is **excluded**, never treated as zero brightness.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — installed automatically by `bin/setup` via Homebrew
- A running `color_matching` server for palette data (defaults to `http://localhost:4000`)

## Setup

```bash
git clone https://github.com/viamin/ColorMatching-macOS.git
cd ColorMatching-macOS
bin/setup        # installs xcodegen if needed, generates ColorMatching.xcodeproj
open ColorMatching.xcodeproj
```

Then ⌘R to run, or build from the command line:

```bash
xcodebuild -project ColorMatching.xcodeproj -scheme ColorMatching -configuration Debug build
```

## Workflow

1. **Server** (sidebar) — set the `color_matching` base URL (persisted), Test, then Refresh to load printer profiles.
2. **Palette** — choose a printer profile; the app fetches every color with its measured illuminant responses. Each fetch is cached to disk per server and profile: when the server is unreachable the cached colors load instead and are badged as offline-stale (with their fetch date), the profile picker falls back to cached profiles when the server can't be reached at all, and **Clear Cache** discards them.
3. **Source images** — add up to 4 images (PNG/JPEG/TIFF/HEIC), assign each to Red / Green / Blue / LPS. Per image: invert, and Fit / Fill / Stretch mapping.
4. **Composition** — set the logical resolution (e.g. 200×200), export pixels-per-cell, physical print size, and per-channel weights.
5. **Generate** — solve, then explore:
   - **Composite** — the printable color image (exact palette RGBs; export/print use this). Toggle **Soft Proof** for a printer-profile preview derived from the selected profile's paper/ink metadata: warmed paper white, lifted blacks, compressed saturation, and an orange wash on out-of-gamut cells.
   - **Error map** — where the palette can't represent the targets well.
   - **Gamut** — parallel-coordinates plot of the loaded colors' response vectors against the target vectors the source images ask for, highlighting targets no color can reach and naming the channel that runs out.
   - **Preview · Red / Green / Blue / LPS / White** — predicted appearance under each light, tinted by channel color.
   - **Statistics** — mean / median / max error, and % of cells below a quality threshold.
6. **Export** PNG/TIFF, **Print** via the native macOS print dialog at a controlled physical size, or **Save Project** (`.cmpj`) with embedded images + palette snapshot.

## Architecture

```
ColorComposerCore/        Pure-Swift package (no UI): solver, models, imaging, API client, renderers
ColorMatching/            SwiftUI macOS app shell
project.yml               xcodegen spec — the source of truth for the Xcode project
bin/setup                 generates the Xcode project
```

- **`ColorComposerCore`** is a standalone Swift Package with no AppKit/SwiftUI dependency, so the solver and imaging logic are unit-testable in isolation (`swift test`). It contains:
  - `CompositionScorer` protocol + `WeightedSquaredErrorScorer` (the v1 default; pluggable for future dithering / diffusion / alternative metrics)
  - `CompositionSolver` — nearest-neighbor with an optimized contiguous fast path, deterministic earliest-wins tie-breaking, parallelized across rows (~25ms for 500×500 × 256 colors in release)
  - `BrightnessGridSampler` — Core Graphics grayscale sampling with Fit/Fill/Stretch + inversion
  - `CompositionRenderer` — composite, error map, and tinted lighting previews
  - `ResponseGamutAnalyzer` — palette reach vs. target demand; quantizes targets into bins so cost scales with the number of *distinct* target vectors, not the cell count
  - `PaletteAPIClient` — async `URLSession` client for the `color_matching` API

- **`ColorMatching`** (app) wraps the package in a SwiftUI interface: an `@Observable` app model, native file panels, `NSPrintOperation` printing, ImageIO export, and Codable `.cmpj` project persistence.

The Xcode project is **generated, not committed** — `project.yml` is the source of truth. Run `bin/setup` (or `xcodegen generate`) after cloning or editing `project.yml`.

## Palette data

Colors and their measured illuminant responses are fetched from `color_matching`'s versioned API:

- `GET /api/v1/printer_profiles`
- `GET /api/v1/colors?printer_profile_id=N`

Response vectors merge human-entered responses (priority) and instrument measurements, and clearly separate normalized brightness (the solver value) from raw instrument readings. See [`color_matching` PR #84](https://github.com/viamin/color_matching/pull/84).

## Development

```bash
# Core unit tests (no Xcode needed)
cd ColorComposerCore && swift test

# Regenerate the Xcode project after editing project.yml
xcodegen generate

# Build the app
xcodebuild -project ColorMatching.xcodeproj -scheme ColorMatching build
```

## Related

- [`color_matching`](https://github.com/viamin/color_matching) — Elixir/Phoenix backend that owns the palette and measured illuminant-response data
- `ColorMatching-iOS` — companion iOS app for capturing/printing swatch sheets

## Status

v1 — deliberately simple and testable. Out of scope for now (but structured to allow later): spectral reflectance modeling, ICC profile generation, CMYK separation, visible halftone optimization, vector error diffusion, and multi-color logical cells.
