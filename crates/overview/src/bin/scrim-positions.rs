//! Per-pilot position, speed and direction from a three-observer scrim recording. Every frame of
//! the video shows the three observers' overviews at once (an OBS scene described by a
//! `scene.json`, see `overview::panel`). Each panel is OCR'd and tracked independently, and the
//! per-observer tracks are merged into one roster by pilot name. Each pilot's three distances per
//! tick are then trilaterated (`overview::solve`): the observers sit on three unknown corners of a
//! 100 km cube that every pilot starts inside, and the corners are inferred from the data.
//! Speed is the overview's own Velocity column. Direction is the slope of the solved positions,
//! because the overview shows speed only as a scalar.

use anyhow::{bail, Context, Result};
use clap::Parser;
use glyph::Font;
use overview::layout::Layout;
use overview::panel::{calibrate, crop_scaled, PanelSpec, Scene};
use overview::row::{read_rows, RowReading};
use overview::solve::{self, direction, infer_corners, solve_track, Fix};
use overview::track::{hampel_flags, Sample, Track, Tracker, CAPSULE};
use overview::util::levenshtein;
use rayon::prelude::*;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(name = "scrim-positions", about = "OCR three observers' overviews into per-pilot positions")]
struct Cli {
    /// Scene config: each observer panel's rect (and optionally its calibrated scale).
    #[arg(long)]
    scene: PathBuf,
    /// Frames per second to sample (decoded by ffmpeg at this rate). 1 Hz matches DESIGN.md's
    /// tick rate.
    #[arg(long, default_value_t = 1.0)]
    fps: f64,
    /// Output directory for `<video>.positions.csv`.
    #[arg(long, default_value = "resouces/matches/out")]
    out: PathBuf,
    videos: Vec<PathBuf>,
}

/// How many leading frames to try calibrating on before giving up — the first frame of a match
/// can catch a panel mid-redraw.
const CALIBRATION_ATTEMPTS: usize = 10;

/// A per-observer track shorter than this fraction of the video's sampled frames, that matches
/// no roster pilot, is OCR noise (a badly misread name opening its own track) and is dropped.
const MIN_TRACK_FRACTION: f64 = 0.05;

/// Max edit distance between two observers' spellings of the same pilot. Looser than the
/// tracker's own within-observer tolerance (1): each observer reads the name at a different scale
/// and so settles on its own look-alike misread (`QIO`/`QJO`, `abcd1`/`abcdL`), and two such
/// independent single-glyph misreads put the canonical spellings 2 apart. Short names stay at 1
/// so two genuinely different short names can't merge.
fn roster_tolerance(name: &str) -> usize {
    if name.chars().count() >= 6 {
        2
    } else {
        1
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.videos.is_empty() {
        bail!("no videos given");
    }
    let scene = Scene::load(&cli.scene)
        .with_context(|| format!("loading scene {}", cli.scene.display()))?;
    if scene.panels.len() != 3 {
        bail!("scene has {} panels; trilateration needs exactly 3 observers", scene.panels.len());
    }
    let font = Font::builtin().context("training built-in font")?;
    std::fs::create_dir_all(&cli.out)
        .with_context(|| format!("creating {}", cli.out.display()))?;

    for video in &cli.videos {
        process_video(video, &scene, &font, cli.fps, &cli.out)
            .with_context(|| format!("processing {}", video.display()))?;
    }
    Ok(())
}

/// One observer panel, calibrated for this video.
struct Panel<'a> {
    spec: &'a PanelSpec,
    scale: f32,
    layout: Layout,
}

fn process_video(video: &Path, scene: &Scene, font: &Font, fps: f64, out: &Path) -> Result<()> {
    let started = std::time::Instant::now();
    let mut decoder = videoin::Decoder::open_with_fps(video, Some(fps))?;
    println!(
        "== {}: {}x{}, sampling at {fps} fps",
        video.display(),
        decoder.width,
        decoder.height
    );

    let mut pending = Vec::new();
    let panels = loop {
        let Some(frame) = decoder.next_frame()? else {
            bail!("video ended before every panel calibrated");
        };
        let attempt: Result<Vec<Panel>> = scene
            .panels
            .par_iter()
            .map(|spec| {
                let (scale, layout) = calibrate(&frame.image, spec, font)?;
                Ok(Panel { spec, scale, layout })
            })
            .collect();
        pending.push(frame);
        match attempt {
            Ok(p) => break p,
            Err(e) if pending.len() < CALIBRATION_ATTEMPTS => {
                eprintln!("  calibration failed on frame {}: {e:#}; retrying", pending.len() - 1);
            }
            Err(e) => return Err(e),
        }
    };
    for p in &panels {
        println!(
            "  panel {}: scale {:.4}, row pitch {:.2}",
            p.spec.name, p.scale, p.layout.row_pitch
        );
    }

    let mut trackers: Vec<Tracker> = panels.iter().map(|_| Tracker::new()).collect();
    let mut times = Vec::new();
    let batch_size = 2 * rayon::current_num_threads();
    loop {
        while pending.len() < batch_size {
            match decoder.next_frame()? {
                Some(f) => pending.push(f),
                None => break,
            }
        }
        if pending.is_empty() {
            break;
        }
        let jobs: Vec<(usize, usize)> = (0..pending.len())
            .flat_map(|f| (0..panels.len()).map(move |p| (f, p)))
            .collect();
        let rows: Vec<Vec<RowReading>> = jobs
            .par_iter()
            .map(|&(f, p)| {
                let panel = &panels[p];
                let crop = crop_scaled(&pending[f].image, panel.spec.rect, panel.scale);
                read_rows(&crop, &panel.layout, font)
            })
            .collect();
        for (&(f, p), r) in jobs.iter().zip(&rows) {
            trackers[p].observe(pending[f].t, r);
        }
        times.extend(pending.iter().map(|f| f.t));
        pending.clear();
        eprint!("\r  {} frames ({:.0}s of video)", times.len(), times.last().unwrap_or(&0.0));
    }
    eprintln!();

    let per_observer: Vec<Vec<Track>> = trackers.into_iter().map(Tracker::finish).collect();
    let names: Vec<&str> = panels.iter().map(|p| p.spec.name.as_str()).collect();
    let roster = build_roster(&per_observer, times.len());

    let readings: Vec<PilotReadings> =
        roster.iter().map(|p| pilot_readings(&per_observer, p, &times)).collect();
    let starts: Vec<[f64; 3]> = readings
        .iter()
        .flat_map(|r| r.distances.iter().take(CORNER_FIT_TICKS).map(|&(_, d)| d))
        .collect();
    if starts.is_empty() {
        bail!("no pilot was seen by all three observers in the same tick");
    }
    let fit = infer_corners(&starts);
    print_corners(&names, &fit);

    let solved: Vec<Vec<Fix>> =
        readings.iter().map(|r| solve_track(fit.corners, &r.distances)).collect();

    let stem = video.file_stem().unwrap_or_default().to_string_lossy();
    let path = out.join(format!("{stem}.positions.csv"));
    std::fs::write(&path, positions_csv(&per_observer, &roster, &readings, &solved))?;
    print_summary(&per_observer, &roster, &readings, &solved);
    println!(
        "  wrote {} ({} frames in {:.0}s)",
        path.display(),
        times.len(),
        started.elapsed().as_secs_f64()
    );
    Ok(())
}

/// How many of each pilot's earliest three-observer ticks feed corner inference. Pilots start
/// inside the cube, but later in a match they may not be.
const CORNER_FIT_TICKS: usize = 10;

/// How close (relative) the best other-shaped corner triple may score before the choice is
/// reported as ambiguous.
const CORNER_AMBIGUITY_RATIO: f64 = 1.5;

/// Seconds either side of a fix used to fit its direction.
const DIRECTION_HALF_WINDOW_S: f64 = 3.0;

fn print_corners(names: &[&str], fit: &solve::CornerFit) {
    let mut line = String::from("  observer corners (km):");
    for (n, c) in names.iter().zip(fit.corners) {
        let _ = write!(line, " {n}=({:.0},{:.0},{:.0})", c[0] / 1e3, c[1] / 1e3, c[2] / 1e3);
    }
    let _ = write!(line, "  fit cost {:.0} m, next shape {:.0} m", fit.score, fit.runner_up);
    println!("{line}");
    if fit.runner_up < fit.score * CORNER_AMBIGUITY_RATIO {
        eprintln!("  warning: corner choice is ambiguous; another observer layout fits almost as well");
    }
}

/// One pilot's per-tick inputs to the solve: the ticks where all three observers have an
/// unflagged distance, and the ticks with a usable speed.
struct PilotReadings {
    distances: Vec<(f64, [f64; 3])>,
    speed: BTreeMap<u64, f64>,
}

/// Collect a pilot's distance triples and speeds per tick. Speed is the median of the observers'
/// unflagged Velocity readings, because speed is the same whichever observer reads it.
fn pilot_readings(per_observer: &[Vec<Track>], pilot: &Pilot, times: &[f64]) -> PilotReadings {
    let dist: Vec<_> =
        (0..3).map(|o| observer_series(per_observer, pilot, o, |s| s.distance_m)).collect();
    let vel: Vec<_> =
        (0..3).map(|o| observer_series(per_observer, pilot, o, |s| s.speed_mps)).collect();
    let unflagged = |s: &BTreeMap<u64, (f64, bool)>, t: f64| {
        s.get(&t.to_bits()).filter(|(_, f)| !f).map(|&(v, _)| v)
    };
    let mut out = PilotReadings { distances: Vec::new(), speed: BTreeMap::new() };
    for &t in times {
        if let [Some(a), Some(b), Some(c)] = [0, 1, 2].map(|o| unflagged(&dist[o], t)) {
            out.distances.push((t, [a, b, c]));
        }
        let mut v: Vec<f64> = vel.iter().filter_map(|s| unflagged(s, t)).collect();
        if !v.is_empty() {
            v.sort_by(f64::total_cmp);
            let m = v.len() / 2;
            let median = if v.len() % 2 == 1 { v[m] } else { (v[m - 1] + v[m]) / 2.0 };
            out.speed.insert(t.to_bits(), median);
        }
    }
    out
}

/// One real pilot, merged across observers: which `(observer, track index)` pairs are theirs.
struct Pilot {
    name: String,
    members: Vec<(usize, usize)>,
}

/// Merge every observer's tracks into one roster by name. Longest tracks go first, so a pilot's
/// canonical name is its best-observed spelling, and the short splinter tracks a bad misread
/// opens (see `tests/video_sample.rs`) fold into an existing pilot instead of founding one.
fn build_roster(per_observer: &[Vec<Track>], n_frames: usize) -> Vec<Pilot> {
    let mut order: Vec<(usize, usize)> = per_observer
        .iter()
        .enumerate()
        .flat_map(|(o, tracks)| (0..tracks.len()).map(move |t| (o, t)))
        .collect();
    order.sort_by_key(|&(o, t)| std::cmp::Reverse(per_observer[o][t].samples.len()));

    let min_samples = ((n_frames as f64 * MIN_TRACK_FRACTION) as usize).max(3);
    let mut roster: Vec<Pilot> = Vec::new();
    for (o, t) in order {
        let track = &per_observer[o][t];
        let nearest = roster
            .iter_mut()
            .map(|p| (levenshtein(&p.name, &track.name), p))
            .filter(|(d, p)| *d <= roster_tolerance(&p.name))
            .min_by_key(|(d, _)| *d);
        match nearest {
            Some((_, pilot)) => pilot.members.push((o, t)),
            None if founds_pilot(track, min_samples) => roster.push(Pilot {
                name: track.name.clone(),
                members: vec![(o, t)],
            }),
            None => {} // OCR noise: too short to found a pilot, close to none
        }
    }
    roster.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    roster
}

/// Whether an unmatched track is real enough to be its own pilot: long enough, with enough
/// readable distances, and a name EVE could actually issue (3+ characters). Junk rows — e.g. a
/// lone `"j"` read off stray ink below the list — fail at least one of these.
fn founds_pilot(track: &Track, min_samples: usize) -> bool {
    let distances = track.samples.iter().filter(|s| s.distance_m.is_some()).count();
    track.name.chars().count() >= MIN_NAME_CHARS && distances >= min_samples
}

/// EVE character names are at least 3 characters long.
const MIN_NAME_CHARS: usize = 3;

/// Ship type for a pilot at time `t`: voted across their tracks by sample count, switching to
/// `Capsule` from the earliest pod any observer saw.
fn ship_type_at(per_observer: &[Vec<Track>], pilot: &Pilot, t: f64) -> String {
    let podded_at = pilot
        .members
        .iter()
        .filter_map(|&(o, i)| per_observer[o][i].capsule_events.first().copied())
        .fold(f64::INFINITY, f64::min);
    if t >= podded_at {
        return CAPSULE.to_string();
    }
    let mut votes: BTreeMap<&str, usize> = BTreeMap::new();
    for &(o, i) in &pilot.members {
        let tr = &per_observer[o][i];
        if let Some(ty) = tr.lost_ship.as_deref().or(tr.ship_type.as_deref()) {
            *votes.entry(ty).or_default() += tr.samples.len();
        }
    }
    votes
        .into_iter()
        .max_by_key(|&(_, n)| n)
        .map(|(ty, _)| ty.to_string())
        .unwrap_or_default()
}

/// One observer's series of one sample field (distance or speed) for a pilot: every member
/// track's samples from that observer, keyed by sample time (a splinter track only ever covers frames the main track missed — each
/// frame's row lands in exactly one track — so there is nothing to reconcile), with Hampel spike
/// flags.
fn observer_series(
    per_observer: &[Vec<Track>],
    pilot: &Pilot,
    observer: usize,
    field: impl Fn(&Sample) -> Option<f64>,
) -> BTreeMap<u64, (f64, bool)> {
    let mut by_t: BTreeMap<u64, f64> = BTreeMap::new();
    for &(o, i) in pilot.members.iter().filter(|m| m.0 == observer) {
        for s in &per_observer[o][i].samples {
            if let Some(d) = field(s) {
                by_t.entry(s.t.to_bits()).or_insert(d);
            }
        }
    }
    // f64 bit patterns sort like the values themselves for non-negative times.
    let values: Vec<Option<f64>> = by_t.values().map(|&d| Some(d)).collect();
    let flags = hampel_flags(&values, 5, 3.0);
    by_t.into_iter().zip(flags).map(|((t, d), f)| (t, (d, f))).collect()
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// One line per (tick, pilot) with a position fix. Speed is blank where no observer could read
/// it. Direction is blank where the ship is stationary or too few fixes surround the tick.
fn positions_csv(
    per_observer: &[Vec<Track>],
    roster: &[Pilot],
    readings: &[PilotReadings],
    solved: &[Vec<Fix>],
) -> String {
    let mut rows: Vec<(f64, String)> = Vec::new();
    for ((pilot, r), fixes) in roster.iter().zip(readings).zip(solved) {
        for (i, f) in fixes.iter().enumerate() {
            let mut line = format!(
                "{:.3},{},{},{:.0},{:.0},{:.0},",
                f.t,
                csv_field(&pilot.name),
                csv_field(&ship_type_at(per_observer, pilot, f.t)),
                f.p[0],
                f.p[1],
                f.p[2]
            );
            if let Some(v) = r.speed.get(&f.t.to_bits()) {
                let _ = write!(line, "{v}");
            }
            match direction(fixes, i, DIRECTION_HALF_WINDOW_S) {
                Some(d) => {
                    let _ = write!(line, ",{:.4},{:.4},{:.4}", d[0], d[1], d[2]);
                }
                None => line.push_str(",,,"),
            }
            let _ = writeln!(line, ",{:.0}", f.residual_m);
            rows.push((f.t, line));
        }
    }
    // Tick-major like the old wide CSV; the sort is stable, so pilots stay in roster order.
    rows.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out = String::from("t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m\n");
    out.extend(rows.into_iter().map(|(_, l)| l));
    out
}

fn median(mut v: Vec<f64>) -> Option<f64> {
    v.sort_by(f64::total_cmp);
    v.get(v.len() / 2).copied()
}

fn print_summary(
    per_observer: &[Vec<Track>],
    roster: &[Pilot],
    readings: &[PilotReadings],
    solved: &[Vec<Fix>],
) {
    println!(
        "\n  {:<22} {:<20} {:>5} {:>20} {:>9} {:>17}",
        "pilot", "type", "fixes", "start km (x,y,z)", "resid m", "speed med/max m/s"
    );
    for ((pilot, r), fixes) in roster.iter().zip(readings).zip(solved) {
        let start = fixes
            .first()
            .map(|f| format!("{:.0},{:.0},{:.0}", f.p[0] / 1e3, f.p[1] / 1e3, f.p[2] / 1e3))
            .unwrap_or_else(|| "-".into());
        let resid = median(fixes.iter().map(|f| f.residual_m).collect())
            .map_or("-".into(), |v| format!("{v:.0}"));
        let speeds: Vec<f64> = r.speed.values().copied().collect();
        let max = speeds.iter().copied().fold(f64::NAN, f64::max);
        let speed = median(speeds).map_or("-".into(), |m| format!("{m:.0}/{max:.0}"));
        println!(
            "  {:<22} {:<20} {:>5} {:>20} {:>9} {:>17}",
            pilot.name,
            ship_type_at(per_observer, pilot, f64::NEG_INFINITY),
            fixes.len(),
            start,
            resid,
            speed
        );
    }
    let n_tracks: usize = per_observer.iter().map(Vec::len).sum();
    let n_kept: usize = roster.iter().map(|p| p.members.len()).sum();
    println!("  ({} of {n_tracks} per-observer tracks merged into {} pilots; rest dropped as noise)", n_kept, roster.len());
}
