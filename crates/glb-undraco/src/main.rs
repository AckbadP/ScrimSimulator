//! `glb-undraco <in.glb> <out.glb>`: decodes Draco-compressed meshes so Godot can load the model.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: glb-undraco <in.glb> <out.glb>");
        return ExitCode::from(2);
    }
    let result = std::fs::read(&args[1])
        .map_err(|e| e.to_string())
        .and_then(|bytes| glb_undraco::undraco(&bytes).map_err(|e| e.to_string()))
        .and_then(|out| std::fs::write(&args[2], out).map_err(|e| e.to_string()));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("glb-undraco: {}: {e}", args[1]);
            ExitCode::FAILURE
        }
    }
}
