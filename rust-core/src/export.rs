//! Bulk, read-only export of a container into a local ZIP archive.
//!
//! Nothing inside the container is modified when direct access is available.
//! When the bridge denies traversal (AirLift move mode) the subtree is
//! relocated once, archived from Media, and moved back with verification — the
//! same guarantees as `fs_list`, and it requires the risky-move opt-in.
//!
//! Symbolic links are never followed: their target is recorded as a small
//! `<name>.symlink.txt` entry instead, so an export can never walk out of the
//! container (or loop forever).

use std::ffi::{c_char, c_void};
use std::io::Write as _;
use tokio::io::AsyncReadExt;

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;
use serde_json::json;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};
use crate::fsengine;

const CHUNK: usize = 256 * 1024;
const MAX_DEPTH: usize = 64;
const MAX_ENTRIES: u64 = 200_000;

struct Exporter {
    zip: zip::ZipWriter<std::fs::File>,
    files: u64,
    bytes: u64,
    links: u64,
    dirs: u64,
    failures: Vec<String>,
}

impl Exporter {
    fn new(file: std::fs::File) -> Self {
        Self {
            zip: zip::ZipWriter::new(file),
            files: 0,
            bytes: 0,
            links: 0,
            dirs: 0,
            failures: Vec::new(),
        }
    }

    fn start_file(&mut self, name: &str) -> Result<(), String> {
        let opts: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(0o644);
        self.zip
            .start_file(name.to_string(), opts)
            .map_err(|e| e.to_string())
    }

    fn add_bytes(&mut self, name: &str, data: &[u8]) -> Result<(), String> {
        self.start_file(name)?;
        self.write(data)
    }

    fn add_dir(&mut self, name: &str) -> Result<(), String> {
        let opts: zip::write::SimpleFileOptions =
            zip::write::SimpleFileOptions::default().unix_permissions(0o755);
        self.zip
            .add_directory(format!("{}/", name.trim_end_matches('/')), opts)
            .map_err(|e| e.to_string())
    }

    fn write(&mut self, data: &[u8]) -> Result<(), String> {
        self.zip.write_all(data).map_err(|e| e.to_string())
    }

    fn finish(self) -> Result<(), String> {
        self.zip.finish().map_err(|e| e.to_string()).map(|_| ())
    }
}

/// Copy one regular file from the device into the open zip entry.
async fn copy_file(
    afc: &mut AfcClient,
    afc_path: &str,
    zip_name: &str,
    exporter: &mut Exporter,
) -> Result<u64, String> {
    let mut fd = afc
        .open(afc_path, AfcFopenMode::RdOnly)
        .await
        .map_err(|e| format!("{e:?}"))?;
    exporter.start_file(zip_name)?;
    let mut buf = vec![0u8; CHUNK];
    let mut total = 0u64;
    loop {
        let n = fd.read(&mut buf).await.map_err(|e| format!("{e:?}"))?;
        if n == 0 {
            break;
        }
        exporter.write(&buf[..n])?;
        total += n as u64;
    }
    let _ = fd.close().await;
    Ok(total)
}

/// Walk `root_afc` and add everything below it to the archive.
async fn archive_tree(
    afc: &mut AfcClient,
    root_afc: &str,
    prefix: &str,
    exporter: &mut Exporter,
    logger: &Logger,
) {
    let mut stack: Vec<(String, String, usize)> = vec![(
        root_afc.trim_end_matches('/').to_string(),
        prefix.trim_end_matches('/').to_string(),
        0usize,
    )];

    while let Some((dir, zip_dir, depth)) = stack.pop() {
        if depth > MAX_DEPTH {
            exporter
                .failures
                .push(format!("{zip_dir}: depth limit reached"));
            continue;
        }
        let names = match afc.list_dir(&dir).await {
            Ok(n) => n,
            Err(e) => {
                exporter
                    .failures
                    .push(format!("{zip_dir}: list failed {e:?}"));
                continue;
            }
        };
        for name in names {
            if name == "." || name == ".." {
                continue;
            }
            if exporter.files + exporter.links + exporter.dirs >= MAX_ENTRIES {
                exporter.failures.push("entry limit reached".to_string());
                return;
            }
            let child_afc = format!("{}/{}", dir.trim_end_matches('/'), name);
            let child_zip = if zip_dir.is_empty() {
                name.clone()
            } else {
                format!("{zip_dir}/{name}")
            };
            let info = match afc.get_file_info(&child_afc).await {
                Ok(i) => i,
                Err(e) => {
                    exporter.failures.push(format!("{child_zip}: {e:?}"));
                    continue;
                }
            };
            if info.st_ifmt.contains("LNK") {
                // Record the target; never follow it.
                let target = info.st_link_target.clone().unwrap_or_default();
                let note = format!("symbolic link -> {target}\n");
                if exporter
                    .add_bytes(&format!("{child_zip}.symlink.txt"), note.as_bytes())
                    .is_err()
                {
                    exporter
                        .failures
                        .push(format!("{child_zip}: could not record link"));
                }
                exporter.links += 1;
                continue;
            }
            if info.st_ifmt.contains("DIR") {
                if exporter.add_dir(&child_zip).is_err() {
                    exporter
                        .failures
                        .push(format!("{child_zip}: could not add directory"));
                }
                exporter.dirs += 1;
                stack.push((child_afc, child_zip, depth + 1));
                continue;
            }
            match copy_file(afc, &child_afc, &child_zip, exporter).await {
                Ok(n) => {
                    exporter.files += 1;
                    exporter.bytes += n;
                    logger.log(format!("export: {child_zip} ({n} bytes)"));
                }
                Err(e) => exporter.failures.push(format!("{child_zip}: {e}")),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
pub unsafe fn export_container(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    container_path: *const c_char,
    rel_path: *const c_char,
    bridge: *const c_char,
    dest_zip_path: *const c_char,
    root_name: *const c_char,
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
    let dest_zip_path = opt_str(dest_zip_path, "");
    let root_name = opt_str(root_name, "");
    let ctx_usize = ctx as usize;

    if !fsengine::allowed_container(&container_path) || !fsengine::safe_rel(&rel_path) {
        if !out_error.is_null() {
            *out_error = cstr("invalid container or path");
        }
        return 1;
    }
    if dest_zip_path.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("dest_zip_path must not be empty");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_export_container", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(export_async(
            pairing_path.clone(),
            bundle_id.clone(),
            container_path.clone(),
            rel_path.clone(),
            bridge.clone(),
            dest_zip_path.clone(),
            root_name.clone(),
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

#[allow(clippy::too_many_arguments)]
async fn export_async(
    pairing_path: String,
    bundle_id: String,
    container_path: String,
    rel_path: String,
    bridge: String,
    dest_zip_path: String,
    root_name: String,
    logger: &Logger,
) -> Result<String, String> {
    if let Some(parent) = std::path::Path::new(&dest_zip_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let file = std::fs::File::create(&dest_zip_path)
        .map_err(|e| format!("cannot create {dest_zip_path}: {e}"))?;
    let mut exporter = Exporter::new(file);

    let prefix = root_name.trim().trim_matches('/').to_string();
    let (mut tunnel, mut engine) =
        fsengine::open_engine(&pairing_path, &bundle_id, &container_path, &bridge, logger).await?;

    let mut mode = "direct";
    let mut relocate: Option<(String, String)> = None;

    if engine.direct_read {
        let root_afc = engine.path(&rel_path);
        archive_tree(&mut engine.afc, &root_afc, &prefix, &mut exporter, logger).await;
    } else {
        if !fsengine::risky_moves_allowed() {
            return Err(
                "This container blocks direct access. Enable \"Allow risky moves\" in Setup to \
                 export it (the folder is relocated to Media for the duration of the export)."
                    .to_string(),
            );
        }
        mode = "move";
        let token = exploit::random_hex(8);
        let staging = format!("readipa-export-{token}");
        let abs = engine.abs_path(&container_path, &rel_path);
        let dst_back = engine.path(&rel_path);

        fsengine::move_path(&mut tunnel, &mut engine.afc, &abs, &staging, logger)
            .await
            .map_err(|e| format!("could not relocate the folder for export: {e}"))?;

        archive_tree(&mut engine.afc, &staging, &prefix, &mut exporter, logger).await;

        relocate = Some((staging, dst_back));
    }

    // Add the manifest last: the archive can only be finalised once.
    let manifest = json!({
        "app": root_name,
        "bundleId": bundle_id,
        "container": container_path,
        "path": rel_path,
        "mode": mode,
        "files": exporter.files,
        "directories": exporter.dirs,
        "symlinks": exporter.links,
        "bytes": exporter.bytes,
        "failures": exporter.failures,
        "generator": "Readipa",
    });
    let manifest_bytes = serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?;
    let _ = exporter.add_bytes("_readipa_export.json", &manifest_bytes);

    let files = exporter.files;
    let bytes = exporter.bytes;
    let dirs = exporter.dirs;
    let links = exporter.links;
    let failures = exporter.failures.clone();
    exporter.finish()?;

    // Put the folder back, always.
    let mut restore_error: Option<String> = None;
    if let Some((staging, dst_back)) = relocate {
        if let Err(e) =
            fsengine::restore_staged_dir(&mut tunnel, &mut engine.afc, &staging, &dst_back, logger)
                .await
        {
            restore_error = Some(format!(
                "{e}\nThe folder is safe at /var/mobile/Media/{staging} — use Recovery to move it back."
            ));
        }
    }

    if let Some(e) = restore_error {
        return Err(format!(
            "Export finished ({files} files) but the folder could not be restored: {e}"
        ));
    }

    Ok(serde_json::to_string_pretty(&json!({
        "zip": dest_zip_path,
        "files": files,
        "directories": dirs,
        "symlinks": links,
        "bytes": bytes,
        "mode": mode,
        "failures": failures,
    }))
    .map_err(|e| e.to_string())?)
}
