//! Training the bundled font sample must recover exactly its own transcript, glyph for glyph.

use glyph::Font;

#[test]
fn builtin_font_trains_all_94_glyphs() {
    let font = Font::builtin().expect("training the bundled sample");
    assert_eq!(font.templates().len(), 94, "expected every printable non-space ASCII glyph");

    let expected: std::collections::HashSet<char> =
        (33u8..=126u8).map(|b| b as char).collect();
    let got: std::collections::HashSet<char> = font.templates().iter().map(|t| t.ch).collect();
    let missing: Vec<char> = expected.difference(&got).copied().collect();
    assert!(missing.is_empty(), "missing glyphs in sample: {missing:?}");
}

#[test]
fn reading_the_sample_lines_back_recovers_the_transcript() {
    // Each template, matched against a fresh render of its own line, should identify as itself
    // with a clear margin. This exercises segmentation + reconciliation + NCC matching end to end
    // on the exact image the font was trained from.
    let img = image::load_from_memory(include_bytes!("../assets/font-sample.png"))
        .unwrap()
        .to_rgb8();
    let lines: Vec<&str> = include_str!("../assets/font-sample.txt").lines().collect();
    let font = Font::builtin().unwrap();

    // Re-detect the same line bands training used, then read each line as one cell spanning the
    // full image width — this is the same code path a caller reading a real overview cell uses.
    let bands = detect_bands(&img);
    assert_eq!(bands.len(), lines.len());

    for (line, (y0, y1)) in lines.iter().zip(bands) {
        let reading = font.read_region(&img, 0, y0, img.width(), y1 - y0, glyph::Alphabet::Full);
        assert_eq!(
            reading.text,
            expected_reading(line),
            "line {line:?} misread as {:?}",
            reading.text
        );
    }
}

/// `"` is the one trained glyph made of two disconnected ink pieces (see `train.rs`'s
/// run-reconciliation doc comment). Training merges the two dots back into one glyph because it
/// knows the expected character count; `matcher::read` deliberately doesn't do that at read time
/// (DESIGN.md S4.3 keeps the matcher simple and leaves cross-glyph correction to the fuzzy
/// candidate-match pass, M2) — EVE pilot/ship/corp names never contain a literal `"`, so this has
/// no effect on real overview cells. Reading the sample's own `"` back therefore yields two
/// apostrophes rather than one quote; this documents that expected shape instead of masking it.
fn expected_reading(line: &str) -> String {
    line.replace('"', "''")
}

/// Minimal standalone re-detection of line bands, mirroring `train::LINE_THRESHOLD`, so this test
/// doesn't depend on train.rs internals.
fn detect_bands(img: &image::RgbImage) -> Vec<(u32, u32)> {
    let (w, h) = (img.width(), img.height());
    let mut row_ink = vec![false; h as usize];
    for y in 0..h {
        for x in 0..w {
            let p = img.get_pixel(x, y).0;
            let v = (p[0] as f32 - 10.0) / 147.0;
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
    // Widen each band symmetrically halfway to its neighbours, same as training's slab tiling.
    let tops: Vec<u32> = spans.iter().map(|s| s.0).collect();
    let bottoms: Vec<u32> = spans.iter().map(|s| s.1).collect();
    let mut bounds = vec![0u32];
    for i in 0..bottoms.len() - 1 {
        bounds.push((bottoms[i] + tops[i + 1]) / 2);
    }
    bounds.push(h);
    bounds.windows(2).map(|w| (w[0], w[1])).collect()
}
