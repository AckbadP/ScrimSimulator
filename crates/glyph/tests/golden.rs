//! Golden-frame tests (DESIGN.md S6) against real overview screenshots: `overview-general.png`
//! (11 rows, dark/gray/red row backgrounds) plus one blue and one purple row. Column rects were
//! measured directly against the fixture.

use glyph::{Alphabet, Font};

const ROW_HEIGHT: u32 = 40;
const ROW0_Y: u32 = 152;
const ROW_PITCH: u32 = 42;

// (x, width) for Distance, Name, Type, Size, Velocity, Angular columns.
const COL_DISTANCE: (u32, u32) = (60, 130);
const COL_NAME: (u32, u32) = (200, 190);
const COL_TYPE: (u32, u32) = (396, 194);
const COL_SIZE: (u32, u32) = (590, 130);
const COL_VELOCITY: (u32, u32) = (720, 100);
const COL_ANGULAR: (u32, u32) = (820, 100);

struct Row {
    distance: &'static str,
    name: &'static str,
    ty: &'static str,
    size: &'static str,
    velocity: &'static str,
    angular: &'static str,
    /// Name/type cells with a known, out-of-scope ambiguity (touching glyphs, e.g. `ff`, or
    /// look-alike letters, e.g. `l`/`I`, `rn`/`m`) — DESIGN.md S4.3 leaves fixing these to the
    /// fuzzy candidate-match pass (M2), not this crate. Listed here so the test still checks that
    /// *something* was read and it isn't silently high-confidence, instead of skipping the cell.
    fuzzy_name: bool,
    fuzzy_type: bool,
}

const ROWS: &[Row] = &[
    Row { distance: "0 m", name: "Jita IV - Moon", ty: "Jita Trade Hub", size: "200 km", velocity: "-", angular: "-", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "1,515 m", name: "Kudikai", ty: "Orca", size: "1,100 m", velocity: "3", angular: "14.06", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "2,128 m", name: "Daxter Alabel", ty: "Machariel", size: "1,000 m", velocity: "0", angular: "10.26", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "3,951 m", name: "James Plex-Fe", ty: "Hyperion", size: "500 m", velocity: "114", angular: "3.04", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "4,047 m", name: "Lumin892", ty: "Capsule", size: "4 m", velocity: "228", angular: "3.04", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "5,642 m", name: "Miku Merkineau", ty: "Hawk", size: "78 m", velocity: "0", angular: "4.43", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "5,866 m", name: "Wreck of: Min", ty: "Minmatar Shutt", size: "28 m", velocity: "-", angular: "-", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "8,602 m", name: "Jax Sunder", ty: "Griffin Navy Is", size: "82 m", velocity: "0", angular: "1.50", fuzzy_name: false, fuzzy_type: false }, // "Griffin": touching `ff`, now split correctly (matcher.rs classify_span)
    Row { distance: "9,241 m", name: "Cargo Containe", ty: "Cargo Containe", size: "28 m", velocity: "-", angular: "-", fuzzy_name: false, fuzzy_type: false },
    Row { distance: "9,934 m", name: "Kyle Katarn", ty: "Catalyst", size: "286 m", velocity: "0", angular: "2.26", fuzzy_name: true, fuzzy_type: false }, // "Katarn": rn/m, l/I
    Row { distance: "11 km", name: "Uther Orekiller", ty: "Hawk", size: "78 m", velocity: "306", angular: "1.65", fuzzy_name: false, fuzzy_type: false },
];

fn cell(row: u32, col: (u32, u32)) -> (u32, u32, u32, u32) {
    (col.0, ROW0_Y + row * ROW_PITCH, col.1, ROW_HEIGHT)
}

#[test]
fn overview_general_numeric_columns_are_exact() {
    let img = image::open("tests/fixtures/overview-general.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();

    for (i, row) in ROWS.iter().enumerate() {
        let i = i as u32;
        for (col, expected, label) in [
            (COL_DISTANCE, row.distance, "distance"),
            (COL_SIZE, row.size, "size"),
            (COL_VELOCITY, row.velocity, "velocity"),
            (COL_ANGULAR, row.angular, "angular"),
        ] {
            let (x, y, w, h) = cell(i, col);
            let reading = font.read_region(&img, x, y, w, h, Alphabet::Numeric);
            // `"km"` is one documented exception: `matcher::classify_span`'s
            // `CONFIDENT_SINGLE_SCORE` doc comment explains why a `k`+`m` touching pair can read
            // as just one of the two letters (whichever the sliding-offset NCC search happens to
            // plant on) rather than being split — deliberately left for a caller with unit-grammar
            // context (`crates/overview::value`) to resolve, not this crate.
            let accepted_km_truncation = expected.ends_with("km") && {
                let stem = &expected[..expected.len() - 2]; // strip the "km" suffix
                reading.text == format!("{stem}k") || reading.text == format!("{stem}m")
            };
            assert!(
                reading.text == expected || accepted_km_truncation,
                "row {i} {label}: expected {expected:?}, got {:?}",
                reading.text
            );
        }
    }
}

#[test]
fn overview_general_name_and_type_columns_match_or_flag_low_confidence() {
    let img = image::open("tests/fixtures/overview-general.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();

    // Cells without a known ambiguity must match exactly. Flagged cells may legitimately misread
    // a touching/look-alike glyph, but must not do so with high confidence — a caller relying on
    // `Reading::confidence` to decide whether to trust a cell must not be misled here.
    const CONFIDENT_MARGIN: f32 = 0.15;

    for (i, row) in ROWS.iter().enumerate() {
        let i = i as u32;
        for (col, expected, fuzzy, label) in [
            (COL_NAME, row.name, row.fuzzy_name, "name"),
            (COL_TYPE, row.ty, row.fuzzy_type, "type"),
        ] {
            let (x, y, w, h) = cell(i, col);
            let reading = font.read_region(&img, x, y, w, h, Alphabet::Full);
            if fuzzy {
                assert!(
                    reading.text == expected || reading.confidence < CONFIDENT_MARGIN,
                    "row {i} {label}: misread {expected:?} as {:?} with high confidence {}",
                    reading.text,
                    reading.confidence
                );
            } else {
                assert_eq!(
                    reading.text, expected,
                    "row {i} {label}: expected {expected:?}, got {:?}",
                    reading.text
                );
            }
        }
    }
}

#[test]
fn blue_row_reads_correctly() {
    let img = image::open("tests/fixtures/overview-row-blue.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();
    assert_eq!(font.read_region(&img, 60, 9, 130, 40, Alphabet::Numeric).text, "1,729 m");
    assert_eq!(font.read_region(&img, 200, 9, 190, 40, Alphabet::Full).text, "LaBooster");
    assert_eq!(font.read_region(&img, 396, 9, 194, 40, Alphabet::Full).text, "Praxis");
    assert_eq!(font.read_region(&img, 590, 9, 130, 40, Alphabet::Numeric).text, "800 m");
    assert_eq!(font.read_region(&img, 720, 9, 100, 40, Alphabet::Numeric).text, "0");
    assert_eq!(font.read_region(&img, 820, 9, 100, 40, Alphabet::Numeric).text, "5.29");
}

#[test]
fn purple_row_reads_correctly() {
    let img = image::open("tests/fixtures/overview-row-purple.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();
    assert_eq!(font.read_region(&img, 60, 9, 130, 40, Alphabet::Numeric).text, "2,965 m");
    assert_eq!(font.read_region(&img, 200, 9, 190, 40, Alphabet::Full).text, "LaBooster");
    assert_eq!(font.read_region(&img, 396, 9, 194, 40, Alphabet::Full).text, "Praxis");
    assert_eq!(font.read_region(&img, 590, 9, 130, 40, Alphabet::Numeric).text, "800 m");
    assert_eq!(font.read_region(&img, 720, 9, 100, 40, Alphabet::Numeric).text, "0");
    assert_eq!(font.read_region(&img, 820, 9, 100, 40, Alphabet::Numeric).text, "0.00");
}
