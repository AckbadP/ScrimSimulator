//! Multi-observer scene test (`overview::panel`): one native-resolution frame from a real match
//! recording (`resouces/matches/match_03.mkv` @ 60s; scene config copied from that directory's
//! `scene.json`) showing three observers' overviews at three different UI scales. Guards the
//! resample-to-reference-pitch step that lets the single-panel pipeline read all three.

use overview::layout::REF_ROW_PITCH;
use overview::panel::{calibrate, crop_scaled, Scene};
use overview::row::read_rows;
use overview::util::levenshtein;

const SCENE: &str = "tests/fixtures/scene-match03.json";
const FRAME: &str = "tests/fixtures/scene-match03-60s.png";

/// `(panel, pilot, ship type, distance in m)`, read by eye off the fixture frame.
const EXPECTED: &[(&str, &str, &str, f64)] = &[
    ("A", "Pilot One", "Geri", 90_000.0),
    ("A", "Tormund Vasquet", "Deimos", 121_000.0),
    ("A", "Pilot Two", "Astarte", 93_000.0),
    ("A", "Pilot Eleven", "Vigil", 119_000.0),
    ("B", "Pilot One", "Geri", 84_000.0),
    ("B", "Low Tide", "Deacon", 112_000.0),
    ("B", "Pilot Three", "Punisher", 101_000.0),
    ("C", "Pilot One", "Geri", 101_000.0),
    ("C", "Selka Varn", "Ashimmu", 49_000.0),
    ("C", "Pilot Three", "Punisher", 58_000.0),
];

#[test]
fn reads_all_three_observers_at_their_own_scales() {
    let scene = Scene::load(SCENE).unwrap();
    let frame = image::open(FRAME).unwrap().to_rgb8();
    let font = glyph::Font::builtin().unwrap();

    for spec in &scene.panels {
        let (scale, layout) = calibrate(&frame, spec, &font).unwrap();
        assert!(
            (layout.row_pitch - REF_ROW_PITCH).abs() < 1.0,
            "panel {}: calibrated pitch {} (scale {scale}) not near reference",
            spec.name,
            layout.row_pitch
        );
        let crop = crop_scaled(&frame, spec.rect, scale);
        let rows = read_rows(&crop, &layout, &font);
        eprintln!("panel {} scale {scale:.3}: {} rows", spec.name, rows.len());
        for r in &rows {
            eprintln!("  {:?} | {:?} | {:?}", r.distance, r.name.text, r.ship_type.text);
        }

        for &(_, pilot, ship, dist) in EXPECTED.iter().filter(|e| e.0 == spec.name) {
            let row = rows
                .iter()
                .find(|r| levenshtein(&r.name.text, pilot) <= 1)
                .unwrap_or_else(|| panic!("panel {}: no row for {pilot}", spec.name));
            assert!(
                levenshtein(&row.ship_type.text, ship) <= 1,
                "panel {}: {pilot} type read as {:?}",
                spec.name,
                row.ship_type.text
            );
            assert_eq!(row.distance.ok(), Some(dist), "panel {}: {pilot} distance", spec.name);
        }
    }
}
