//! Dev CLI (DESIGN.md S8 `scrim-recorder inspect`-style tool, scoped to this crate): OCR every
//! frame of a video's overview and print each pilot's tracked ship type and distance/speed
//! series.

use anyhow::{Context, Result};
use clap::Parser;
use glyph::Font;
use overview::layout::{self, Rect};
use overview::track::{hampel_flags, Tracker};
use overview::row::read_rows;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "overview-track", about = "OCR an overview video into per-pilot tracks")]
struct Cli {
    video: PathBuf,
    /// Write every (track, t, distance_m, speed_mps) sample to this CSV path.
    #[arg(long)]
    csv: Option<PathBuf>,
    /// Overview panel rectangle to search for the header/table, as "x,y,w,h" in pixels. Real
    /// usage takes this from DESIGN.md's S0 layout calibration (a one-time-per-OBS-scene ROI);
    /// lacking that here, it defaults to the right half of the frame, where EVE's overview is
    /// conventionally docked.
    #[arg(long)]
    panel: Option<String>,
}

fn parse_panel(s: &str) -> Result<Rect> {
    let parts: Vec<u32> = s
        .split(',')
        .map(|p| p.trim().parse::<u32>())
        .collect::<std::result::Result<_, _>>()
        .context("--panel must be \"x,y,w,h\" of integers")?;
    match parts[..] {
        [x, y, w, h] => Ok(Rect { x, y, w, h }),
        _ => anyhow::bail!("--panel must be \"x,y,w,h\""),
    }
}

fn median(values: &[f64]) -> f64 {
    let mut v = values.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let font = Font::builtin().context("training built-in font")?;

    let mut decoder = videoin::Decoder::open(&cli.video)
        .with_context(|| format!("opening {}", cli.video.display()))?;
    println!(
        "{}: {}x{} @ {:.3} fps",
        cli.video.display(),
        decoder.width,
        decoder.height,
        decoder.fps
    );

    let panel = match &cli.panel {
        Some(s) => parse_panel(s)?,
        None => Rect {
            x: decoder.width / 2,
            y: 0,
            w: decoder.width - decoder.width / 2,
            h: decoder.height,
        },
    };

    let mut tracker = Tracker::new();
    let mut layout = None;
    let mut n_frames = 0u64;
    while let Some(frame) = decoder.next_frame()? {
        if layout.is_none() {
            layout = Some(
                layout::detect(&frame.image, panel, &font)
                    .context("detecting overview layout on frame 0")?,
            );
            println!("layout detected: {:#?}", layout.as_ref().unwrap());
        }
        let rows = read_rows(&frame.image, layout.as_ref().unwrap(), &font);
        tracker.observe(frame.t, &rows);
        n_frames += 1;
    }
    println!("processed {n_frames} frames");

    let tracks = tracker.finish();

    if let Some(csv_path) = &cli.csv {
        let mut out = String::from("pilot,t,distance_m,speed_mps\n");
        for t in &tracks {
            for s in &t.samples {
                out.push_str(&format!(
                    "{},{},{},{}\n",
                    t.name,
                    s.t,
                    s.distance_m.map(|v| v.to_string()).unwrap_or_default(),
                    s.speed_mps.map(|v| v.to_string()).unwrap_or_default(),
                ));
            }
        }
        std::fs::write(csv_path, out)
            .with_context(|| format!("writing {}", csv_path.display()))?;
        println!("wrote {}", csv_path.display());
    }

    println!(
        "\n{:<24} {:<10} {:>6} {:>8} {:>28} {:>28}",
        "pilot", "type", "n", "conflict", "distance (min/med/max, m)", "speed (min/med/max, m/s)"
    );
    for t in &tracks {
        let dist: Vec<f64> = t.samples.iter().filter_map(|s| s.distance_m).collect();
        let dist_flags = hampel_flags(
            &t.samples.iter().map(|s| s.distance_m).collect::<Vec<_>>(),
            5,
            3.0,
        );
        let speed: Vec<f64> = t.samples.iter().filter_map(|s| s.speed_mps).collect();
        let speed_flags = hampel_flags(
            &t.samples.iter().map(|s| s.speed_mps).collect::<Vec<_>>(),
            5,
            3.0,
        );
        let n_spikes = dist_flags.iter().filter(|&&f| f).count()
            + speed_flags.iter().filter(|&&f| f).count();

        let dist_summary = if dist.is_empty() {
            "-".to_string()
        } else {
            format!(
                "{:.0} / {:.0} / {:.0}",
                dist.iter().cloned().fold(f64::INFINITY, f64::min),
                median(&dist),
                dist.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
            )
        };
        let speed_summary = if speed.is_empty() {
            "-".to_string()
        } else {
            format!(
                "{:.1} / {:.1} / {:.1}",
                speed.iter().cloned().fold(f64::INFINITY, f64::min),
                median(&speed),
                speed.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
            )
        };

        println!(
            "{:<24} {:<10} {:>6} {:>8} {:>28} {:>28}",
            t.name,
            t.ship_type.as_deref().unwrap_or("?"),
            t.samples.len(),
            t.type_conflicts.len(),
            dist_summary,
            speed_summary,
        );
        for ev in &t.capsule_events {
            println!("  -> podded at t={ev:.1}s");
        }
        for c in &t.type_conflicts {
            println!(
                "  ! type conflict at t={:.1}s: expected {:?}, read {:?}",
                c.t, c.from, c.read_as
            );
        }
        if n_spikes > 0 {
            println!("  ({n_spikes} Hampel-flagged spike(s))");
        }
    }

    Ok(())
}
