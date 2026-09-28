//! Coverage normalisation (DESIGN.md S4.3) must make matching independent of the cell's actual
//! background/foreground colour. This re-renders the font sample over each background the
//! overview actually uses (dark/gray/red/blue/purple, measured from the fixtures) and asserts
//! every line still reads back exactly.

use glyph::{Alphabet, Font};
use image::{Rgb, RgbImage};

/// Measured overview row backgrounds (see docs/DESIGN.md S3.2, S4.3 and the golden fixtures).
const BACKGROUNDS: &[(&str, [u8; 3])] = &[
    ("dark", [10, 10, 10]),
    ("gray", [94, 94, 94]),
    ("red", [101, 5, 5]),
    ("blue", [16, 43, 103]),
    ("purple", [89, 39, 138]),
];

/// Foreground colours to pair with each background: the sample's own gray, and a near-white the
/// overview actually renders text in.
const FOREGROUNDS: &[[u8; 3]] = &[[157, 157, 157], [235, 235, 235]];

/// Re-render the (grayscale) font sample's ink coverage over an arbitrary bg/fg pair.
fn recolor(sample: &RgbImage, bg: [u8; 3], fg: [u8; 3]) -> RgbImage {
    let mut out = RgbImage::new(sample.width(), sample.height());
    for y in 0..sample.height() {
        for x in 0..sample.width() {
            let v = sample.get_pixel(x, y).0[0] as f32; // R=G=B in the sample
            let a = ((v - 10.0) / 147.0).clamp(0.0, 1.0);
            let px = [
                (bg[0] as f32 + a * (fg[0] as f32 - bg[0] as f32)).round() as u8,
                (bg[1] as f32 + a * (fg[1] as f32 - bg[1] as f32)).round() as u8,
                (bg[2] as f32 + a * (fg[2] as f32 - bg[2] as f32)).round() as u8,
            ];
            out.put_pixel(x, y, Rgb(px));
        }
    }
    out
}

/// Same line-band detection as `tests/sample.rs` (kept independent of `train.rs` internals).
fn detect_bands(img: &RgbImage, bg: [u8; 3], fg: [u8; 3]) -> Vec<(u32, u32)> {
    let (w, h) = (img.width(), img.height());
    let d0 = fg[0] as f32 - bg[0] as f32;
    let denom = d0 * d0;
    let mut row_ink = vec![false; h as usize];
    for y in 0..h {
        for x in 0..w {
            let p = img.get_pixel(x, y).0;
            let v = if denom.abs() > 1e-6 {
                (p[0] as f32 - bg[0] as f32) * d0 / denom
            } else {
                0.0
            };
            if v > 0.15 {
                row_ink[y as usize] = true;
                break;
            }
        }
    }
    let mut spans = Vec::new();
    let mut start = None;
    for (y, &ink) in row_ink.iter().enumerate() {
        match (ink, start) {
            (true, None) => start = Some(y),
            (false, Some(s)) => {
                spans.push((s as u32, y as u32));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        spans.push((s as u32, h));
    }
    let tops: Vec<u32> = spans.iter().map(|s| s.0).collect();
    let bottoms: Vec<u32> = spans.iter().map(|s| s.1).collect();
    let mut bounds = vec![0u32];
    for i in 0..bottoms.len() - 1 {
        bounds.push((bottoms[i] + tops[i + 1]) / 2);
    }
    bounds.push(h);
    bounds.windows(2).map(|w| (w[0], w[1])).collect()
}

#[test]
fn every_line_reads_back_on_every_measured_background() {
    let sample = image::load_from_memory(include_bytes!("../assets/font-sample.png"))
        .unwrap()
        .to_rgb8();
    let lines: Vec<&str> = include_str!("../assets/font-sample.txt").lines().collect();
    let font = Font::builtin().unwrap();

    for &(bg_name, bg) in BACKGROUNDS {
        for &fg in FOREGROUNDS {
            if bg == fg {
                continue;
            }
            let recolored = recolor(&sample, bg, fg);
            let bands = detect_bands(&recolored, bg, fg);
            assert_eq!(bands.len(), lines.len(), "bg={bg_name} fg={fg:?}: band count");
            for (line, (y0, y1)) in lines.iter().zip(bands) {
                let reading = font.read_region(&recolored, 0, y0, recolored.width(), y1 - y0, Alphabet::Full);
                // See `tests/sample.rs::expected_reading`: `"` reads back as two apostrophes at
                // read time by design; irrelevant to real overview text, which never contains `"`.
                assert_eq!(
                    reading.text,
                    line.replace('"', "''"),
                    "bg={bg_name} fg={fg:?}: line {line:?} misread as {:?}",
                    reading.text
                );
            }
        }
    }
}
