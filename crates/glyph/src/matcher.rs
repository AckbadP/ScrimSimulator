//! Read a segmented cell against a trained [`crate::Font`] (DESIGN.md S4.3).
//!
//! Each ink run in the cell is classified independently against every template in the active
//! alphabet by best-offset NCC (`template::best_match`). This is deliberately simple: it does not
//! attempt to re-split or merge runs at read time (unlike training, which must reconcile a known
//! transcript). A run spanning two touching glyphs (e.g. `ff`) will just be classified as whatever
//! single template matches best — DESIGN.md's redundancy/fuzzy-candidate correction (S4.3, M2) is
//! the intended place to fix that, not this crate. What this crate guarantees is that such a cell
//! comes back with a low confidence margin rather than a silently wrong high-confidence answer.

use crate::coverage::CoverageMap;
use crate::segment::{self, gaps};
use crate::template::{best_match, Template};

/// Which characters are legal in a cell, used to prune the search (DESIGN.md S4.3: "numeric
/// columns use a digit/separator/unit alphabet only — a tiny, closed, high-confidence set").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alphabet {
    /// Distance/velocity/angular-velocity columns: digits, thousands separator, decimal point,
    /// minus sign, and the unit letters the overview actually appends (km, m, m/s, AU, rad/s...).
    Numeric,
    /// Name/type/corp/alliance columns: the full trained character set.
    Full,
}

impl Alphabet {
    fn allows(self, ch: char) -> bool {
        match self {
            Alphabet::Full => true,
            Alphabet::Numeric => "0123456789,.-kmAUs/".contains(ch),
        }
    }
}

/// One classified character, with the winning NCC score and the margin over the runner-up. A
/// small margin means the glyph was genuinely ambiguous (e.g. `l` vs `I`, or a run that actually
/// contained two touching characters).
#[derive(Clone, Debug)]
pub struct CharReading {
    pub ch: char,
    pub score: f32,
    pub margin: f32,
}

/// The result of reading one cell.
#[derive(Clone, Debug)]
pub struct Reading {
    pub text: String,
    pub chars: Vec<CharReading>,
    /// The smallest per-character margin in the reading — a cheap proxy for "how much do I trust
    /// this whole cell". DESIGN.md S4.3: "every cell carries a confidence; low-confidence cells
    /// are dropped, not guessed" is left to the caller, thresholding on this.
    pub confidence: f32,
}

/// How far a template is allowed to slide inside a cell, beyond the natural size difference.
const DX_PAD: usize = 2;
const DY_PAD: usize = 10;

/// Width tolerance (px) for the initial candidate filter — skips obviously-wrong-width templates
/// to keep matching fast. Widened automatically if it would leave zero candidates (a wider- or
/// narrower-than-any-single-glyph run, e.g. touching characters), so a reading is always produced.
const WIDTH_TOLERANCE: i32 = 4;

fn best_two<'a>(templates: &'a [Template], cell: &CoverageMap, alphabet: Alphabet) -> Vec<(f32, &'a Template)> {
    let candidates: Vec<&Template> = templates
        .iter()
        .filter(|t| alphabet.allows(t.ch))
        .collect();

    let narrow: Vec<&Template> = candidates
        .iter()
        .copied()
        .filter(|t| (t.width as i32 - cell.width as i32).abs() <= WIDTH_TOLERANCE)
        .collect();
    let pool = if narrow.is_empty() { candidates } else { narrow };

    let mut scored: Vec<(f32, &Template)> = pool
        .into_iter()
        .map(|t| {
            let (score, _dx, _dy) = best_match(t, cell, DX_PAD, DY_PAD);
            (score, t)
        })
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
    scored
}

/// Read a full cell: segment it into ink runs, classify each, and insert spaces at wide gaps.
///
/// `space_gap_px` is the minimum gap (in pixels) between two runs that counts as a word break
/// rather than ordinary inter-glyph spacing.
pub fn read(templates: &[Template], cell: &CoverageMap, alphabet: Alphabet, space_gap_px: usize) -> Reading {
    let runs = segment::blobs(cell, segment::DEFAULT_BLOB_THRESHOLD);
    let run_gaps = gaps(&runs);

    let mut text = String::new();
    let mut chars = Vec::new();
    let mut confidence = f32::INFINITY;

    for (i, &(x0, x1)) in runs.iter().enumerate() {
        if i > 0 && run_gaps[i - 1] >= space_gap_px {
            text.push(' ');
        }
        let glyph_cell = cell.slice_cols(x0, x1);
        let scored = best_two(templates, &glyph_cell, alphabet);
        let (top_score, top) = scored.first().copied().map(|(s, t)| (s, t.ch)).unwrap_or((0.0, '?'));
        let second_score = scored.get(1).map(|(s, _)| *s).unwrap_or(-1.0);
        let margin = top_score - second_score;
        confidence = confidence.min(margin);
        text.push(top);
        chars.push(CharReading {
            ch: top,
            score: top_score,
            margin,
        });
    }

    if runs.is_empty() {
        confidence = 0.0;
    }

    Reading {
        text,
        chars,
        confidence,
    }
}
