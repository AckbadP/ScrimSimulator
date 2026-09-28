//! Train a [`crate::Font`] from a font-sample image and its transcript.
//!
//! The sample renders several text lines, one glyph after another with no spaces, at a known flat
//! background/foreground colour pair. Training must turn that into one [`crate::template::Template`]
//! per character in the transcript. Two things make this non-trivial:
//!
//! 1. **Line isolation.** The image is tiled into as many horizontal slabs as there are transcript
//!    lines, using only the detected line positions (no hardcoded offsets) so this keeps working if
//!    the sample is re-captured at a different size or line count.
//! 2. **Glyph/run reconciliation.** Column-wise ink runs within a line don't always match transcript
//!    characters 1:1: `"` renders as two disconnected dots (2 runs -> 1 char) and tightly-kerned
//!    pairs can touch into a single run (1 run -> 2 chars). Counts are reconciled generically —
//!    merge the closest-together runs when there are too many, split the widest run at its ink
//!    minimum when there are too few — rather than hardcoding which characters need it, so a
//!    regenerated sample re-trains without code changes.

use crate::coverage::{coverage_region_with_colours, CoverageMap};
use crate::segment::{
    self, blobs as find_blobs, gaps, line_bands, split_at_ink_minimum, vertical_extent, Span,
};
use crate::template::Template;
use anyhow::{bail, Context};
use image::RgbImage;

/// Threshold (in coverage units) for detecting a text line's vertical extent. Low enough to
/// catch faint anti-aliased ascender tips, well above flat-background noise.
const LINE_THRESHOLD: f32 = 0.15;

/// A run's height counts as "short" (and so a candidate to be one piece of a multi-piece glyph,
/// like one dot of `"`) when it's at most this fraction of the tallest run's height in the line.
/// Distinct adjacent glyphs (e.g. `[` next to `]`) are each nearly full line height, so this
/// reliably tells the two situations apart regardless of which pair happens to have the smallest
/// horizontal gap.
const SHORT_RUN_FRACTION: f32 = 0.6;

/// Pick which adjacent pair of runs to merge when there are more runs than expected characters.
/// Prefers the smallest-gap pair among those where *both* runs are short relative to the line
/// (disconnected pieces of one glyph, like `"`'s two dots); only falls back to the global
/// smallest gap if no such pair exists.
fn merge_candidate(cov: &CoverageMap, spans: &[Span]) -> usize {
    let heights: Vec<usize> = spans
        .iter()
        .map(|&s| {
            let (lo, hi) = vertical_extent(cov, s, segment::DEFAULT_BLOB_THRESHOLD);
            hi - lo
        })
        .collect();
    let max_h = heights.iter().copied().max().unwrap_or(0);
    let short_thresh = (max_h as f32 * SHORT_RUN_FRACTION) as usize;
    let g = gaps(spans);

    let short_pair_min = g
        .iter()
        .enumerate()
        .filter(|&(i, _)| heights[i] <= short_thresh && heights[i + 1] <= short_thresh)
        .min_by_key(|&(_, gap)| gap);
    if let Some((i, _)) = short_pair_min {
        return i;
    }
    g.iter().enumerate().min_by_key(|&(_, gap)| gap).map(|(i, _)| i).unwrap_or(0)
}

/// Reconcile the number of detected runs in a line with the number of expected characters by
/// greedily merging (if there are too many runs) or splitting (if there are too few).
fn reconcile(cov: &CoverageMap, mut spans: Vec<Span>, expected: usize, line: &str) -> anyhow::Result<Vec<Span>> {
    while spans.len() > expected {
        let i = merge_candidate(cov, &spans);
        let merged = (spans[i].0, spans[i + 1].1);
        spans.splice(i..=i + 1, [merged]);
    }
    while spans.len() < expected {
        // Too few runs: split the widest run at its ink minimum (this is how touching characters
        // like tightly-kerned brackets reconcile).
        let (i, _) = spans
            .iter()
            .enumerate()
            .max_by_key(|(_, s)| s.1 - s.0)
            .context("no runs to split")?;
        let span = spans[i];
        if span.1 - span.0 < 2 {
            bail!(
                "line {:?}: expected {} glyphs, found {} runs and the widest is too narrow to split",
                line,
                expected,
                spans.len()
            );
        }
        let mid = split_at_ink_minimum(cov, span);
        spans.splice(i..=i, [(span.0, mid), (mid, span.1)]);
    }
    spans.sort_by_key(|s| s.0);
    if spans.len() != expected {
        bail!(
            "line {:?}: expected {} glyphs, reconciled to {}",
            line,
            expected,
            spans.len()
        );
    }
    Ok(spans)
}

/// Train templates from a sample image at a known flat `bg`/`fg` colour pair, given the transcript
/// lines it renders (one line of the sample per string in `lines`, in order, no spaces).
///
/// Returns the templates plus the common per-glyph frame height used, and the measured line pitch
/// (used as a default word-gap scale if the caller doesn't have a better source).
pub fn train(
    img: &RgbImage,
    lines: &[&str],
    bg: [u8; 3],
    fg: [u8; 3],
) -> anyhow::Result<(Vec<Template>, usize)> {
    let (w, h) = (img.width(), img.height());
    let full = coverage_region_with_colours(img, 0, 0, w, h, bg, fg);
    let bands = line_bands(&full, LINE_THRESHOLD);
    if bands.len() != lines.len() {
        bail!(
            "detected {} text line(s) in the sample but the transcript has {}",
            bands.len(),
            lines.len()
        );
    }

    // Tile the whole image height into one non-overlapping slab per line, split at the midpoint
    // of the *gap* between one line's bottom and the next line's top — not between their tops.
    // Splitting at top-to-top midpoints clips descenders (g/j/p/q/y reach well below a line's own
    // top-of-x-height neighbours) and lets that ink bleed into the next line's slab instead,
    // corrupting both lines' glyph counts.
    let tops: Vec<usize> = bands.iter().map(|b| b.0).collect();
    let bottoms: Vec<usize> = bands.iter().map(|b| b.1).collect();
    let pitch = if tops.len() > 1 {
        (tops[tops.len() - 1] - tops[0]) as f32 / (tops.len() - 1) as f32
    } else {
        h as f32
    };
    let mut slab_bounds = vec![0usize];
    for i in 0..bottoms.len() - 1 {
        slab_bounds.push((bottoms[i] + tops[i + 1]) / 2);
    }
    slab_bounds.push(h as usize);

    let mut templates = Vec::new();
    for (li, (&line, win)) in lines.iter().zip(slab_bounds.windows(2)).enumerate() {
        let (y0, y1) = (win[0] as u32, win[1] as u32);
        let slab = coverage_region_with_colours(img, 0, y0, w, y1 - y0, bg, fg);
        let raw = find_blobs(&slab, segment::DEFAULT_BLOB_THRESHOLD);
        if raw.is_empty() {
            bail!("line {} ({:?}): no glyphs detected", li, line);
        }
        let spans = reconcile(&slab, raw, line.chars().count(), line)?;
        for (ch, (x0, x1)) in line.chars().zip(spans) {
            let glyph_cov = slab.slice_cols(x0, x1);
            templates.push(Template::from_coverage(ch, &glyph_cov));
        }
    }
    Ok((templates, pitch.round() as usize))
}
