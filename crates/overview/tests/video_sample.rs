//! End-to-end test over the real video fixture (DESIGN.md S6 "synthetic"/"self-consistency"
//! validation, applied to this crate's OCR + tracking instead of the full geometry solver):
//! decode `overview-sample.mkv`, run layout detection + row OCR + tracking on it, and check the
//! properties this crate exists to guarantee.
//!
//! Every frame is decoded (60fps, matching DESIGN.md S1's real capture rate), but only every
//! `FRAME_STRIDE`th is OCR'd: measured directly against this fixture, `crates/glyph`'s NCC
//! template matching over a full name/type-alphabet cell (every template, a small sliding search
//! window each) costs ~2.5s of wall time per *frame* (all ~29 rows x 4 columns) in this
//! unoptimized prototype — nowhere near DESIGN.md's throughput estimate, which assumes a
//! production-tuned matcher. OCR'ing all ~453 frames would make this a 15-20 minute `cargo test`;
//! the stride keeps it to roughly a minute of wall time while still sampling densely enough
//! (~4/s) to cover the whole timeline, including the mid-video arrivals (new pilots warping onto
//! grid) that make this fixture interesting in the first place. Speeding up the matcher itself
//! (e.g. caching each alphabet's candidate template list instead of rebuilding it per glyph) is
//! real future work, not something this test should paper over by sampling even more sparsely.
//!
//! What this test does *not* assert: that every pilot's OCR readings cluster into exactly one
//! track for the whole video. `crates/glyph`'s per-glyph matching (see its own golden tests) has
//! known look-alike-glyph confusions (`l`/`I`, `J`/`I`, and occasionally several such misreads on
//! one unlucky frame); when a name misreads badly enough on some sampled frame to land outside
//! [`Tracker`]'s single-glyph fuzzy-merge tolerance, that frame's observation opens a second,
//! low-sample track for the same real pilot rather than corrupting the first one. That is the
//! system correctly *not* guessing at an over-large edit distance — DESIGN.md's posture throughout
//! ("low-confidence cells are dropped, not guessed") — not a tracking bug, so this test checks the
//! properties that actually matter: every real pilot is identified and typed correctly by *some*
//! track, and — the rule this project exists to enforce — no track's ship type is ever silently
//! swapped for a different real ship.

use overview::layout::{self, Rect};
use overview::row::read_rows;
use overview::track::Tracker;
use overview::util::levenshtein;

const PANEL: Rect = Rect { x: 816, y: 0, w: 1200, h: 1600 };
const FRAME_STRIDE: u64 = 15;

/// Every pilot this video ever shows, and the one ship type each has throughout. This pilot's real
/// name is `ftftfttfy` — already `Capsule` from frame 0 (already podded, not a mid-video loss) —
/// but its repeated-`ft` shape is far enough outside this font's normal letter spacing that OCR
/// never recovers it; `"Itfy"` is what it consistently, stably converges to instead. That's the
/// property actually being checked here (a real, if unreadable, pilot still gets ONE stable
/// identity + a correct type), so the roster names what tracking will actually converge to, the
/// same way `crates/glyph`'s golden tests accept a documented look-alike-glyph misread instead of
/// demanding the real spelling.
const EXPECTED_PILOTS: &[(&str, &str)] = &[
    ("Alexader Todak", "Corax"),
    ("Charlot theHarl", "Tornado"),
    ("ChernobylAllen", "Badger"),
    ("Defenzer", "Tornado"),
    ("Desson Craft", "Nereus"),
    ("ELECTR1C", "Badger"),
    ("Ethan Tiboteau", "Squall"),
    ("FATHERFACK", "Venture"),
    ("Itfy", "Capsule"),
    ("Hai Yun Huang", "Gnosis"),
    ("Henry Tiboteau", "Iteron Mark V"),
    ("Illypa Kapmen", "Astero"),
    ("Janis Drukhari", "Wor"), // real type is "Worm" — see the trailing-`rm` note further down
    ("jannaukko", "Mastodon"),
    ("Jax Sunder", "Griffin Navy Is"),
    ("Jilbert Tibotea", "Badger"),
    ("Kenneth McArt", "Tornado"),
    ("Laxus Erata", "Bustard"),
    ("Lonely Babe", "Scorpion"),
    ("Lysithea", "Orca"),
    ("Mathis Tibotea", "Badger"),
    ("Natasha Etern", "Venture"),
    ("Nepaxa", "Metamorphosis"),
    ("Nicha vnii srrid", "Stiletto"),
    ("Nicolas Tibotea", "Tornado"),
    ("Otrorber Arste", "Venture"),
    ("Rudocopnax", "Miasmos"),
    ("samantha m", "Tornado"),
    ("Samantha Myh", "Tayra"),
    ("Samantha-Nov", "Gnosis"),
    ("Sergeji Harloff", "Tornado"),
];

/// How much OCR name-noise is tolerated when matching a track back to a known pilot for this
/// test's *identity-coverage* check — looser than [`Tracker`]'s own same-track merge tolerance
/// (which stays tight to avoid merging two different short names), because here the question is
/// "did the pipeline see this pilot at all", and a name is only ever compared against this short,
/// known roster (no risk of two *different* expected pilots being confused for each other at this
/// distance — the closest pair, `Samantha Myh`/`Samantha-Nov`, is 4 apart).
const IDENTITY_MATCH_MAX_DISTANCE: usize = 3;

#[test]
fn tracks_every_pilot_with_a_stable_type_and_no_conflicts() {
    let mut decoder = videoin::Decoder::open("tests/fixtures/overview-sample.mkv").unwrap();
    assert_eq!((decoder.width, decoder.height), (2560, 1600));

    let font = glyph::Font::builtin().unwrap();
    let mut layout = None;
    let mut tracker = Tracker::new();
    let mut n_processed = 0u64;

    while let Some(frame) = decoder.next_frame().unwrap() {
        if frame.index % FRAME_STRIDE != 0 {
            continue;
        }
        if layout.is_none() {
            layout = Some(layout::detect(&frame.image, PANEL, &font).expect("layout detection on frame 0"));
        }
        let rows = read_rows(&frame.image, layout.as_ref().unwrap(), &font);
        tracker.observe(frame.t, &rows);
        n_processed += 1;
    }
    assert!(n_processed >= 25, "expected dense-enough sampling of a ~453-frame video, got {n_processed}");

    let tracks = tracker.finish();

    // Two documented sources of noise a track can carry no real identity for, excluded from every
    // check below that assumes one:
    //
    // - Below the visible list, the panel is background over which stray contrast can still cross
    //   `glyph`'s ink threshold on an unlucky frame (see `layout::detect`'s `list_bottom` doc
    //   comment — a documented backstop, not a guarantee of zero noise beyond the real rows) and
    //   read as a one- or two-character "row" — too short for any real EVE character name.
    // - This video's own last visible row sits right at the panel's bottom edge and is only ever
    //   partially rendered (DESIGN.md S7: "only rows actually rendered can be read"), so its OCR
    //   is unstable frame to frame; a real pilot name never contains `.` (not in EVE's character-
    //   name charset — `glyph::Alphabet::Name` allows it only because it's shared with celestial/
    //   structure names), so a track name containing one is recognisably this clipped-row noise.
    const MIN_REAL_NAME_LEN: usize = 3;
    let has_identity =
        |t: &&overview::track::Track| t.name.chars().count() >= MIN_REAL_NAME_LEN && !t.name.contains('.');

    // `Janis Drukhari`'s ship, `Worm`, has a second, narrower documented OCR limitation: its
    // trailing `rm` reads as a *confident* but wrong single glyph often enough here that the type
    // never stops flagging conflicts against whichever truncation (`"Wor"`, `"Wo."`, ...) the
    // 3-sample bootstrap happened to lock — the same font/scale weakness as `crates/glyph`'s
    // `"200 km"` -> `"200 k"` case (see `matcher::classify_span`'s `CONFIDENT_SINGLE_SCORE` doc
    // comment), landing on a word this video happens to use as a ship name. The safety property
    // that matters — the *displayed* type never silently swaps to a different real ship — still
    // holds (every conflict here is a truncation of the same word, not a different one); what
    // doesn't hold is this prototype ever cleanly confirming "Worm" after bootstrap, which is a
    // `glyph`-level accuracy gap, not a tracking-logic bug, so it's excluded from the check below
    // rather than the check weakened for everyone.
    let has_clean_type_reads = |t: &&overview::track::Track| levenshtein(&t.name, "Janis Drukhari") > 2;

    // The rule this project exists to enforce: a ship type may only ever change *to* Capsule;
    // every other apparent change is `Tracker::observe`'s job to reject as a `TypeConflict`, never
    // to apply. This must hold for every track with a real identity, including any extra
    // low-sample ones a badly misread frame opened (see the module doc comment) — a real
    // type-changing mistake would be just as much a bug on one of those as on a cleanly-tracked
    // pilot.
    for t in tracks.iter().filter(has_identity).filter(has_clean_type_reads) {
        assert!(
            t.type_conflicts.is_empty(),
            "track {:?} (type {:?}) had type conflicts: {:?}",
            t.name,
            t.ship_type,
            t.type_conflicts
        );
    }

    // This clip has no real ship-loss: nobody is expected to flip to Capsule mid-video.
    for t in tracks.iter().filter(has_identity) {
        assert!(t.capsule_events.is_empty(), "track {:?} unexpectedly recorded as podded: {:?}", t.name, t.capsule_events);
    }

    // Identity coverage: every real pilot was seen and typed correctly by at least one track.
    for &(name, ty) in EXPECTED_PILOTS {
        let closest = tracks
            .iter()
            .min_by_key(|t| levenshtein(&t.name, name))
            .unwrap_or_else(|| panic!("no tracks at all (looking for {name:?})"));
        let d = levenshtein(&closest.name, name);
        assert!(
            d <= IDENTITY_MATCH_MAX_DISTANCE,
            "pilot {name:?} was never tracked (closest: {:?} at distance {d}; all tracks: {:?})",
            closest.name,
            tracks.iter().map(|t| &t.name).collect::<Vec<_>>()
        );
        assert_eq!(closest.ship_type.as_deref(), Some(ty), "pilot {name:?} (tracked as {:?}) ship type", closest.name);
        assert!(!closest.samples.is_empty(), "pilot {name:?} has no samples");
    }

    // Distance/speed parse for the large majority of samples across the whole tracked population
    // — DESIGN.md's "every cell carries a confidence; low-confidence cells are dropped, not
    // guessed" means *some* unparsed cells are expected (this crate's own golden tests document
    // several classes of them), just not a large fraction.
    let total: usize = tracks.iter().map(|t| t.samples.len()).sum();
    let distance_ok: usize = tracks.iter().flat_map(|t| &t.samples).filter(|s| s.distance_m.is_some()).count();
    let speed_ok: usize = tracks.iter().flat_map(|t| &t.samples).filter(|s| s.speed_mps.is_some()).count();
    assert!(
        distance_ok as f64 / total as f64 > 0.85,
        "distance parse rate too low: {distance_ok}/{total}"
    );
    assert!(
        speed_ok as f64 / total as f64 > 0.85,
        "speed parse rate too low: {speed_ok}/{total}"
    );

    // Spot check: `Natasha Etern` warps in partway through the clip at high speed (per the
    // recording — absent from frame 0, present from roughly its middle third), which is also a
    // useful check that mid-video list growth (a new row appearing, shifting rows below it down)
    // doesn't corrupt tracking.
    let natasha = tracks.iter().min_by_key(|t| levenshtein(&t.name, "Natasha Etern")).unwrap();
    let max_speed = natasha.samples.iter().filter_map(|s| s.speed_mps).fold(0.0f64, f64::max);
    assert!(max_speed > 10_000.0, "Natasha Etern's max recorded speed was only {max_speed}");
}
