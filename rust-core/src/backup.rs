//! Read an app's data through the device's own backup service.
//!
//! Every other route is closed for a normal App Store app:
//!   * `com.apple.afc` cannot even resolve `/var/mobile/Containers` (sandboxed
//!     lookup returns ENOENT), so the AirLift bridge gives nothing.
//!   * `house_arrest` refuses both vend modes without `get-task-allow`.
//!   * `ATAirlock` cannot move entries out of a container.
//!
//! `com.apple.mobilebackup2` is the one service a paired host may legitimately
//! use: the device streams the requested domain's files to us and we write them
//! into a directory the app can then zip and share. Nothing on the device is
//! modified — a backup is a read.

use std::ffi::{c_char, c_void};

use idevice::services::mobilebackup2::{FsBackupDelegate, MobileBackup2Client};
use idevice::IdeviceService;
use serde_json::json;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

/// Hard ceiling so a device that ignores the domain filter cannot fill the
/// sandbox. Checked by a size watcher while the backup runs.
const MAX_BACKUP_BYTES: u64 = 3 * 1024 * 1024 * 1024;

#[allow(clippy::too_many_arguments)]
pub unsafe fn backup_app(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    dest_dir: *const c_char,
    timeout_secs: u32,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let dest_dir = opt_str(dest_dir, "");
    let ctx_usize = ctx as usize;

    if bundle_id.is_empty() || dest_dir.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("bundle_id and dest_dir are required");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_backup_app", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(backup_async(
            pairing_path.clone(),
            bundle_id.clone(),
            dest_dir.clone(),
            timeout_secs.max(30),
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

async fn backup_async(
    pairing_path: String,
    bundle_id: String,
    dest_dir: String,
    timeout_secs: u32,
    logger: &Logger,
) -> Result<String, String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;

    let udid = device_udid(&mut tunnel, logger).await;
    logger.log(format!(
        "backup: requesting AppDomain-{bundle_id} (source {})",
        udid.clone().unwrap_or_else(|| "device".into())
    ));

    std::fs::create_dir_all(&dest_dir).map_err(|e| format!("cannot create {dest_dir}: {e}"))?;

    let stream = tunnel
        .connect_service("com.apple.mobilebackup2", logger)
        .await?;
    let idevice = idevice::Idevice::new(stream, "Readipa");

    logger.log("backup: DeviceLink handshake…");
    let mut client = MobileBackup2Client::from_stream(idevice)
        .await
        .map_err(|e| format!("mobilebackup2 handshake failed: {e:?}"))?;

    // Only this app's domain; if the device ignores it we bail out on size.
    let mut options = plist::Dictionary::new();
    options.insert("AllDomains".into(), plist::Value::Boolean(false));
    options.insert(
        "Domains".into(),
        plist::Value::Array(vec![plist::Value::String(format!("AppDomain-{bundle_id}"))]),
    );
    options.insert("IsFullBackup".into(), plist::Value::Boolean(false));
    options.insert(
        "BackupReason".into(),
        plist::Value::String("Readipa export".into()),
    );

    let delegate = FsBackupDelegate;
    let root = std::path::PathBuf::from(&dest_dir);
    let source = udid.clone();

    let result = tokio::time::timeout(std::time::Duration::from_secs(timeout_secs as u64), async {
        let backup = client.backup_from_path(&root, source.as_deref(), Some(options), &delegate);
        tokio::pin!(backup);
        loop {
            tokio::select! {
                outcome = &mut backup => return Ok::<bool, String>(outcome.is_ok()),
                _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {
                    if dir_size(&root) > MAX_BACKUP_BYTES {
                        return Err("size ceiling reached".to_string());
                    }
                }
            }
        }
    })
    .await;

    match result {
        Ok(Ok(true)) => logger.log("backup: device reported completion"),
        Ok(Ok(false)) => {
            logger.log("backup: device ended the session with an error, keeping what arrived")
        }
        Ok(Err(e)) => logger.log(format!("backup: stopped — {e}")),
        Err(_) => logger.log("backup: timed out — keeping what arrived"),
    }

    let files = count_files(&root);
    let bytes = dir_size(&root);
    logger.log(format!(
        "backup: {files} file(s), {} received",
        crate::fsengine::human_bytes(bytes)
    ));

    if files == 0 {
        return Err(
            "The device sent no files. It may refuse backups while a passcode/Touch ID \
             gesture is pending, or this domain may not be included in local backups."
                .to_string(),
        );
    }

    Ok(serde_json::to_string_pretty(&json!({
        "bundleId": bundle_id,
        "directory": dest_dir,
        "files": files,
        "bytes": bytes,
        "truncated": bytes >= MAX_BACKUP_BYTES,
    }))
    .map_err(|e| e.to_string())?)
}

async fn device_udid(tunnel: &mut AppDeviceTunnel, logger: &Logger) -> Option<String> {
    let mut lockdown = tunnel.connect_lockdown(logger).await.ok()?;
    let value = lockdown
        .get_value(Some("UniqueDeviceID"), None)
        .await
        .ok()?;
    value.as_string().map(|s| s.to_string())
}

fn dir_size(root: &std::path::Path) -> u64 {
    fn walk(dir: &std::path::Path, out: &mut u64) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(t) if t.is_dir() => walk(&path, out),
                Ok(t) if t.is_file() => {
                    if let Ok(meta) = entry.metadata() {
                        *out += meta.len();
                    }
                }
                _ => {}
            }
        }
    }
    let mut total = 0;
    walk(root, &mut total);
    total
}

fn count_files(root: &std::path::Path) -> u64 {
    fn walk(dir: &std::path::Path, out: &mut u64) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(t) if t.is_dir() => walk(&path, out),
                Ok(t) if t.is_file() => *out += 1,
                _ => {}
            }
        }
    }
    let mut total = 0;
    walk(root, &mut total);
    total
}
