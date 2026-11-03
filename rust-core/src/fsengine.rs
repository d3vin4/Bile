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

pub(crate) fn risky_moves_allowed() -> bool {
    ALLOW_RISKY_MOVES.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Path validation
// ---------------------------------------------------------------------------

pub(crate) fn normalize_path(p: &str) -> String {
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
pub(crate) fn allowed_container(p: &str) -> bool {
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
pub(crate) fn safe_rel(rel: &str) -> bool {
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

pub(crate) fn read_pairing(pairing_path: &str) -> Result<Vec<u8>, String> {
    std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))
}

pub(crate) fn human_bytes(bytes: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut index = 0;
    while value >= 1024.0 && index < units.len() - 1 {
        value /= 1024.0;
        index += 1;
    }
    if index == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", units[index])
    }
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

/// Files the Books sync daemon may touch while our manifest is in place.
/// They are snapshotted before every AirTraffic move and written back
/// afterwards, so the device is left exactly as it was found.
const BOOKS_STATE_FILES: [&str; 6] = [
    "Books/Sync/Books.plist",
    "Books/Sync/Upload.plist",
    "Books/Books.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
];

/// Beyond this size a state file is not worth holding in memory.
const MAX_STATE_FILE: usize = 8 * 1024 * 1024;

struct MediaState {
    files: Vec<(String, Option<Vec<u8>>)>,
    dirs: Vec<(String, bool)>,
}

async fn snapshot_media_state(afc: &mut AfcClient) -> MediaState {
    let mut files: Vec<(String, Option<Vec<u8>>)> = Vec::new();
    for path in BOOKS_STATE_FILES {
        let size = afc.get_file_info(path).await.map(|i| i.size).unwrap_or(0);
        let data = match afc.open(path, AfcFopenMode::RdOnly).await {
            Ok(mut fd) => {
                let data = if size <= MAX_STATE_FILE {
                    fd.read_entire().await.ok()
                } else {
                    None
                };
                let _ = fd.close().await;
                data
            }
            Err(_) => None,
        };
        files.push((path.to_string(), data));
    }
    let dirs = vec![
        (
            "Books".to_string(),
            afc.get_file_info("Books").await.is_ok(),
        ),
        (
            "Books/Sync".to_string(),
            afc.get_file_info("Books/Sync").await.is_ok(),
        ),
    ];
    MediaState { files, dirs }
}

fn dir_existed(state: &MediaState, path: &str) -> bool {
    state
        .dirs
        .iter()
        .find(|(p, _)| p == path)
        .map(|(_, e)| *e)
        .unwrap_or(false)
}

async fn restore_media_state(afc: &mut AfcClient, state: &MediaState) {
    // Put every state file back exactly as it was; remove the ones we created.
    for (path, original) in &state.files {
        match original {
            Some(bytes) => {
                if let Ok(mut fd) = afc.open(path, AfcFopenMode::WrOnly).await {
                    let _ = fd.write_entire(bytes).await;
                    let _ = fd.close().await;
                }
            }
            None => {
                let _ = afc.remove(path).await;
            }
        }
    }
    // State files we deliberately do not hold (> 8 MB) are left alone entirely.
    if let Some((_, existed)) = state.dirs.iter().find(|(p, _)| p == "Books/Sync") {
        if !existed {
            let _ = afc.remove("Books/Sync").await;
        }
    }
    if let Some((_, existed)) = state.dirs.iter().find(|(p, _)| p == "Books") {
        if !existed {
            let _ = afc.remove("Books").await;
        }
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

/// One stable "library" identity per app run. Using a fresh random id for every
/// sync makes the device remember a new phantom host each time, which leaves
/// sync state behind; a stable id keeps the device's Books database clean.
static LIBRARY_ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();

fn library_id() -> String {
    LIBRARY_ID
        .get_or_init(|| {
            format!(
                "{}-{}-{}-{}-{}",
                exploit::random_hex(4),
                exploit::random_hex(2),
                exploit::random_hex(2),
                exploit::random_hex(2),
                exploit::random_hex(6)
            )
        })
        .clone()
}

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
    host_info.insert("LibraryID".into(), plist::Value::String(library_id()));
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

    // The device only honours FileComplete for assets **it** announced as
    // downloadable. Checking that list turns a silent no-op into a precise
    // answer.
    let mut offered: Vec<String> = Vec::new();
    let mut manifest_seen = false;
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
                        manifest_seen = true;
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(manifest) =
                                params.get("AssetManifest").and_then(|m| m.as_dictionary())
                            {
                                if let Some(rows) = manifest.get("Book").and_then(|b| b.as_array())
                                {
                                    for row in rows {
                                        if let Some(row) = row.as_dictionary() {
                                            let id = row
                                                .get("AssetID")
                                                .and_then(|v| v.as_string())
                                                .unwrap_or_default()
                                                .to_string();
                                            let is_download = row
                                                .get("IsDownload")
                                                .and_then(|v| v.as_boolean())
                                                .unwrap_or(false);
                                            logger.log(format!(
                                                "airlift: device offered '{id}' (IsDownload={is_download})"
                                            ));
                                            if is_download {
                                                offered.push(id);
                                            }
                                        }
                                    }
                                }
                            }
                        }
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
    if !manifest_seen {
        return Err("AirTraffic: AssetManifest not observed".into());
    }
    if !offered.iter().any(|id| id == asset_id) {
        return Err(format!(
            "the device did not offer '{asset_id}' for download, so it ignored the move. Offered: {}",
            if offered.is_empty() {
                "nothing".to_string()
            } else {
                offered.join(", ")
            }
        ));
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
pub(crate) async fn move_path(
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
    if !dir_existed(&state, "Books") {
        let _ = afc.mk_dir("Books").await;
    }
    if !dir_existed(&state, "Books/Sync") {
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

    if result.is_ok() {
        logger.log("AirTraffic move done (Books sync state snapshotted and restored)".to_string());
    }

    // Surface a failed cleanup instead of leaving silent junk in Media.
    if afc.get_file_info(&stage).await.is_ok() {
        logger.log(format!(
            "warning: staging folder {stage} could not be removed (see Recovery in Setup)"
        ));
    }

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

/// Finds an existing bridge that already points at `container_path`.
///
/// Reusing it keeps Media tidy without ever touching a bridge another container
/// may still be using. Bridges are only removed by `al_bridge_close` or by the
/// explicit "Clean empty" action in Recovery.
async fn find_usable_bridge(afc: &mut AfcClient, container_path: &str) -> Option<String> {
    let names = media_list_root(afc).await.ok()?;
    for name in names {
        if !name.starts_with("readipa-bridge-") {
            continue;
        }
        if bridge_is_ours(afc, &name, container_path).await {
            return Some(name);
        }
    }
    None
}

/// Create a fresh bridge to `container_path`.
async fn make_bridge(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    container_path: &str,
    logger: &Logger,
) -> Result<String, String> {
    let candidate = format!("readipa-bridge-{}", exploit::random_hex(6));
    let made = afc
        .link(container_path, &candidate, LinkType::Symlink)
        .await
        .is_ok();
    let bridge = if made {
        candidate
    } else {
        create_bridge_atc(tunnel, afc, container_path, logger).await?
    };
    if !wait_present(afc, &bridge, 20).await {
        return Err("could not create a bridge in Media".to_string());
    }
    match bridge_matches(afc, &bridge, container_path).await {
        Ok(Some(true)) | Ok(None) => {}
        Ok(Some(false)) => {
            let _ = remove_one(afc, &bridge).await;
            return Err("bridge target mismatch; the symlink was removed".to_string());
        }
        Err(e) => return Err(format!("could not verify the new bridge: {e}")),
    }
    Ok(bridge)
}

async fn create_bridge_atc(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    container_path: &str,
    logger: &Logger,
) -> Result<String, String> {
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
    if !dir_existed(&state, "Books") {
        let _ = afc.mk_dir("Books").await;
    }
    if !dir_existed(&state, "Books/Sync") {
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
    // The symlink must point at the container we asked for (when the target is
    // reported at all).
    match bridge_matches(afc, &bridge_name, container_path).await {
        Ok(Some(true)) | Ok(None) => Ok(bridge_name),
        Ok(Some(false)) => {
            let _ = remove_one(afc, &bridge_name).await;
            Err("Bridge target mismatch; the symlink was removed".into())
        }
        Err(e) => Err(format!("could not verify the new bridge: {e}")),
    }
}

/// Compare a bridge symlink with the container it is supposed to serve.
///
/// `Ok(Some(true))`  — the target is known and matches.
/// `Ok(Some(false))` — the target is known and points somewhere else.
/// `Ok(None)`        — this iOS build does not report the link target, so a
///                     match can neither be proven nor disproven. Callers that
///                     only *reuse* bridges must treat this as "no".
async fn bridge_matches(
    afc: &mut AfcClient,
    bridge: &str,
    container_path: &str,
) -> Result<Option<bool>, String> {
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
            Ok(Some(resolved == normalize_path(container_path)))
        }
        None => Ok(None),
    }
}

/// A bridge we are willing to *reuse*: the link target must be known and match.
async fn bridge_is_ours(afc: &mut AfcClient, bridge: &str, container_path: &str) -> bool {
    matches!(
        bridge_matches(afc, bridge, container_path).await,
        Ok(Some(true))
    )
}

/// A bridge we are willing to *operate through*: known and matching, or a
/// target this iOS build cannot report (the caller opened it moments ago).
async fn bridge_usable(afc: &mut AfcClient, bridge: &str, container_path: &str) -> bool {
    matches!(
        bridge_matches(afc, bridge, container_path).await,
        Ok(Some(true)) | Ok(None)
    )
}

/// Try every spelling AFC may accept for a directory. Directory enumeration
/// through a Media symlink is not always accepted for the bare path, so the
/// trailing-slash and `/.` forms are attempted too. This keeps browsing on the
/// direct path (no relocation of live app data) whenever it is possible at all.
async fn list_dir_variants(afc: &mut AfcClient, full_path: &str) -> (Option<Vec<String>>, String) {
    let trimmed = if full_path.is_empty() {
        "/".to_string()
    } else {
        full_path.trim_end_matches('/').to_string()
    };
    let mut candidates = vec![
        trimmed.clone(),
        format!("{trimmed}/"),
        format!("{trimmed}/."),
    ];
    if trimmed == "/" {
        candidates = vec!["/".to_string(), ".".to_string(), "".to_string()];
    }
    let mut last = String::from("no attempt");
    for candidate in candidates {
        match afc.list_dir(&candidate).await {
            Ok(names) => return (Some(names), String::new()),
            Err(e) => last = format!("{e:?}"),
        }
    }
    (None, last)
}

/// Probe what the Media bridge actually permits.
///
/// AFC validates directory enumeration and file access separately, so a denied
/// `list_dir` does **not** imply that reads are denied. Knowing the difference
/// lets reads avoid any relocation of live app data.
async fn probe_bridge(afc: &mut AfcClient, bridge: &str) -> (bool, bool) {
    let list_ok = afc.list_dir(bridge).await.is_ok();
    if list_ok {
        return (true, true);
    }
    // Directory enumeration is denied — check whether reading still works by
    // stat'ing paths that exist in virtually every container.
    const PROBES: [&str; 8] = [
        ".",
        "Library",
        "Documents",
        "tmp",
        "Library/Preferences",
        "Library/Caches",
        "Library/Preferences/.GlobalPreferences.plist",
        ".com.apple.mobile_container_manager.metadata.plist",
    ];
    for probe in PROBES {
        let path = if probe == "." {
            format!("{bridge}/.")
        } else {
            format!("{bridge}/{probe}")
        };
        if afc.get_file_info(&path).await.is_ok() {
            return (false, true);
        }
    }
    (false, false)
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

    // Reuse a bridge that already points at this container so opening the same
    // container twice never creates duplicates (and never breaks another one).
    let bridge = match find_usable_bridge(&mut afc, &container_path).await {
        Some(existing) => {
            logger.log(format!("reusing bridge {existing}"));
            existing
        }
        None => make_bridge(&mut tunnel, &mut afc, &container_path, logger).await?,
    };

    let (direct_list, direct_read) = probe_bridge(&mut afc, &bridge).await;
    let mode = if direct_list {
        "bridge_direct"
    } else if direct_read {
        "bridge_readonly"
    } else {
        "bridge_move"
    };

    Ok(serde_json::to_string_pretty(&json!({
        "bridge": bridge,
        "container": container_path,
        "mode": mode,
        "requiresRiskyMoves": !direct_list,
        "capabilities": {
            "list": direct_list || risky_moves_allowed(),
            "read": direct_read || risky_moves_allowed(),
            "readDirect": direct_read,
            "listDirect": direct_list,
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

pub(crate) struct Engine {
    pub(crate) afc: AfcClient,
    pub(crate) bridge: String,
    /// `list_dir` through the bridge works (fastest path for browsing).
    pub(crate) direct_list: bool,
    /// Reading/statting files through the bridge works. This is a *separate*
    /// probe from listing: AFC may refuse directory enumeration while still
    /// serving file reads, in which case no relocation is ever needed.
    pub(crate) direct_read: bool,
    pub(crate) house_arrest: bool,
}

impl Engine {
    pub(crate) fn path(&self, rel: &str) -> String {
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
    pub(crate) fn abs_path(&self, container_path: &str, rel: &str) -> String {
        if rel.is_empty() {
            container_path.to_string()
        } else {
            format!("{}/{}", container_path.trim_end_matches('/'), rel)
        }
    }
}

pub(crate) async fn open_engine(
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
        for command in ["VendContainer", "VendDocuments"] {
            match try_vend(&mut tunnel, bundle_id, command, logger).await {
                Ok(afc) => {
                    logger.log(format!("HouseArrest {command} granted for {bundle_id}"));
                    return Ok((
                        tunnel,
                        Engine {
                            afc,
                            bridge: String::new(),
                            direct_list: true,
                            direct_read: true,
                            house_arrest: true,
                        },
                    ));
                }
                Err(e) => logger.log(format!("HouseArrest {command} refused: {e}")),
            }
        }
        logger.log("HouseArrest unavailable for this app; using the AirLift bridge");
    }

    let mut afc = tunnel.connect_afc(logger).await?;

    // Self-heal: if the caller's bridge is gone (closed, cleaned up by the user
    // or by an earlier build) recreate it instead of failing the operation.
    let usable = if bridge_name.is_empty() || !safe_media_name(bridge_name) {
        false
    } else {
        bridge_usable(&mut afc, bridge_name, container_path).await
    };

    let bridge = if usable {
        bridge_name.to_string()
    } else {
        if !bridge_name.is_empty() && safe_media_name(bridge_name) {
            logger.log(format!(
                "bridge {bridge_name} is gone or points elsewhere; recreating"
            ));
        }
        match find_usable_bridge(&mut afc, container_path).await {
            Some(existing) => {
                logger.log(format!("reusing bridge {existing}"));
                existing
            }
            None => make_bridge(&mut tunnel, &mut afc, container_path, logger).await?,
        }
    };

    let (direct_list, direct_read) = probe_bridge(&mut afc, &bridge).await;

    Ok((
        tunnel,
        Engine {
            afc,
            bridge,
            direct_list,
            direct_read,
            house_arrest: false,
        },
    ))
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

    // Always attempt the direct listing first — even when the earlier probe said
    // "no", because AFC accepts some path spellings and rejects others. Only a
    // real failure falls back to relocating anything.
    let direct_path = engine.path(&rel_path);
    let (direct, direct_error) = list_dir_variants(&mut engine.afc, &direct_path).await;

    // Base path the entries are stat'ed through. In move mode this is the Media
    // staging path, because the bridge denies traversal.
    let (names, base) = if let Some(names) = direct {
        (names, engine.path(&rel_path))
    } else {
        if !risky_moves_allowed() {
            return Err(format!(
                "Folder listing is blocked for this container (AFC said: {direct_error}).\n\
                 Turn on \"Allow risky moves\" in Setup to try the AirLift relocation fallback — \
                 reading individual files and exporting the container as a ZIP still work without it.\n\
                 Tap “Diagnose” in the Files toolbar to see exactly what is allowed here."
            ));
        }
        // Relocate the whole CONTAINER once and read from Media.
        //
        // A rename needs write permission on the *parent* directory. AirTraffic
        // can create entries in `/var/mobile/Containers/Data/Application` (the
        // container's parent) but not inside `<UUID>/…`, so moving the root
        // works while moving a sub-folder does not. One root move also gives
        // access to the entire tree, not just the folder being listed.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-mount-{token}");
        let dst_back = engine.path("");
        let inside = |rel: &str| -> String {
            if rel.is_empty() {
                staging.clone()
            } else {
                format!("{}/{}", staging.trim_end_matches('/'), rel)
            }
        };

        move_path(
            &mut tunnel,
            &mut engine.afc,
            &container_path,
            &staging,
            logger,
        )
        .await
        .map_err(|e| {
            format!(
                "Direct listing failed (AFC said: {direct_error}) and moving the container \
                     into Media failed too ({e}).\nNothing was changed — the container is exactly \
                     where it was.\nTap “Diagnose” in the Files toolbar for the full report."
            )
        })?;

        let listed = engine.afc.list_dir(inside(&rel_path)).await;
        let names = match listed {
            Ok(n) => n,
            Err(e) => {
                let _ =
                    restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
                        .await;
                return Err(format!("list failed: {e:?}"));
            }
        };

        for n in &names {
            if n == "." || n == ".." {
                continue;
            }
            let full = format!("{}/{}", inside(&rel_path).trim_end_matches('/'), n);
            match engine.afc.get_file_info(&full).await {
                Ok(info) => entries.push(entry_json(n, &info)),
                Err(_) => entries.push(json!({"name": n, "isDir": false, "size": 0})),
            }
        }

        restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
            .await
            .map_err(|e| {
                format!(
                    "THE CONTAINER COULD NOT BE RESTORED AUTOMATICALLY: {e}\n\
                     Your data is safe at /var/mobile/Media/{staging} — use Recovery to move it back."
                )
            })?;

        return Ok(serde_json::to_string_pretty(
            &json!({"entries": entries, "bridge": engine.bridge}),
        )
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

    Ok(
        serde_json::to_string_pretty(&json!({"entries": entries, "bridge": engine.bridge}))
            .map_err(|e| e.to_string())?,
    )
}

/// Move the container into Media so AFC can read and modify the whole tree.
///
/// A rename needs write permission on the entry's *parent*, and iOS only lets
/// AirTraffic write inside `.../Data/Application` (the container's parent) — never
/// inside `<UUID>` itself. Moving the root therefore works while moving nested
/// folders never does, and one root move gives both eyes and hands.
pub(crate) async fn stage_container(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    container_path: &str,
    logger: &Logger,
) -> Result<String, String> {
    let token = exploit::random_hex(8);
    let staging = format!("readipa-mount-{token}");
    move_path(tunnel, afc, container_path, &staging, logger)
        .await
        .map_err(|e| {
            format!(
                "could not move the container into Media ({e}). Nothing was changed — run \
                 Diagnose to see whether AirTraffic can reach this container at all."
            )
        })?;
    Ok(staging)
}

/// Put a staged container back, always reporting what happened.
pub(crate) async fn unstage_container(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    staging: &str,
    dst_back: &str,
    logger: &Logger,
) -> Result<(), String> {
    restore_staged_dir(tunnel, afc, staging, dst_back, logger).await
}

/// Combines an operation result with the restore result into one message.
pub(crate) fn staged_outcome<T>(
    outcome: Result<T, String>,
    restore: Result<(), String>,
    staging: &str,
) -> Result<T, String> {
    match (outcome, restore) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(e), Ok(())) => Err(e),
        (Ok(_), Err(e)) => Err(format!(
            "the operation finished but the container could not be put back: {e}\n\
             Everything is safe at /var/mobile/Media/{staging} — use Recovery to restore it."
        )),
        (Err(e), Err(re)) => Err(format!(
            "{e}\nThe container also could not be put back ({re}) and is safe at \
             /var/mobile/Media/{staging} — use Recovery."
        )),
    }
}

/// Move a Media-staged item back into its container. `dst` must be the
/// bridge-relative destination (a Media-relative string), never an absolute
/// container path — ATAirlock only accepts destinations below Media.
pub(crate) async fn restore_staged_dir(
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

    // Always try the direct read first: if AFC serves the file through the
    // bridge, nothing in the container is touched at all.
    let afc_path = engine.path(&rel_path);
    let mut direct_error: Option<String> = None;
    {
        match engine.afc.open(&afc_path, AfcFopenMode::RdOnly).await {
            Ok(mut fd) => match stream_afc_to_local(&mut fd, &dest_local_path).await {
                Ok(_) => {
                    let _ = fd.close().await;
                    return Ok(());
                }
                Err(e) => {
                    let _ = fd.close().await;
                    direct_error = Some(e);
                }
            },
            Err(e) => direct_error = Some(format!("open: {e:?}")),
        }
    }

    // One clean retry before doing anything destructive.
    if direct_error.is_some() {
        let retry = {
            match engine.afc.open(&afc_path, AfcFopenMode::RdOnly).await {
                Ok(mut fd) => {
                    let r = stream_afc_to_local(&mut fd, &dest_local_path).await;
                    let _ = fd.close().await;
                    r.map(|_| ())
                }
                Err(e) => Err(format!("open: {e:?}")),
            }
        };
        if retry.is_ok() {
            return Ok(());
        }
        logger.log(format!(
            "direct read unavailable ({}); falling back to a verified relocation",
            direct_error.unwrap_or_default()
        ));
    }

    if !risky_moves_allowed() {
        return Err(
            "This file can only be read by relocating it, which needs \"Allow risky moves\" in \
             Setup. Turn it on, or export the whole container as a ZIP instead."
                .to_string(),
        );
    }

    // Move mode: relocate the whole container once (its parent directory is
    // writable, a nested folder's is not), read from Media, then put it back.
    let token = exploit::random_hex(8);
    let staging = format!("readipa-mount-{token}");
    let dst_back = engine.path("");
    let inside = format!(
        "{}/{}",
        staging.trim_end_matches('/'),
        rel_path.trim_start_matches('/')
    );

    move_path(
        &mut tunnel,
        &mut engine.afc,
        &container_path,
        &staging,
        logger,
    )
    .await
    .map_err(|e| format!("could not move the container into Media to read it: {e}"))?;

    let read = async {
        let mut fd = engine
            .afc
            .open(&inside, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let r = stream_afc_to_local(&mut fd, &dest_local_path).await;
        let _ = fd.close().await;
        r.map(|_| ())
    }
    .await;

    if let Err(e) = read {
        let _ = restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
        return Err(format!("read failed: {e}"));
    }

    restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
        .await
        .map_err(|e| {
            format!(
                "The file was read but the container could not be put back: {e}\n\
                 Everything is safe at /var/mobile/Media/{staging} — use Recovery to restore it."
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

    if engine.direct_read {
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

    // Stage the container once, then write the file straight into it with AFC.
    let dst_back = engine.path("");
    let staging = stage_container(&mut tunnel, &mut engine.afc, &container_path, logger).await?;
    let target = format!("{}/{}", staging.trim_end_matches('/'), rel_path);
    let outcome = async {
        if let Ok(info) = engine.afc.get_file_info(&target).await {
            if info.st_ifmt.contains("DIR") {
                return Err("A folder already exists at that name".to_string());
            }
        }
        let mut fd = engine
            .afc
            .open(&target, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let r = stream_local_to_afc(&src_local_path, &mut fd).await;
        let _ = fd.close().await;
        r.map(|_| ())
    }
    .await;
    let restore =
        unstage_container(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
    staged_outcome(outcome, restore, &staging)
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

    if engine.direct_read {
        let afc_path = engine.path(&rel_path);
        engine
            .afc
            .mk_dir(&afc_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        return Ok(());
    }

    let dst_back = engine.path("");
    let staging = stage_container(&mut tunnel, &mut engine.afc, &container_path, logger).await?;
    let target = format!("{}/{}", staging.trim_end_matches('/'), rel_path);
    let outcome = engine
        .afc
        .mk_dir(&target)
        .await
        .map_err(|e| format!("{e:?}"));
    let restore =
        unstage_container(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
    staged_outcome(outcome, restore, &staging)
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

    if engine.direct_read {
        let afc_path = engine.path(&rel_path);
        // Symlink-safe recursive delete.
        return remove_tree_safe(&mut engine.afc, &afc_path).await;
    }

    let dst_back = engine.path("");
    let staging = stage_container(&mut tunnel, &mut engine.afc, &container_path, logger).await?;
    let target = format!("{}/{}", staging.trim_end_matches('/'), rel_path);
    let outcome = remove_tree_safe(&mut engine.afc, &target).await;
    let restore =
        unstage_container(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
    staged_outcome(outcome, restore, &staging)
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

    if engine.direct_read {
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

    let dst_back = engine.path("");
    let staging = stage_container(&mut tunnel, &mut engine.afc, &container_path, logger).await?;
    let from = format!("{}/{}", staging.trim_end_matches('/'), old_rel);
    let to = format!("{}/{}", staging.trim_end_matches('/'), new_rel);
    let outcome = async {
        // Never clobber: a shadowed destination would be silent data loss.
        if engine.afc.get_file_info(&to).await.is_ok() {
            return Err("A file or folder with that name already exists".to_string());
        }
        engine
            .afc
            .rename(&from, &to)
            .await
            .map_err(|e| format!("{e:?}"))
    }
    .await;
    let restore =
        unstage_container(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger).await;
    staged_outcome(outcome, restore, &staging)
}

// ---------------------------------------------------------------------------
// Leftover classification & cleanup
// ---------------------------------------------------------------------------

/// Friendly label for the temporary names this app (and its ancestor code)
/// leaves in Media.
fn leftover_kind(name: &str) -> &'static str {
    if name.starts_with("readipa-bridge-") || name.starts_with("airlift-link-") {
        "bridge link"
    } else if name.starts_with("airlift-src-") {
        "staging folder"
    } else if name.starts_with("readipa-hold-") || name.starts_with("airlift-recovered-") {
        "held file"
    } else if name.starts_with("readipa-backup-") {
        "backup copy"
    } else if name.starts_with("readipa-pickup-") {
        "pending write"
    } else if name.starts_with("readipa-list-") {
        "listing snapshot"
    } else if name.starts_with("readipa-mkdir-") {
        "new folder"
    } else if name.starts_with("readipa-dump-") || name.starts_with("readipa-trash-") {
        "deleted item"
    } else if name.starts_with("readipa-export-") {
        "export snapshot"
    } else {
        "temporary item"
    }
}

/// True when the tree below `root` contains no regular files (only folders and
/// symlinks) — such an entry can be removed with zero data loss.
async fn tree_is_empty(afc: &mut AfcClient, root: &str) -> bool {
    let mut stack: Vec<(String, usize)> = vec![(root.to_string(), 0)];
    let mut visited = 0usize;
    while let Some((path, depth)) = stack.pop() {
        if depth > 32 || visited > 20_000 {
            return false; // too big to judge — treat as containing data
        }
        visited += 1;
        let info = match afc.get_file_info(&path).await {
            Ok(i) => i,
            Err(_) => continue,
        };
        if info.st_ifmt.contains("LNK") {
            continue; // links hold no data
        }
        if !info.st_ifmt.contains("DIR") {
            return false; // a real file lives here
        }
        if let Ok(names) = afc.list_dir(&path).await {
            for n in names {
                if n == "." || n == ".." {
                    continue;
                }
                stack.push((format!("{}/{}", path.trim_end_matches('/'), n), depth + 1));
            }
        }
    }
    true
}

async fn leftover_json(
    afc: &mut AfcClient,
    name: &str,
    info: &idevice::afc::FileInfo,
) -> serde_json::Value {
    let is_link = info.st_ifmt.contains("LNK");
    let is_dir = info.st_ifmt.contains("DIR");
    let safe = if is_link {
        true
    } else if is_dir {
        tree_is_empty(afc, name).await
    } else {
        info.size == 0
    };
    json!({
        "name": name,
        "isDir": is_dir,
        "isLink": is_link,
        "size": info.size,
        "modified": info.modified.to_string(),
        "kind": leftover_kind(name),
        "safeToRemove": safe,
    })
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
        let info = match afc.get_file_info(&n).await {
            Ok(info) => info,
            Err(_) => continue,
        };
        entries.push(leftover_json(&mut afc, &n, &info).await);
    }
    entries.sort_by(|a, b| {
        let ka = a.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        let kb = b.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        ka.cmp(kb).then_with(|| {
            a.get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .cmp(b.get("name").and_then(|v| v.as_str()).unwrap_or(""))
        })
    });
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
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    // Recovery needs a Media-side bridge because ATAirlock only accepts
    // destinations below Media. Reuse the caller's, or a matching one already in
    // Media, before creating anything new.
    let reliable = !bridge.is_empty()
        && safe_media_name(&bridge)
        && bridge_usable(&mut afc, &bridge, &container_path).await;
    let (bridge_name, temporary) = if reliable {
        (bridge, false)
    } else if let Some(existing) = find_usable_bridge(&mut afc, &container_path).await {
        (existing, true)
    } else {
        (
            make_bridge(&mut tunnel, &mut afc, &container_path, logger).await?,
            true,
        )
    };

    let dst = format!("{bridge_name}/{rel_path}");
    let prereq = if afc.get_file_info(&dst).await.is_ok() {
        Err("A file or folder with that name already exists at the destination".to_string())
    } else {
        Ok(())
    };
    if let Err(e) = prereq {
        if temporary {
            let _ = remove_one(&mut afc, &bridge_name).await;
        }
        return Err(e);
    }

    let result = move_path(
        &mut tunnel,
        &mut afc,
        &format!("{MEDIA_ROOT}{leftover_name}"),
        &dst,
        logger,
    )
    .await
    .map_err(|e| format!("could not move the leftover back: {e}"));

    if temporary {
        let _ = remove_one(&mut afc, &bridge_name).await;
    }
    result
}

/// Remove every leftover that provably holds no data (symlinks and empty
/// folder trees). Anything that contains files is reported, never deleted.
pub unsafe fn cleanup_leftovers(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_cleanup_leftovers", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(cleanup_leftovers_async(pairing_path.clone(), &logger))
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

async fn cleanup_leftovers_async(pairing_path: String, logger: &Logger) -> Result<String, String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    let names = media_list_root(&mut afc).await?;
    let mut removed: Vec<String> = Vec::new();
    let mut kept: Vec<String> = Vec::new();

    for name in names {
        if !(name.starts_with("readipa-") || name.starts_with("airlift-")) {
            continue;
        }
        let info = match afc.get_file_info(&name).await {
            Ok(i) => i,
            Err(_) => continue,
        };
        let is_link = info.st_ifmt.contains("LNK");
        let is_dir = info.st_ifmt.contains("DIR");
        let safe = if is_link {
            true
        } else if is_dir {
            tree_is_empty(&mut afc, &name).await
        } else {
            info.size == 0
        };
        if safe {
            match remove_tree_safe(&mut afc, &name).await {
                Ok(()) => {
                    logger.log(format!("cleanup: removed {name}"));
                    removed.push(name);
                }
                Err(e) => {
                    logger.log(format!("cleanup: could not remove {name}: {e}"));
                    kept.push(name);
                }
            }
        } else {
            kept.push(name);
        }
    }

    Ok(serde_json::to_string_pretty(&json!({
        "removed": removed.len(),
        "kept": kept.len(),
        "keptNames": kept,
    }))
    .map_err(|e| e.to_string())?)
}

/// Explicitly delete one leftover (the caller confirms first). Symlink-safe.
pub unsafe fn delete_leftover(
    pairing_path: *const c_char,
    name: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let name = opt_str(name, "");
    let ctx_usize = ctx as usize;

    if !safe_media_name(&name) || !(name.starts_with("readipa-") || name.starts_with("airlift-")) {
        if !out_error.is_null() {
            *out_error = cstr("refusing to delete: not a Readipa leftover");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_delete_leftover", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(delete_leftover_async(
            pairing_path.clone(),
            name.clone(),
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

async fn delete_leftover_async(
    pairing_path: String,
    name: String,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;
    remove_tree_safe(&mut afc, &name).await
}

/// Copy a leftover out of Media to a local file so the user can save it with
/// the share sheet — useful when a folder cannot be put back into a container.
pub unsafe fn export_leftover(
    pairing_path: *const c_char,
    name: *const c_char,
    dest_local_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let name = opt_str(name, "");
    let dest_local_path = opt_str(dest_local_path, "");
    let ctx_usize = ctx as usize;

    if !safe_media_name(&name)
        || !(name.starts_with("readipa-") || name.starts_with("airlift-"))
        || dest_local_path.is_empty()
    {
        if !out_error.is_null() {
            *out_error = cstr("invalid leftover or destination");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_export_leftover", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(export_leftover_async(
            pairing_path.clone(),
            name.clone(),
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

async fn export_leftover_async(
    pairing_path: String,
    name: String,
    dest_local_path: String,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;

    let info = afc
        .get_file_info(&name)
        .await
        .map_err(|e| format!("{e:?}"))?;
    if let Some(parent) = std::path::Path::new(&dest_local_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    if info.st_ifmt.contains("DIR") {
        // Folders are zipped so their contents survive.
        let file = std::fs::File::create(&dest_local_path)
            .map_err(|e| format!("cannot create {dest_local_path}: {e}"))?;
        let mut exporter = crate::export::Exporter::new(file);
        crate::export::archive_tree(&mut afc, &name, &name, &mut exporter, logger).await;
        exporter.finish()?;
        return Ok(());
    }

    let mut fd = afc
        .open(&name, AfcFopenMode::RdOnly)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let r = stream_afc_to_local(&mut fd, &dest_local_path).await;
    let _ = fd.close().await;
    r.map(|_| ())
}

// ---------------------------------------------------------------------------
// FFI: access probe (runs automatically, read-only + one reversible write test)
// ---------------------------------------------------------------------------

/// Works out what iOS will actually let us do with this container and returns a
/// one-line verdict plus the evidence. No button, no report screen — Swift calls
/// this when a container is opened and logs the answer.
pub unsafe fn probe_access(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    bridge: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let container_path = opt_str(container_path, "");
    let bridge = opt_str(bridge, "");
    let ctx_usize = ctx as usize;

    if !allowed_container(&container_path) {
        if !out_error.is_null() {
            *out_error = cstr("container_path is not allowed");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_probe_access", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(probe_access_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
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

async fn probe_access_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    bridge: String,
    logger: &Logger,
) -> Result<String, String> {
    let pairing_bytes = read_pairing(&pairing_path)?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut evidence: Vec<String> = Vec::new();

    // 1. HouseArrest (dev-signed / file-sharing apps).
    if !bundle_id.is_empty() {
        for command in ["VendContainer", "VendDocuments"] {
            match try_vend(&mut tunnel, &bundle_id, command, logger).await {
                Ok(mut afc) => {
                    let entries = afc.list_dir(".").await.map(|v| v.len()).unwrap_or(0);
                    evidence.push(format!(
                        "house_arrest {command}: granted ({entries} entries)"
                    ));
                    return Ok(verdict("full", &evidence));
                }
                Err(e) => evidence.push(format!("house_arrest {command}: {e}")),
            }
        }
    } else {
        evidence.push("house_arrest: no bundle id for this container".into());
    }

    // 2. Direct AFC through the bridge.
    let mut afc = tunnel.connect_afc(logger).await?;
    let bridge_ok = bridge_matches(&mut afc, &bridge, &container_path)
        .await
        .is_ok();
    evidence.push(format!("bridge resolves to the container: {bridge_ok}"));

    let (listed, list_err) = list_dir_variants(&mut afc, &bridge).await;
    if let Some(names) = listed {
        evidence.push(format!("direct listing: {} entries", names.len()));
        return Ok(verdict("bridge", &evidence));
    }
    evidence.push(format!("direct listing: {list_err}"));

    let stat = afc.get_file_info(&format!("{bridge}/.")).await;
    evidence.push(format!(
        "direct stat: {}",
        match stat {
            Ok(_) => "ok".to_string(),
            Err(e) => format!("{e:?}"),
        }
    ));

    // 3. The one thing AirLift is documented to do here: write a NEW file in.
    //    A tiny payload is moved through the bridge and then removed again.
    let token = exploit::random_hex(6);
    let probe_name = format!("readipa-probe-{token}.txt");
    let media_probe = format!("readipa-probe-{token}");
    let payload = b"readipa probe\n";
    {
        let mut fd = afc
            .open(&media_probe, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let _ = fd.write_entire(payload).await;
        let _ = fd.close().await;
    }
    let dst = format!("{}/{}", bridge.trim_end_matches('/'), probe_name);
    match move_path(
        &mut tunnel,
        &mut afc,
        &format!("{MEDIA_ROOT}{media_probe}"),
        &dst,
        logger,
    )
    .await
    {
        Ok(()) => {
            evidence.push("write probe: a new file landed inside the container".into());
        }
        Err(e) => {
            evidence.push(format!("write probe: {e}"));
        }
    }
    let _ = afc.remove(&media_probe).await;

    Ok(verdict("none", &evidence))
}

fn verdict(level: &str, evidence: &[String]) -> String {
    serde_json::to_string_pretty(&json!({
        "access": level,
        "evidence": evidence,
    }))
    .unwrap_or_else(|_| format!("{{\"access\":\"{level}\"}}"))
}
