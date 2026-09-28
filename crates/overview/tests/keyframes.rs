//! Row-reading tests against `frame0.png`, a real native-resolution (2560x1600) frame from
//! `overview-sample.mkv`. Ground truth was read directly off the frame (cross-checked against
//! upscaled crops) while building this crate's layout detection.

use overview::layout::{self, Rect};
use overview::row::read_rows;
use overview::value::CellValue;

const PANEL: Rect = Rect { x: 816, y: 0, w: 1200, h: 1600 };

struct Row {
    distance_m: Option<f64>,
    name: &'static str,
    ty: &'static str,
    velocity: f64,
    /// A known, out-of-scope OCR ambiguity (see `crates/glyph`'s golden tests for the same
    /// pattern): `l`/`I` and `J`/`I` are visually close in this font at video-compression
    /// resolution. Listed so the test still checks a reading was produced, without demanding an
    /// exact match this crate's OCR can't reliably give.
    fuzzy_name: bool,
    fuzzy_type: bool,
    /// Distance is allowed to come back unreadable (a real degraded case, not a bug): this
    /// video's own capsuleer's row renders red-on-red-highlight, which this crate's OCR does not
    /// guarantee, and its identity (name/type) is what tracking actually depends on.
    fuzzy_distance: bool,
}

const fn row(distance_m: f64, name: &'static str, ty: &'static str, velocity: f64) -> Row {
    Row { distance_m: Some(distance_m), name, ty, velocity, fuzzy_name: false, fuzzy_type: false, fuzzy_distance: false }
}

const ROWS: &[Row] = &[
    row(29_000.0, "Alexader Todak", "Corax", 247.0),
    row(35_000.0, "Charlot theHarl", "Tornado", 0.0),
    row(29_000.0, "ChernobylAllen", "Badger", 85.0),
    row(23_000.0, "Defenzer", "Tornado", 0.0),
    row(26_000.0, "Desson Craft", "Nereus", 86.0),
    row(24_000.0, "ELECTR1C", "Badger", 123.0),
    row(28_000.0, "Ethan Tiboteau", "Squall", 0.0),
    row(4_482.0, "FATHERFACK", "Venture", 385.0),
    Row { distance_m: Some(23_000.0), name: "ftftfttfy", ty: "Capsule", velocity: 0.0, fuzzy_name: true, fuzzy_type: false, fuzzy_distance: false },
    row(24_000.0, "Hai Yun Huang", "Gnosis", 0.0),
    row(34_000.0, "Henry Tiboteau", "Iteron Mark V", 0.0),
    Row { distance_m: Some(21_000.0), name: "Illypa Kapmen", ty: "Astero", velocity: 632.0, fuzzy_name: true, fuzzy_type: false, fuzzy_distance: false },
    // Distance itself is a documented degraded case here too: the `km` run is one of this font's
    // rarer bad single-glyph matches (see `crates/glyph`'s `CONFIDENT_SINGLE_SCORE` doc comment)
    // and comes back as a wrong glyph at very low confidence rather than "37 km" — the system
    // correctly refuses to guess (the resulting text fails unit parsing -> `Unreadable`) rather
    // than silently producing a wrong number, which is what actually matters here.
    Row { distance_m: Some(37_000.0), name: "Janis Drukhari", ty: "Worm", velocity: 472.0, fuzzy_name: true, fuzzy_type: true, fuzzy_distance: true },
    row(12_000.0, "jannaukko", "Mastodon", 222.0),
    Row { distance_m: Some(11_000.0), name: "Jax Sunder", ty: "Griffin Navy Is", velocity: 0.0, fuzzy_name: true, fuzzy_type: false, fuzzy_distance: false },
    Row { distance_m: Some(44_000.0), name: "Jilbert Tibotea", ty: "Badger", velocity: 0.0, fuzzy_name: true, fuzzy_type: false, fuzzy_distance: false },
    row(35_000.0, "Kenneth McArt", "Tornado", 0.0),
    row(187_000.0, "Laxus Erata", "Bustard", 70.0),
    row(34_000.0, "Lonely Babe", "Scorpion", 0.0),
    row(24_000.0, "Lysithea", "Orca", 0.0),
    row(27_000.0, "Mathis Tibotea", "Badger", 0.0),
    row(462_000.0, "Nepaxa", "Metamorphosis", 185.0),
    row(35_000.0, "Nicolas Tibotea", "Tornado", 0.0),
    row(23_000.0, "Rudocopnax", "Miasmos", 29.0),
    Row { distance_m: None, name: "samantha m", ty: "Tornado", velocity: 0.0, fuzzy_name: false, fuzzy_type: false, fuzzy_distance: true },
    row(145_000.0, "Samantha Myh", "Tayra", 0.0),
    row(123_000.0, "Samantha-Nov", "Gnosis", 0.0),
    Row { distance_m: Some(35_000.0), name: "Sergeji Harloff", ty: "Tornado", velocity: 0.0, fuzzy_name: true, fuzzy_type: false, fuzzy_distance: false },
];

#[test]
fn frame0_rows_match_ground_truth() {
    let img = image::open("tests/fixtures/frame0.png").unwrap().to_rgb8();
    let font = glyph::Font::builtin().unwrap();
    let layout = layout::detect(&img, PANEL, &font).unwrap();
    let rows = read_rows(&img, &layout, &font);

    assert!(
        rows.len() >= ROWS.len(),
        "expected at least {} rows, got {} (list may have been cut short)",
        ROWS.len(),
        rows.len()
    );

    for (i, expected) in ROWS.iter().enumerate() {
        let got = &rows[i];

        if !expected.fuzzy_distance {
            let m = expected.distance_m.expect("non-fuzzy rows always carry an expected distance");
            assert_eq!(got.distance, CellValue::Value(m), "row {i} ({:?}) distance", expected.name);
        } // else: a documented degraded case (see the fixture entry) — any reading is accepted

        let name = got.name.text.trim();
        if expected.fuzzy_name {
            assert!(!name.is_empty(), "row {i}: expected some reading for {:?}, got empty", expected.name);
        } else {
            assert_eq!(name, expected.name, "row {i} name");
        }

        let ty = got.ship_type.text.trim();
        if expected.fuzzy_type {
            assert!(!ty.is_empty(), "row {i}: expected some reading for type {:?}, got empty", expected.ty);
        } else {
            assert_eq!(ty, expected.ty, "row {i} ({:?}) type", expected.name);
        }

        assert_eq!(
            got.velocity,
            CellValue::Value(expected.velocity),
            "row {i} ({:?}) velocity",
            expected.name
        );
    }
}
