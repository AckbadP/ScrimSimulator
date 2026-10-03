//! The Mobile Micro Jump Unit from EVE_Model_Gallery: Draco geometry and webp textures.

use serde_json::Value;

fn json_chunk(glb: &[u8]) -> Value {
    assert_eq!(&glb[0..4], b"glTF");
    let len = u32::from_le_bytes(glb[12..16].try_into().unwrap()) as usize;
    serde_json::from_slice(&glb[20..20 + len]).unwrap()
}

fn names(v: &Value) -> Vec<&str> {
    v.as_array().map_or(vec![], |a| a.iter().filter_map(Value::as_str).collect())
}

#[test]
fn decodes_draco_primitives() {
    let input = std::fs::read("tests/fixtures/mobile-micro-jump-unit.glb").unwrap();
    assert!(names(&json_chunk(&input)["extensionsRequired"]).contains(&"KHR_draco_mesh_compression"));

    let out = glb_undraco::undraco(&input).unwrap();
    let json = json_chunk(&out);
    for key in ["extensionsUsed", "extensionsRequired"] {
        assert!(!names(&json[key]).contains(&"KHR_draco_mesh_compression"), "{key}");
    }
    // Textures are left alone; Godot reads EXT_texture_webp itself.
    assert!(names(&json["extensionsRequired"]).contains(&"EXT_texture_webp"));
    for prim in json["meshes"][0]["primitives"].as_array().unwrap() {
        assert!(prim.get("extensions").and_then(|e| e.get("KHR_draco_mesh_compression")).is_none());
        let pos = &json["accessors"][prim["attributes"]["POSITION"].as_u64().unwrap() as usize];
        assert!(pos["count"].as_u64().unwrap() > 0);
        let idx = &json["accessors"][prim["indices"].as_u64().unwrap() as usize];
        assert!(idx["count"].as_u64().unwrap() > 0);
    }
}

#[test]
fn rejects_garbage() {
    assert!(glb_undraco::undraco(b"not a glb").is_err());
}
