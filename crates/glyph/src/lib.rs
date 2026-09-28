//! Template-matching OCR for the EVE Online overview font.
//!
//! Implements DESIGN.md S4.3 (glyph OCR): the overview font is fixed, pixel-stable, and rendered
//! on a small set of known flat backgrounds, so a per-glyph template classifier trained once on
//! the actual font is more accurate on small anti-aliased text than general OCR, and removes any
//! dependence on a specific UI scale — coverage normalisation (`coverage.rs`) makes matching
//! independent of the cell's actual background/foreground colour, so one template set covers the
//! gray/red/blue/purple/dark row backgrounds the overview uses.
//!
//! ```no_run
//! use glyph::{Alphabet, Font};
//! # fn get_cell_image() -> image::RgbImage { unimplemented!() }
//! let font = Font::builtin().expect("bundled font sample trains cleanly");
//! let cell = get_cell_image();
//! let reading = font.read(&cell, Alphabet::Numeric);
//! println!("{} (confidence {})", reading.text, reading.confidence);
//! ```

pub mod coverage;
pub mod matcher;
pub mod segment;
pub mod template;
pub mod train;

pub use matcher::{Alphabet, CharReading, Reading};
pub use template::Template;

use coverage::coverage_region;
use image::RgbImage;

/// The font sample bundled into the binary (metadata-stripped PNG; see `assets/font-sample.png`)
/// and its transcript, one line per row rendered in the sample.
const SAMPLE_PNG: &[u8] = include_bytes!("../assets/font-sample.png");
const SAMPLE_TRANSCRIPT: &str = include_str!("../assets/font-sample.txt");

/// The sample's known flat background/foreground colours (grayscale PNG: R=G=B).
const SAMPLE_BG: [u8; 3] = [10, 10, 10];
const SAMPLE_FG: [u8; 3] = [157, 157, 157];

/// Default minimum gap (px) between ink runs that counts as a word break rather than ordinary
/// inter-glyph spacing. Tuned against the overview fixtures (S6 golden frames): intra-word gaps
/// there run up to ~5px, word gaps are ~15px or more.
const DEFAULT_SPACE_GAP_PX: usize = 9;

/// A trained set of glyph templates plus the reading parameters derived from training.
pub struct Font {
    templates: Vec<Template>,
    space_gap_px: usize,
}

impl Font {
    /// Train from the font sample bundled into this crate (`assets/font-sample.png` /
    /// `.txt`). Cheap (microseconds) — safe to call once at process startup.
    pub fn builtin() -> anyhow::Result<Font> {
        let img = image::load_from_memory(SAMPLE_PNG)?.to_rgb8();
        let lines: Vec<&str> = SAMPLE_TRANSCRIPT.lines().collect();
        Font::from_sample(&img, &lines, SAMPLE_BG, SAMPLE_FG)
    }

    /// Train from an arbitrary sample image and transcript. `bg`/`fg` are the sample's known flat
    /// colours (not estimated — training crops are small and a modal-colour estimate could latch
    /// onto ink instead of background on a very short line).
    pub fn from_sample(
        img: &RgbImage,
        lines: &[&str],
        bg: [u8; 3],
        fg: [u8; 3],
    ) -> anyhow::Result<Font> {
        let (templates, _pitch) = train::train(img, lines, bg, fg)?;
        Ok(Font {
            templates,
            space_gap_px: DEFAULT_SPACE_GAP_PX,
        })
    }

    /// Override the word-gap threshold (see [`DEFAULT_SPACE_GAP_PX`]); layout calibration (S0)
    /// will eventually derive this per-recording instead of using the built-in default.
    pub fn with_space_gap_px(mut self, px: usize) -> Font {
        self.space_gap_px = px;
        self
    }

    pub fn templates(&self) -> &[Template] {
        &self.templates
    }

    /// Read one cell image (bg/fg auto-detected — see `coverage::coverage_region`) against the
    /// given alphabet.
    pub fn read(&self, cell: &RgbImage, alphabet: Alphabet) -> Reading {
        let cov = coverage_region(cell, 0, 0, cell.width(), cell.height());
        matcher::read(&self.templates, &cov, alphabet, self.space_gap_px)
    }

    /// Read a rectangular region of a larger image (e.g. one overview cell within a full frame).
    pub fn read_region(
        &self,
        img: &RgbImage,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        alphabet: Alphabet,
    ) -> Reading {
        let cov = coverage_region(img, x, y, w, h);
        matcher::read(&self.templates, &cov, alphabet, self.space_gap_px)
    }
}
