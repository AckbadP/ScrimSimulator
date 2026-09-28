//! Ink-projection segmentation (DESIGN.md S4.3): find text line bands by row-wise ink, and glyph
//! blobs within a band by column-wise ink.

use crate::coverage::CoverageMap;

/// An inclusive-exclusive pixel range `[start, end)`.
pub type Span = (usize, usize);

/// Find contiguous ink runs in a 1-D ink signal, using a coverage threshold.
pub fn runs(signal: &[f32], threshold: f32) -> Vec<Span> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    for (i, &v) in signal.iter().enumerate() {
        let ink = v > threshold;
        match (ink, start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                out.push((s, i));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        out.push((s, signal.len()));
    }
    out
}

/// Find horizontal text-line bands in a full-height coverage map: rows where any pixel has ink.
pub fn line_bands(cov: &CoverageMap, threshold: f32) -> Vec<Span> {
    let row_ink: Vec<f32> = (0..cov.height)
        .map(|y| cov.row(y).iter().cloned().fold(0.0f32, f32::max))
        .collect();
    runs(&row_ink, threshold)
}

/// Find glyph-blob column spans within a coverage map, using the column-wise max-ink projection.
/// Default threshold of 0.21 was tuned against the font sample and overview fixtures — low
/// enough to keep faint anti-aliased serifs (e.g. of `.`, `,`) but well above encoder noise.
pub const DEFAULT_BLOB_THRESHOLD: f32 = 0.21;

pub fn blobs(cov: &CoverageMap, threshold: f32) -> Vec<Span> {
    let cols = cov.column_ink();
    runs(&cols, threshold)
}

/// Find the column at which a run's ink is weakest, for splitting one blob into two glyphs
/// (e.g. `[]`, which touch as a single connected run of ink at the coverage threshold used for
/// segmentation). Only interior columns (not the first/last) are considered so the split
/// actually separates ink into two non-empty pieces.
pub fn split_at_ink_minimum(cov: &CoverageMap, span: Span) -> usize {
    let (s, e) = span;
    let cols = cov.column_ink();
    let mut best_x = s + 1;
    let mut best_v = f32::INFINITY;
    let hi = e.saturating_sub(1).max(s + 1);
    for (x, &v) in cols.iter().enumerate().take(hi).skip(s + 1) {
        if v < best_v {
            best_v = v;
            best_x = x;
        }
    }
    best_x
}

/// Gap width (in pixels) between consecutive blobs, used to decide whether a space should be
/// inserted between them.
pub fn gaps(blobs: &[Span]) -> Vec<usize> {
    blobs
        .windows(2)
        .map(|w| w[1].0.saturating_sub(w[0].1))
        .collect()
}

/// The vertical extent (min row, max row inclusive) of ink within a column span, at the given
/// coverage threshold. Used to tell apart "two disconnected pieces of one glyph" (both short and
/// at the same height, like `"`'s two dots) from "two adjacent distinct glyphs" (typically each
/// spanning most of the line's height) when reconciling run counts against a transcript.
pub fn vertical_extent(cov: &CoverageMap, span: Span, threshold: f32) -> (usize, usize) {
    let (s, e) = span;
    let mut lo = cov.height;
    let mut hi = 0usize;
    for y in 0..cov.height {
        let row = cov.row(y);
        if row[s..e].iter().any(|&v| v > threshold) {
            lo = lo.min(y);
            hi = hi.max(y);
        }
    }
    if lo > hi {
        (0, 0)
    } else {
        (lo, hi)
    }
}
