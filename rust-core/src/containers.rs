//! Container catalog — list installed apps + their Data containers + App Group containers.

use idevice::services::installation_proxy::InstallationProxyClient;
use serde_json::json;
use std::ffi::{c_char, c_void};

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

const DATA_ROOT: &str = "/var/mobile/Containers/Data/Application";
const GROUP_ROOT: &str = "/var/mobile/Containers/Shared/AppGroup";

fn normalize_path(p: &str) -> String {
    let p = p.trim();
    if p.starts_with("/private/var/") {
        p.replacen("/private/var/", "/var/", 1)
    } else {
        p.to_string()
    }
}

fn is_allowed_container(p: &str) -> bool {
    if p.is_empty() || p.contains('\0') {
        return false;
    }
    let p = normalize_path(p);
    if !p.starts_with('/') || p.split('/').any(|c| c == ".." || c == ".") {
        return false;
    }
    for root in [DATA_ROOT, GROUP_ROOT] {
        if let Some(rest) = p.strip_prefix(root) {
            // Require a real "<root>/<uuid>" boundary, not a prefix match.
            return rest.starts_with('/') && rest.len() > 1;
        }
    }
    false
}

pub unsafe fn catalog(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_container_catalog", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(catalog_async(pairing_path.clone(), &logger))
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

async fn catalog_async(pairing_path: String, logger: &Logger) -> Result<String, String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;

    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let mut inst = tunnel.connect_installation_proxy(logger).await?;

    let apps = inst
        .get_apps(Some("Any"), None)
        .await
        .map_err(|e| format!("InstallationProxy get_apps failed: {e:?}"))?;

    let mut app_list: Vec<serde_json::Value> = Vec::new();
    let mut groups: std::collections::BTreeMap<String, (String, Vec<String>)> =
        std::collections::BTreeMap::new();

    for (bundle_id, info) in apps.iter() {
        let dict = match info.as_dictionary() {
            Some(d) => d,
            None => continue,
        };
        let app_type = dict
            .get("ApplicationType")
            .and_then(|v| v.as_string())
            .unwrap_or("User")
            .to_string();
        let name = dict
            .get("CFBundleDisplayName")
            .or_else(|| dict.get("CFBundleName"))
            .and_then(|v| v.as_string())
            .unwrap_or(bundle_id.as_str())
            .to_string();
        let version = dict
            .get("CFBundleShortVersionString")
            .or_else(|| dict.get("CFBundleVersion"))
            .and_then(|v| v.as_string())
            .unwrap_or("")
            .to_string();

        let data_container = dict
            .get("Container")
            .and_then(|v| v.as_string())
            .map(normalize_path)
            .unwrap_or_default();

        let mut group_map = serde_json::Map::new();
        if let Some(gc) = dict.get("GroupContainers").and_then(|v| v.as_dictionary()) {
            for (gid, pathv) in gc {
                if let Some(path) = pathv.as_string() {
                    let np = normalize_path(path);
                    if is_allowed_container(&np) {
                        group_map.insert(gid.clone(), serde_json::Value::String(np.clone()));
                        let entry = groups
                            .entry(gid.clone())
                            .or_insert_with(|| (np.clone(), Vec::new()));
                        if !entry.1.contains(bundle_id) {
                            entry.1.push(bundle_id.clone());
                        }
                    }
                }
            }
        }

        app_list.push(json!({
            "bundleId": bundle_id,
            "name": name,
            "type": app_type,
            "version": version,
            "dataContainer": data_container,
            "groupContainers": group_map,
        }));
    }

    app_list.sort_by(|a, b| {
        a.get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .cmp(b.get("name").and_then(|v| v.as_str()).unwrap_or(""))
    });

    let mut group_list: Vec<serde_json::Value> = Vec::new();
    for (gid, (path, owners)) in groups.iter() {
        group_list.push(json!({
            "id": gid,
            "path": path,
            "owners": owners,
        }));
    }

    let out = json!({
        "apps": app_list,
        "appGroups": group_list,
    });

    Ok(serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?)
}
