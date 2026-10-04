//! Draco decoding for the simulator's ship models. Godot's glTF importer has no
//! `KHR_draco_mesh_compression` support, so models are rewritten with plain accessors once, when
//! they are downloaded.

/// Returns `glb` (GLB or glTF bytes) as a GLB with every Draco primitive decoded.
pub fn undraco(glb: &[u8]) -> Result<Vec<u8>, draco_gltf::Error> {
    let mut scene = draco_gltf::parse(glb, draco_gltf::ValidationProfile::Gltf20)?;
    scene.decompress_in_place()?;
    scene.to_bytes(draco_gltf::OutputFormat::GlbV2)
}
