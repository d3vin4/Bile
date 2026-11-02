//! Real app icons, straight from SpringBoard.
//!
//! iOS keeps every installed app's icon in SpringBoard; the
//! `com.apple.springboardservices` service hands out the PNG for a bundle id.
//! Icons are written to a local cache file chosen by the caller — nothing on the
//! device is modified.

use std::ffi::{c_char, c_void};

use idevice::services::springboardservices::SpringBoardServicesClient;

use crate::exploit::{self, Logger};
use crate::ffi_util::{cstr, opt_str};

pub unsafe fn app_icon(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    dest_local_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let dest_local_path = opt_str(dest_local_path, "");
    let ctx_usize = ctx as usize;

    if bundle_id.is_empty() || dest_local_path.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("bundle_id and dest_local_path are required");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_app_icon", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(icon_async(
            pairing_path.clone(),
            bundle_id.clone(),
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

async fn icon_async(
    pairing_path: String,
    bundle_id: String,
    dest_local_path: String,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;

    let mut client = match tunnel
        .connect_service("com.apple.springboardservices", logger)
        .await
    {
        Ok(stream) => SpringBoardServicesClient::new(idevice::Idevice::new(stream, "Airlift")),
        Err(e) => {
            // Try the RSD-native variant as a second chance.
            logger.log(format!("springboardservices unavailable ({e})"));
            return Err(e);
        }
    };

    let png = client
        .get_icon_pngdata(bundle_id.clone())
        .await
        .map_err(|e| format!("getIconPNGData({bundle_id}) failed: {e:?}"))?;

    if png.is_empty() {
        return Err(format!("{bundle_id} returned an empty icon"));
    }

    if let Some(parent) = std::path::Path::new(&dest_local_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&dest_local_path, &png).map_err(|e| format!("write icon: {e}"))?;
    logger.log(format!("icon for {bundle_id}: {} bytes", png.len()));
    Ok(())
}
