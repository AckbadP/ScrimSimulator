//! Minimal ffmpeg-piped frame decode (DESIGN.md S8 `videoin`, S1 "decode and time base").
//!
//! No native ffmpeg linking: this shells out to the `ffmpeg`/`ffprobe` binaries already required
//! to *produce* a scrim recording (OBS uses the same libraries), and reads raw RGB24 frames off
//! ffmpeg's stdout pipe. `t` is presentation time in seconds (currently `index / fps`; mapping
//! that to wall-clock game time via the in-frame EVE clock, per DESIGN.md S1, is a later pass —
//! nothing here depends on this being exact).

use anyhow::{bail, ensure, Context, Result};
use image::RgbImage;
use std::io::Read;
use std::process::{Child, ChildStdout, Command, Stdio};

/// One decoded video frame.
pub struct Frame {
    /// 0-based frame index in decode order.
    pub index: u64,
    /// Presentation time in seconds, `index / fps`.
    pub t: f64,
    pub image: RgbImage,
}

/// Streams frames out of a video file by shelling out to `ffmpeg`.
pub struct Decoder {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    child: Child,
    stdout: ChildStdout,
    index: u64,
    buf: Vec<u8>,
    done: bool,
}

/// The subset of `ffprobe -show_streams -of json`'s output this crate reads.
#[derive(serde::Deserialize)]
struct ProbeOutput {
    streams: Vec<ProbeStream>,
}

#[derive(serde::Deserialize)]
struct ProbeStream {
    width: Option<u32>,
    height: Option<u32>,
    r_frame_rate: Option<String>,
}

fn parse_frame_rate(s: &str) -> Result<f64> {
    match s.split_once('/') {
        Some((num, den)) => {
            let num: f64 = num.parse().context("parsing r_frame_rate numerator")?;
            let den: f64 = den.parse().context("parsing r_frame_rate denominator")?;
            ensure!(den != 0.0, "r_frame_rate denominator is zero");
            Ok(num / den)
        }
        None => s.parse().context("parsing r_frame_rate"),
    }
}

/// Probe a video's first video stream for width/height/fps via `ffprobe`.
fn probe(path: &std::path::Path) -> Result<(u32, u32, f64)> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate",
            "-of",
            "json",
        ])
        .arg(path)
        .output()
        .context("running ffprobe (is it installed and on PATH?)")?;
    ensure!(
        output.status.success(),
        "ffprobe failed on {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let parsed: ProbeOutput =
        serde_json::from_slice(&output.stdout).context("parsing ffprobe JSON output")?;
    let stream = parsed
        .streams
        .first()
        .context("ffprobe reported no video stream")?;
    let width = stream.width.context("ffprobe stream has no width")?;
    let height = stream.height.context("ffprobe stream has no height")?;
    let fps = parse_frame_rate(
        stream
            .r_frame_rate
            .as_deref()
            .context("ffprobe stream has no r_frame_rate")?,
    )?;
    Ok((width, height, fps))
}

impl Decoder {
    /// Open a video file, probing its dimensions/framerate and starting an `ffmpeg` process that
    /// streams raw RGB24 frames on stdout.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Decoder> {
        Decoder::open_with_fps(path, None)
    }

    /// Like [`Decoder::open`], but resampled by ffmpeg to `fps` frames per second (`None`: the
    /// source rate). Sampling a long recording at a few Hz this way avoids piping every
    /// full-resolution frame only to discard most of them; `Frame::t` is then `index / fps`.
    pub fn open_with_fps(path: impl AsRef<std::path::Path>, fps: Option<f64>) -> Result<Decoder> {
        let path = path.as_ref();
        let (width, height, src_fps) = probe(path)?;
        if let Some(f) = fps {
            ensure!(f > 0.0, "fps must be positive, got {f}");
        }

        let mut cmd = Command::new("ffmpeg");
        cmd.args(["-v", "error", "-i"]).arg(path).args(["-map", "0:v:0"]);
        if let Some(f) = fps {
            cmd.args(["-vf", &format!("fps={f}")]);
        }
        let mut child = cmd
            .args(["-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("spawning ffmpeg (is it installed and on PATH?)")?;
        let stdout = child.stdout.take().expect("stdout was piped");

        Ok(Decoder {
            width,
            height,
            fps: fps.unwrap_or(src_fps),
            child,
            stdout,
            index: 0,
            buf: vec![0u8; width as usize * height as usize * 3],
            done: false,
        })
    }

    /// Read the next frame, or `None` at end of stream.
    pub fn next_frame(&mut self) -> Result<Option<Frame>> {
        if self.done {
            return Ok(None);
        }
        match self.stdout.read_exact(&mut self.buf) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                self.done = true;
                self.check_exit_status()?;
                return Ok(None);
            }
            Err(e) => return Err(e).context("reading frame from ffmpeg stdout"),
        }
        let image = RgbImage::from_raw(self.width, self.height, self.buf.clone())
            .context("frame buffer size did not match width*height*3")?;
        let frame = Frame {
            index: self.index,
            t: self.index as f64 / self.fps,
            image,
        };
        self.index += 1;
        Ok(Some(frame))
    }

    fn check_exit_status(&mut self) -> Result<()> {
        let status = self.child.wait().context("waiting for ffmpeg to exit")?;
        if !status.success() {
            let mut stderr = String::new();
            if let Some(mut s) = self.child.stderr.take() {
                let _ = s.read_to_string(&mut stderr);
            }
            bail!("ffmpeg exited with {status}: {stderr}");
        }
        Ok(())
    }
}

impl Iterator for Decoder {
    type Item = Result<Frame>;

    fn next(&mut self) -> Option<Result<Frame>> {
        self.next_frame().transpose()
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // Best-effort: don't leave a decode process running if the caller stops early.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_rate_parsing() {
        assert_eq!(parse_frame_rate("60/1").unwrap(), 60.0);
        assert_eq!(parse_frame_rate("30000/1001").unwrap(), 30000.0 / 1001.0);
        assert_eq!(parse_frame_rate("25").unwrap(), 25.0);
    }
}
