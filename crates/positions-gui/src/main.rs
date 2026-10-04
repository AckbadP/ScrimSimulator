//! A window for running `scrim-positions` on one recording: pick the video, the observer's Local
//! chat log, the output folder, optionally the gamelogs of the pilots in the match, and whether
//! to save the audio. The
//! choices are remembered between sessions (eframe's app storage). The tool runs as a child
//! process found next to this executable (or on `PATH`), and its output is shown as it runs.

#![cfg_attr(windows, windows_subsystem = "windows")]

use eframe::egui;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};

const SETTINGS_KEY: &str = "settings";

/// Everything the user picks; persisted between sessions.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct Settings {
    video: String,
    chat_log: String,
    out_dir: String,
    /// Gamelogs to attach to the match.
    combat_log_files: Vec<String>,
    /// Where the combat log picker opens: the folder of the last logs picked.
    combat_log_dir: String,
    extract_audio: bool,
    scene: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            video: String::new(),
            chat_log: String::new(),
            out_dir: String::new(),
            combat_log_files: Vec::new(),
            combat_log_dir: default_gamelogs().map(path_string).unwrap_or_default(),
            extract_audio: true,
            scene: default_scene().map(path_string).unwrap_or_default(),
        }
    }
}

fn path_string(p: PathBuf) -> String {
    p.to_string_lossy().into_owned()
}

/// EVE's gamelogs folder in the user's Documents, if it exists.
fn default_gamelogs() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?;
    let dir = Path::new(&home).join("Documents/EVE/logs/Gamelogs");
    dir.is_dir().then_some(dir)
}

/// How a gamelog is shown in the list: its character and session start (from the header), since
/// the file names are only a date and a character ID.
fn gamelog_label(path: &str) -> String {
    let file = Path::new(path).file_name().unwrap_or_default().to_string_lossy().into_owned();
    let mut head = Vec::new();
    let read = std::fs::File::open(path).and_then(|f| f.take(4096).read_to_end(&mut head));
    if let Err(e) = read {
        return format!("{file}  ({e})");
    }
    let head = String::from_utf8_lossy(&head);
    let field = |key: &str| {
        head.lines().find_map(|l| l.trim().strip_prefix(key).map(|v| v.trim().to_owned()))
    };
    match (field("Listener:"), field("Session Started:")) {
        (Some(who), Some(when)) => format!("{who}  ·  {when}  ·  {file}"),
        (Some(who), None) => format!("{who}  ·  {file}"),
        _ => format!("{file}  (not an EVE gamelog)"),
    }
}

/// `scene.json` next to this executable (as in the release zip), else the source tree's.
fn default_scene() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok()?.parent()?.join("scene.json");
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/obs/scene.json");
    [beside, source].into_iter().find(|p| p.is_file()).map(|p| p.canonicalize().unwrap_or(p))
}

/// The `scrim-positions` executable next to this one, else whatever `PATH` finds.
fn scrim_positions() -> PathBuf {
    let name = format!("scrim-positions{}", std::env::consts::EXE_SUFFIX);
    std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.join(&name)))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from(name))
}

/// A piece of the child's output: a finished line, or a `\r`-terminated progress line that the
/// next piece replaces.
enum Output {
    Line(String),
    Progress(String),
}

/// Forward `pipe` to `tx` split into lines, waking the UI for each.
fn forward(mut pipe: impl Read + Send + 'static, tx: Sender<Output>, ctx: egui::Context) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let mut line = Vec::new();
        while let Ok(n @ 1..) = pipe.read(&mut buf) {
            for &b in &buf[..n] {
                if b != b'\n' && b != b'\r' {
                    line.push(b);
                    continue;
                }
                let text = String::from_utf8_lossy(&line).into_owned();
                line.clear();
                let msg = if b == b'\n' { Output::Line(text) } else { Output::Progress(text) };
                if tx.send(msg).is_err() {
                    return;
                }
            }
            ctx.request_repaint();
        }
        if !line.is_empty() {
            let _ = tx.send(Output::Line(String::from_utf8_lossy(&line).into_owned()));
        }
        ctx.request_repaint();
    });
}

struct Run {
    child: Child,
    output: Receiver<Output>,
}

struct App {
    settings: Settings,
    run: Option<Run>,
    log: Vec<String>,
    /// The last log line is a progress line, replaced by the next output.
    progress: bool,
    /// `gamelog_label` of each combat log, read once.
    labels: HashMap<String, String>,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        let settings = cc
            .storage
            .and_then(|s| eframe::get_value(s, SETTINGS_KEY))
            .unwrap_or_default();
        Self { settings, run: None, log: Vec::new(), progress: false, labels: HashMap::new() }
    }

    fn push(&mut self, out: Output) {
        let (text, progress) = match out {
            Output::Line(t) => (t, false),
            Output::Progress(t) => (t, true),
        };
        // `\r\n` arrives as an empty line after the progress line it ends.
        if self.progress && text.is_empty() && !progress {
            self.progress = false;
            return;
        }
        if self.progress {
            self.log.pop();
        }
        self.log.push(text);
        self.progress = progress;
    }

    /// What's missing before a run can start, if anything.
    fn missing(&self) -> Option<&'static str> {
        let s = &self.settings;
        if s.video.trim().is_empty() {
            Some("Pick a video.")
        } else if s.out_dir.trim().is_empty() {
            Some("Pick an output folder.")
        } else if s.scene.trim().is_empty() {
            Some("Pick a scene file.")
        } else {
            None
        }
    }

    fn start(&mut self, ctx: &egui::Context) {
        let s = &self.settings;
        let exe = scrim_positions();
        let mut cmd = Command::new(&exe);
        cmd.arg("--scene").arg(s.scene.trim()).arg("--out").arg(s.out_dir.trim());
        if !s.chat_log.trim().is_empty() {
            cmd.arg("--chat-log").arg(s.chat_log.trim());
        }
        if !s.extract_audio {
            cmd.arg("--no-audio");
        }
        for log in &s.combat_log_files {
            cmd.arg("--combat-log").arg(log);
        }
        cmd.arg(s.video.trim()).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        self.log.clear();
        self.progress = false;
        self.log.push(format!("$ {cmd:?}"));
        match cmd.spawn() {
            Ok(mut child) => {
                let (tx, rx) = channel();
                forward(child.stdout.take().unwrap(), tx.clone(), ctx.clone());
                forward(child.stderr.take().unwrap(), tx, ctx.clone());
                self.run = Some(Run { child, output: rx });
            }
            Err(e) => self.log.push(format!("Cannot start {}: {e}", exe.display())),
        }
    }

    /// Drain the running child's output and notice when it exits.
    fn poll(&mut self) {
        let Some(run) = &mut self.run else { return };
        let pending: Vec<Output> = run.output.try_iter().collect();
        let status = run.child.try_wait();
        for out in pending {
            self.push(out);
        }
        let done = match status {
            Ok(Some(status)) if status.success() => Some("Done.".to_owned()),
            Ok(Some(status)) => Some(format!("Failed ({status}).")),
            Ok(None) => None,
            Err(e) => Some(format!("Lost the process: {e}")),
        };
        if let Some(msg) = done {
            // Output written just before exit may still be in the pipe threads.
            if let Some(run) = self.run.take() {
                for out in run.output.iter() {
                    self.push(out);
                }
            }
            self.push(Output::Line(msg));
        }
    }
}

/// A labelled path field with a "Browse…" button that opens `pick`.
fn path_row(
    ui: &mut egui::Ui,
    label: &str,
    value: &mut String,
    hint: &str,
    pick: impl FnOnce(rfd::FileDialog) -> Option<PathBuf>,
) {
    ui.label(label);
    ui.horizontal(|ui| {
        let browse = ui.button("Browse…");
        let field = egui::TextEdit::singleline(value).hint_text(hint);
        ui.add_sized([ui.available_width(), ui.spacing().interact_size.y], field);
        if browse.clicked() {
            let mut dialog = rfd::FileDialog::new();
            if let Some(dir) = Path::new(value.trim()).parent().filter(|d| d.is_dir()) {
                dialog = dialog.set_directory(dir);
            }
            if Path::new(value.trim()).is_dir() {
                dialog = dialog.set_directory(value.trim());
            }
            if let Some(p) = pick(dialog) {
                *value = path_string(p);
            }
        }
    });
    ui.end_row();
}

/// The combat logs list: one row per gamelog (its character, session start and file name) with a
/// remove button, and buttons to add more or clear them.
fn combat_logs_ui(ui: &mut egui::Ui, s: &mut Settings, labels: &mut HashMap<String, String>) {
    ui.horizontal(|ui| {
        ui.label("Combat logs");
        if ui.button("Add logs…").clicked() {
            let mut dialog = rfd::FileDialog::new()
                .set_title("Gamelogs of the pilots in the match")
                .add_filter("Gamelog", &["txt"]);
            if Path::new(&s.combat_log_dir).is_dir() {
                dialog = dialog.set_directory(&s.combat_log_dir);
            }
            for p in dialog.pick_files().unwrap_or_default() {
                if let Some(dir) = p.parent() {
                    s.combat_log_dir = path_string(dir.to_path_buf());
                }
                let p = path_string(p);
                if !s.combat_log_files.contains(&p) {
                    s.combat_log_files.push(p);
                }
            }
        }
        if ui.add_enabled(!s.combat_log_files.is_empty(), egui::Button::new("Clear")).clicked() {
            s.combat_log_files.clear();
        }
        ui.weak("optional: each pilot's gamelog; ones with no combat in the match are skipped");
    });
    let mut remove = None;
    egui::ScrollArea::vertical().id_salt("combat_logs").max_height(120.0).show(ui, |ui| {
        for (i, path) in s.combat_log_files.iter().enumerate() {
            ui.horizontal(|ui| {
                if ui.small_button("🗙").on_hover_text("Remove").clicked() {
                    remove = Some(i);
                }
                let label = labels.entry(path.clone()).or_insert_with(|| gamelog_label(path));
                ui.label(label.as_str()).on_hover_text(path);
            });
        }
    });
    if let Some(i) = remove {
        s.combat_log_files.remove(i);
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll();
        let running = self.run.is_some();

        egui::TopBottomPanel::top("settings").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.add_enabled_ui(!running, |ui| {
                let s = &mut self.settings;
                egui::Grid::new("paths").num_columns(2).spacing([8.0, 6.0]).show(ui, |ui| {
                    path_row(ui, "Video", &mut s.video, "recorded match (.mkv, .mp4, …)", |d| {
                        d.add_filter("Video", &["mkv", "mp4", "mov", "webm", "flv", "avi"])
                            .add_filter("All files", &["*"])
                            .pick_file()
                    });
                    path_row(ui, "Chat log", &mut s.chat_log, "optional: Local chat log, finds the match and EVE times", |d| {
                        d.add_filter("Chat log", &["txt"]).pick_file()
                    });
                    path_row(ui, "Output folder", &mut s.out_dir, "where the CSV (and audio, logs) go", |d| {
                        d.pick_folder()
                    });
                    path_row(ui, "Scene", &mut s.scene, "scene.json: where each overview is in the frame", |d| {
                        d.add_filter("Scene", &["json"]).pick_file()
                    });
                    ui.label("");
                    ui.checkbox(&mut s.extract_audio, "Extract audio (<video>.mp3 next to the CSV)");
                    ui.end_row();
                });
                ui.add_space(4.0);
                combat_logs_ui(ui, s, &mut self.labels);
                if !s.combat_log_files.is_empty() && s.chat_log.trim().is_empty() {
                    ui.colored_label(
                        ui.visuals().warn_fg_color,
                        "Combat logs need EVE times, which come from the chat log.",
                    );
                }
            });
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                if running {
                    ui.spinner();
                    if ui.button("Cancel").clicked() {
                        if let Some(run) = &mut self.run {
                            let _ = run.child.kill();
                        }
                    }
                } else {
                    let missing = self.missing();
                    let run = ui.add_enabled(missing.is_none(), egui::Button::new("Run"));
                    if let Some(why) = missing {
                        ui.label(why);
                    }
                    if run.clicked() {
                        self.start(ctx);
                    }
                }
            });
            ui.add_space(6.0);
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::both().stick_to_bottom(true).auto_shrink(false).show(ui, |ui| {
                for line in &self.log {
                    ui.label(egui::RichText::new(line).monospace());
                }
            });
        });
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, SETTINGS_KEY, &self.settings);
    }
}

impl Drop for App {
    /// Closing the window stops a run in progress.
    fn drop(&mut self) {
        if let Some(run) = &mut self.run {
            let _ = run.child.kill();
        }
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Scrim Positions")
            .with_inner_size([820.0, 560.0]),
        ..Default::default()
    };
    eframe::run_native(
        "scrim-positions-gui",
        options,
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    )
}
