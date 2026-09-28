//! Dev CLI for the `glyph` crate: read a rectangle out of an image, or dump the trained
//! templates as PNGs for eyeballing.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use glyph::{Alphabet, Font};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "glyph", about = "EVE overview glyph OCR — dev tool")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// OCR a rectangle of an image against the built-in font.
    Read {
        image: PathBuf,
        /// "x,y,w,h" in pixels.
        #[arg(long)]
        rect: String,
        #[arg(long, value_enum, default_value = "full")]
        alphabet: AlphabetArg,
    },
    /// Write each trained template glyph as its own PNG (coverage as grayscale) for inspection.
    DumpTemplates {
        #[arg(long)]
        out: PathBuf,
    },
}

#[derive(Clone, clap::ValueEnum)]
enum AlphabetArg {
    Full,
    Numeric,
}

fn parse_rect(s: &str) -> Result<(u32, u32, u32, u32)> {
    let parts: Vec<u32> = s
        .split(',')
        .map(|p| p.trim().parse::<u32>())
        .collect::<Result<_, _>>()
        .context("--rect must be \"x,y,w,h\" of integers")?;
    match parts[..] {
        [x, y, w, h] => Ok((x, y, w, h)),
        _ => anyhow::bail!("--rect must be \"x,y,w,h\""),
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let font = Font::builtin().context("training built-in font")?;

    match cli.cmd {
        Cmd::Read {
            image,
            rect,
            alphabet,
        } => {
            let (x, y, w, h) = parse_rect(&rect)?;
            let img = image::open(&image)
                .with_context(|| format!("opening {}", image.display()))?
                .to_rgb8();
            let alphabet = match alphabet {
                AlphabetArg::Full => Alphabet::Full,
                AlphabetArg::Numeric => Alphabet::Numeric,
            };
            let reading = font.read_region(&img, x, y, w, h, alphabet);
            println!("text: {:?}", reading.text);
            println!("confidence: {:.3}", reading.confidence);
            for c in &reading.chars {
                println!("  {:?}  score={:.3}  margin={:.3}", c.ch, c.score, c.margin);
            }
        }
        Cmd::DumpTemplates { out } => {
            std::fs::create_dir_all(&out)?;
            for (i, t) in font.templates().iter().enumerate() {
                let mut img = image::GrayImage::new(t.width as u32, t.height as u32);
                for yy in 0..t.height {
                    for xx in 0..t.width {
                        let v = (t.data[yy * t.width + xx] * 255.0) as u8;
                        img.put_pixel(xx as u32, yy as u32, image::Luma([v]));
                    }
                }
                let name = format!("{:03}_{}.png", i, sanitize(t.ch));
                img.save(out.join(name))?;
            }
            println!("wrote {} templates to {}", font.templates().len(), out.display());
        }
    }
    Ok(())
}

fn sanitize(ch: char) -> String {
    if ch.is_ascii_alphanumeric() {
        ch.to_string()
    } else {
        format!("u{:04x}", ch as u32)
    }
}
