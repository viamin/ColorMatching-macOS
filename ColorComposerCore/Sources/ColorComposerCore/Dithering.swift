import Foundation

/// Optional error-diffusion pass applied after the nearest-neighbor solve.
///
/// The default, `.off`, is plain nearest-neighbor matching: every cell gets the
/// single closest palette color, which bands (posterizes) when no color
/// reproduces a target tone exactly. `.floydSteinberg` runs a vector
/// Floyd–Steinberg pass — each cell's signed per-channel error
/// (target − chosen) is diffused to not-yet-visited neighbors (7/16 right,
/// 3/16 bottom-left, 5/16 bottom, 1/16 bottom-right) so adjacent cells
/// compensate. The result is still one color per cell, so renderers, export,
/// and print are unaffected.
///
/// Dithering trades per-cell error for spatial (tonal) accuracy: a single cell
/// may reproduce its target less exactly, but a local average of cells tracks
/// the intended tone far more closely than nearest-neighbor banding. Per-cell
/// `errors` in the result are therefore recorded against the *original* target
/// and may be larger than nearest-neighbor; the win is in de-posterized local
/// averages, not lower per-cell scores.
public enum Dithering: Sendable, Equatable {
    /// No diffusion — plain nearest-neighbor matching (the default).
    case off
    /// Vector Floyd–Steinberg error diffusion. Walks the grid in raster order
    /// with earliest-candidate tie-breaking, so output is deterministic for a
    /// given input order.
    case floydSteinberg
}
