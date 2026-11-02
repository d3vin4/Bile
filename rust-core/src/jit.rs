//! JIT enabler for sideloaded apps (`get-task-allow`).
//!
//! Same mechanism the on-device debuggers use, implemented straight against the
//! RSD tunnel:
//!
//!   1. `com.apple.instruments.dtservicehub` — the DVT remote server.
//!   2. `com.apple.instruments.server.services.processcontrol` — launch the app
//!      suspended and read back its pid.
//!   3. `com.apple.internal.dt.remote.debugproxy` — speak the GDB remote
//!      protocol, `vAttach;<pid>`, then detach. Attaching marks the process as
//!      debugged, which is what lets the kernel allow JIT on its pages.
//!
//! Nothing is installed and no entitlement is forged: an app without
//! `get-task-allow` simply cannot be attached to.

use std::ffi::{c_char, c_void};

use idevice::services::debug_proxy::{DebugProxyClient, DebugserverCommand};
use idevice::services::dvt::process_control::ProcessControlClient;
use idevice::services::dvt::remote_server::RemoteServerClient;
use serde_json::json;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

pub unsafe fn jit_enable(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let ctx_usize = ctx as usize;

    if bundle_id.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("bundle_id must not be empty");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_jit_enable", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(jit_enable_async(
            pairing_path.clone(),
            bundle_id.clone(),
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

async fn jit_enable_async(
    pairing_path: String,
    bundle_id: String,
    logger: &Logger,
) -> Result<String, String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;

    // 1. DVT remote server.
    logger.log("jit: connecting to com.apple.instruments.dtservicehub…");
    let mut remote = connect_dtservicehub(&mut tunnel, logger).await?;
    remote
        .read_message(0)
        .await
        .map_err(|e| format!("remote server handshake failed: {e:?}"))?;

    // 2. Process control: launch the app suspended so the debugger can attach.
    let pid = {
        let mut control = ProcessControlClient::new(&mut remote)
            .await
            .map_err(|e| format!("processcontrol channel failed: {e:?}"))?;
        logger.log(format!("jit: launching {bundle_id} suspended…"));
        control
            .launch_app(bundle_id.clone(), None, None, true, true)
            .await
            .map_err(|e| {
                format!(
                    "could not launch {bundle_id}: {e:?}\n\
                     This usually means the app is not sideloaded with get-task-allow, \
                     or it is not installed."
                )
            })?
    };
    logger.log(format!("jit: {bundle_id} is pid {pid}"));

    // 3. Debug proxy: attach, then detach so the process resumes with JIT on.
    logger.log("jit: connecting to the debug proxy…");
    let stream = tunnel
        .connect_service("com.apple.internal.dt.remote.debugproxy", logger)
        .await?;
    let mut debug = DebugProxyClient::new(stream);

    let _ = debug.send_ack().await;
    let _ = debug.send_ack().await;

    match debug
        .send_command(DebugserverCommand::new(
            "QStartNoAckMode".to_string(),
            vec![],
        ))
        .await
    {
        Ok(response) => logger.log(format!("jit: QStartNoAckMode -> {response:?}")),
        Err(e) => logger.log(format!("jit: QStartNoAckMode warning: {e:?}")),
    }
    debug.set_ack_mode(false);

    let attach = format!("vAttach;{pid:x}");
    let response = debug
        .send_command(DebugserverCommand::new(attach.clone(), vec![]))
        .await
        .map_err(|e| format!("{attach} failed: {e:?}"))?;
    logger.log(format!("jit: {attach} -> {response:?}"));

    let attached = response
        .as_deref()
        .map(|r| r.starts_with('T') || r.starts_with('S') || r.starts_with("OK"))
        .unwrap_or(false);
    if !attached {
        let _ = debug
            .send_command(DebugserverCommand::new("D".to_string(), vec![]))
            .await;
        return Err(format!(
            "the debugger could not attach to {bundle_id} (pid {pid}); response was {response:?}. \
             The app most likely lacks the get-task-allow entitlement."
        ));
    }

    // Detach: the process keeps running, now marked as debugged.
    match debug
        .send_command(DebugserverCommand::new("D".to_string(), vec![]))
        .await
    {
        Ok(r) => logger.log(format!("jit: detach -> {r:?}")),
        Err(e) => logger.log(format!("jit: detach warning: {e:?}")),
    }

    logger.log(format!("jit: {bundle_id} now runs with JIT enabled ✅"));

    Ok(serde_json::to_string_pretty(&json!({
        "bundleId": bundle_id,
        "pid": pid,
        "jit": "enabled",
    }))
    .map_err(|e| e.to_string())?)
}

/// Connect to the DVT service hub. RSD advertises it directly on iOS 17+.
async fn connect_dtservicehub(
    tunnel: &mut AppDeviceTunnel,
    logger: &Logger,
) -> Result<RemoteServerClient<Box<dyn idevice::ReadWrite>>, String> {
    let stream = tunnel
        .connect_service("com.apple.instruments.dtservicehub", logger)
        .await?;
    Ok(RemoteServerClient::new(stream))
}
