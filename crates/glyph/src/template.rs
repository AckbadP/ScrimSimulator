//! Glyph templates and normalised cross-correlation (NCC) matching.
//!
//! Each template is cropped to its own line's slab during training (`train.rs`), so heights vary
//! a little line to line. Matching against a cell searches a small window of vertical and
//! horizontal offsets rather than assuming baseline-exact alignment, since a cell's row band (the
//! overview highlight/background stripe) is generally taller than the glyphs it contains and its
//! top does not line up pixel-for-pixel with the training crop.

use crate::coverage::CoverageMap;

#[derive(Clone, Debug)]
pub struct Template {
    pub ch: char,
    pub width: usize,
    pub height: usize,
    /// Row-major coverage values, `[0, 1]`.
    pub data: Vec<f32>,
}

impl Template {
    pub fn from_coverage(ch: char, cov: &CoverageMap) -> Template {
        Template {
            ch,
            width: cov.width,
            height: cov.height,
            data: cov.data.clone(),
        }
    }
}

/// Normalised cross-correlation between two equal-sized coverage patches, flattened row-major.
/// Returns a value in roughly `[-1, 1]`; `1` is a perfect match. Patches with (near-)zero
/// variance (e.g. all-background) score `0` rather than `NaN`/`inf`.
pub fn ncc(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len());
    let n = a.len() as f32;
    let mean_a = a.iter().sum::<f32>() / n;
    let mean_b = b.iter().sum::<f32>() / n;
    let mut num = 0.0f32;
    let mut da = 0.0f32;
    let mut db = 0.0f32;
    for i in 0..a.len() {
        let x = a[i] - mean_a;
        let y = b[i] - mean_b;
        num += x * y;
        da += x * x;
        db += y * y;
    }
    let denom = (da * db).sqrt();
    if denom < 1e-6 {
        0.0
    } else {
        num / denom
    }
}

/// Best NCC score (and the offset it occurred at) for `template` against a `cell` region that may
/// be larger than the template in both dimensions. `dx_pad`/`dy_pad` bound how far, beyond the
/// natural size difference, the template is allowed to slide — this absorbs the vertical mismatch
/// between a training crop and a live cell's row band, plus a few pixels of horizontal jitter from
/// segmentation, without letting a small glyph match anywhere in a large cell.
pub fn best_match(
    template: &Template,
    cell: &CoverageMap,
    dx_pad: usize,
    dy_pad: usize,
) -> (f32, i32, i32) {
    let th = template.height as i32;
    let tw = template.width as i32;
    let ch = cell.height as i32;
    let cw = cell.width as i32;

    let y_lo = -(dy_pad as i32);
    let y_hi = ch - th + dy_pad as i32;
    let x_lo = -(dx_pad as i32);
    let x_hi = cw - tw + dx_pad as i32;

    let mut best = f32::NEG_INFINITY;
    let mut best_dx = 0;
    let mut best_dy = 0;

    let mut patch = vec![0.0f32; template.data.len()];
    for dy in y_lo..=y_hi {
        for dx in x_lo..=x_hi {
            for ty in 0..template.height {
                let cy = dy + ty as i32;
                for tx in 0..template.width {
                    let cx = dx + tx as i32;
                    let v = if cy >= 0 && cy < ch && cx >= 0 && cx < cw {
                        cell.get(cx as usize, cy as usize)
                    } else {
                        0.0
                    };
                    patch[ty * template.width + tx] = v;
                }
            }
            let score = ncc(&template.data, &patch);
            if score > best {
                best = score;
                best_dx = dx;
                best_dy = dy;
            }
        }
    }
    (best, best_dx, best_dy)
}
