//! Core Device FileService — the sanctioned file-browser protocol iOS exposes
//! over the RSD tunnel.
//!
//! The command channel speaks OPACK dictionaries framed by the RemoteXPC
//! transport (HTTP/2). The wire protocol is: `CreateSession` to open a session
//! for one domain (appDataContainer / appGroupDataContainer / temporary),
//! `FileSystemOperation` for open/read/write/create/rename/remove, and
//! `RetrieveDirectoryList` to enumerate a folder. Failures are reported as
//! dictionaries carrying `EncodedError` / `LocalizedDescription`.
//!
//! This module is used in two ways:
//! - `probe_service` runs from the automatic access check and explains whether
//!   the current iOS build exposes the service;
//! - `list_entries` / `read_to_local` are fallbacks used by the file engine
//!   when AFC access to a container is refused.

use std::ffi::{c_char, c_void};

use idevice::xpc::{Dictionary, RemoteXpcClient, XPCObject};
use serde_json::json;

use crate::exploit::{self, AppDeviceTunnel, Logger};
use crate::ffi_util::{cstr, opt_str};

pub(crate) const CTRL_SERVICE: &str = "com.apple.coredevice.fileservice.control";

const CHUNK: usize = 512 * 1024;
const MAX_ENTRY: usize = 4096;

#[derive(Clone, Copy)]
pub(crate) enum Domain {
    AppDataContainer = 1,
    AppGroupDataContainer = 2,
    Temporary = 3,
    SystemCrashLogs = 5,
}

impl Domain {
    pub(crate) fn from_name(name: &str) -> Result<Self, String> {
        match name {
            "application" | "appDataContainer" => Ok(Self::AppDataContainer),
            "appGroup" | "appGroupDataContainer" | "systemAppGroup" => {
                Ok(Self::AppGroupDataContainer)
            }
            "temporary" => Ok(Self::Temporary),
            "systemCrashLogs" | "system" => Ok(Self::SystemCrashLogs),
            other => Err(format!("unknown file-service domain {other}")),
        }
    }

    /// Container root → FileService domain.
    pub(crate) fn for_container(container_path: &str) -> Self {
        if container_path.contains("/Shared/AppGroup") {
            Self::AppGroupDataContainer
        } else {
            Self::AppDataContainer
        }
    }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// One live FileService session, bound to a single domain + identifier.
pub(crate) struct Session {
    client: RemoteXpcClient<Box<dyn idevice::ReadWrite>>,
    session: String,
}

/// The container UUID is the last path component of the container root.
fn uuid_of(container_path: &str) -> &str {
    container_path.rsplit('/').next().unwrap_or("")
}

impl Session {
    pub(crate) async fn open(
        tunnel: &mut AppDeviceTunnel,
        domain: Domain,
        identifier: &str,
        logger: &Logger,
    ) -> Result<Self, String> {
        Self::open_as(tunnel, domain, identifier, "mobile", logger).await
    }

    /// Open a session trying the identifier first and the container's UUID
    /// second: some iOS builds resolve one but not the other.
    pub(crate) async fn open_for_container(
        tunnel: &mut AppDeviceTunnel,
        domain: Domain,
        identifier: &str,
        container_path: &str,
        allow_root: bool,
        logger: &Logger,
    ) -> Result<(Self, String), String> {
        match Self::open_as(tunnel, domain, identifier, "mobile", logger).await {
            Ok(session) => return Ok((session, identifier.to_string())),
            Err(first) => {
                let uuid = uuid_of(container_path);
                if !uuid.is_empty() && uuid != identifier {
                    logger.log(format!(
                        "file_service: identifier refused ({first}); retrying with the container UUID"
                    ));
                    match Self::open_as(tunnel, domain, uuid, "mobile", logger).await {
                        Ok(session) => return Ok((session, uuid.to_string())),
                        Err(second) => {
                            if !allow_root {
                                return Err(format!("{first}; uuid fallback: {second}"));
                            }
                            logger.log(format!(
                                "file_service: uuid refused ({second}); retrying as user 'root' (read-only use)"
                            ));
                            return match Self::open_as(tunnel, domain, identifier, "root", logger)
                                .await
                            {
                                Ok(session) => Ok((session, "root".to_string())),
                                Err(third) => {
                                    Err(format!("{first}; uuid: {second}; root: {third}"))
                                }
                            };
                        }
                    }
                }
                if !allow_root {
                    return Err(first);
                }
                logger.log(
                    "file_service: identifier refused; retrying as user 'root' (read-only use)"
                        .to_string(),
                );
                match Self::open_as(tunnel, domain, identifier, "root", logger).await {
                    Ok(session) => Ok((session, "root".to_string())),
                    Err(second) => Err(format!("{first}; root: {second}")),
                }
            }
        }
    }

    async fn open_as(
        tunnel: &mut AppDeviceTunnel,
        domain: Domain,
        identifier: &str,
        user: &str,
        logger: &Logger,
    ) -> Result<Self, String> {
        logger.log(format!(
            "file_service: connecting to {CTRL_SERVICE} (domain {} id {identifier} user {user})…",
            domain as u64
        ));
        match tunnel.rsd_service_features(CTRL_SERVICE) {
            Some(features) => logger.log(format!(
                "file_service: device advertises {} feature(s): {}",
                features.len(),
                features.join(", ")
            )),
            None => logger.log("file_service: device advertises no feature list".to_string()),
        }
        let stream = tunnel.connect_rsd_service_raw(CTRL_SERVICE, logger).await?;
        let mut client = RemoteXpcClient::new(stream)
            .await
            .map_err(|e| format!("FileService handshake failed: {e:?}"))?;
        client
            .do_handshake()
            .await
            .map_err(|e| format!("FileService handshake failed: {e:?}"))?;

        let response = send_dict(
            &mut client,
            Dictionary::from_iter([
                ("Cmd".to_string(), XPCObject::String("CreateSession".into())),
                ("Domain".to_string(), XPCObject::UInt64(domain as u64)),
                (
                    "Identifier".to_string(),
                    XPCObject::String(identifier.into()),
                ),
                ("Session".to_string(), XPCObject::String(String::new())),
                ("User".to_string(), XPCObject::String(user.into())),
            ]),
        )
        .await?;

        let session = response
            .as_dictionary()
            .and_then(|d| d.get("NewSessionID"))
            .and_then(|v| v.as_string())
            .map(|s| s.to_string())
            .ok_or_else(|| {
                format!(
                    "device refused the FileService session: {}",
                    show(&response)
                )
            })?;
        logger.log(format!("file_service: session open ({session})"));
        Ok(Self { client, session })
    }

    pub(crate) async fn list(&mut self, path: &str) -> Result<Vec<String>, String> {
        let path = if path.trim_matches('/').is_empty() {
            "."
        } else {
            path
        };
        let response = send_dict(
            &mut self.client,
            Dictionary::from_iter([
                (
                    "Cmd".to_string(),
                    XPCObject::String("RetrieveDirectoryList".into()),
                ),
                ("MessageUUID".to_string(), XPCObject::String(message_uuid())),
                ("Path".to_string(), XPCObject::String(path.into())),
                (
                    "SessionID".to_string(),
                    XPCObject::String(self.session.clone()),
                ),
            ]),
        )
        .await?;
        response
            .as_dictionary()
            .and_then(|d| d.get("FileList"))
            .and_then(|v| v.as_array())
            .map(|v| {
                v.iter()
                    .filter_map(|i| i.as_string().map(|s| s.to_string()))
                    .collect()
            })
            .ok_or_else(|| format!("malformed directory list reply: {}", show(&response)))
    }

    pub(crate) async fn attributes(&mut self, path: &str) -> Result<Attributes, String> {
        let path = if path.trim_matches('/').is_empty() {
            "."
        } else {
            path
        };
        let response = self
            .file_operation(
                "GetAttributes",
                Dictionary::from_iter([
                    ("Path".to_string(), XPCObject::String(path.into())),
                    ("FollowSymlinks".to_string(), XPCObject::Bool(true)),
                ]),
            )
            .await?;
        let raw = response
            .as_dictionary()
            .and_then(|d| d.get("Attributes"))
            .ok_or_else(|| format!("attributes missing in reply: {}", show(&response)))?;
        let text = attribute_text(raw)
            .ok_or_else(|| format!("attributes are not readable text: {}", show(&response)))?;
        Attributes::parse(&text)
    }

    pub(crate) async fn open_file(
        &mut self,
        path: &str,
        flags: i64,
        mode: u64,
    ) -> Result<i64, String> {
        let response = self
            .file_operation(
                "OpenFile",
                Dictionary::from_iter([
                    ("Path".to_string(), XPCObject::String(path.into())),
                    ("Flags".to_string(), XPCObject::Int64(flags)),
                    ("Mode".to_string(), XPCObject::UInt64(mode)),
                ]),
            )
            .await?;
        response
            .as_dictionary()
            .and_then(|d| d.get("FileDescriptor"))
            .and_then(|v| v.as_signed_integer())
            .ok_or_else(|| format!("FileDescriptor missing in reply: {}", show(&response)))
    }

    pub(crate) async fn read_chunk(
        &mut self,
        fd: i64,
        offset: u64,
        length: usize,
    ) -> Result<Vec<u8>, String> {
        let response = self
            .file_operation(
                "ReadFile",
                Dictionary::from_iter([
                    ("FileDescriptor".to_string(), XPCObject::Int64(fd)),
                    ("Offset".to_string(), XPCObject::UInt64(offset)),
                    ("Length".to_string(), XPCObject::Int64(length as i64)),
                ]),
            )
            .await?;
        response
            .as_dictionary()
            .and_then(|d| d.get("FileData"))
            .and_then(plist_data)
            .ok_or_else(|| format!("FileData missing in reply: {}", show(&response)))
    }

    #[allow(dead_code)]
    async fn write_chunk(&mut self, fd: i64, offset: u64, data: Vec<u8>) -> Result<(), String> {
        self.file_operation(
            "WriteFile",
            Dictionary::from_iter([
                ("FileDescriptor".to_string(), XPCObject::Int64(fd)),
                ("Offset".to_string(), XPCObject::UInt64(offset)),
                ("FileData".to_string(), XPCObject::Data(data)),
            ]),
        )
        .await
        .map(|_| ())
    }

    pub(crate) async fn read_symbolic_link(&mut self, path: &str) -> Result<String, String> {
        let response = self
            .file_operation(
                "ReadSymbolicLink",
                Dictionary::from_iter([("Path".to_string(), XPCObject::String(path.into()))]),
            )
            .await?;
        response
            .as_dictionary()
            .and_then(|d| d.get("TargetPath"))
            .and_then(|v| v.as_string())
            .map(|s| s.to_string())
            .ok_or_else(|| format!("TargetPath missing in reply: {}", show(&response)))
    }

    pub(crate) async fn close_file(&mut self, fd: i64) -> Result<(), String> {
        self.file_operation(
            "CloseFile",
            Dictionary::from_iter([("FileDescriptor".to_string(), XPCObject::Int64(fd))]),
        )
        .await
        .map(|_| ())
    }

    async fn create_directory(&mut self, path: &str) -> Result<(), String> {
        self.file_operation(
            "CreateDirectory",
            Dictionary::from_iter([("Path".to_string(), XPCObject::String(path.into()))]),
        )
        .await
        .map(|_| ())
    }

    async fn remove(&mut self, path: &str) -> Result<(), String> {
        // Try a plain file/symlink first; fall back to removing an empty dir.
        let file = self
            .file_operation(
                "RemoveFile",
                Dictionary::from_iter([("Path".to_string(), XPCObject::String(path.into()))]),
            )
            .await;
        if file.is_ok() {
            return Ok(());
        }
        self.file_operation(
            "RemoveDirectory",
            Dictionary::from_iter([("Path".to_string(), XPCObject::String(path.into()))]),
        )
        .await
        .map(|_| ())
    }

    /// Recursive delete that never descends into a symlink: a link is removed
    /// as a single entry (its target is never touched).
    async fn remove_tree(&mut self, path: &str, logger: &Logger) -> Result<(), String> {
        let attrs = self.attributes(path).await?;
        if attrs.is_link || !attrs.is_dir {
            return self.remove(path).await;
        }
        let base = path.trim_end_matches('/');
        for name in self.list(path).await? {
            if name == "." || name == ".." {
                continue;
            }
            let child = format!("{base}/{name}");
            if let Err(e) = Box::pin(self.remove_tree(&child, logger)).await {
                logger.log(format!("file_service: remove '{child}' failed: {e}"));
                return Err(e);
            }
        }
        self.remove(path).await
    }

    async fn rename(&mut self, old_path: &str, new_path: &str) -> Result<(), String> {
        // rename(2) silently replaces an existing destination; refuse instead.
        if self.attributes(new_path).await.is_ok() {
            return Err("A file or folder with that name already exists".into());
        }
        self.file_operation(
            "Rename",
            Dictionary::from_iter([
                ("OldPath".to_string(), XPCObject::String(old_path.into())),
                ("NewPath".to_string(), XPCObject::String(new_path.into())),
            ]),
        )
        .await
        .map(|_| ())
    }

    async fn write_new_file(&mut self, path: &str, data: &[u8], mode: u64) -> Result<(), String> {
        // Darwin open(2): O_WRONLY | O_CREAT | O_TRUNC
        const FLAGS: i64 = 0x1 | 0x200 | 0x400;
        let fd = self.open_file(path, FLAGS, mode).await?;
        let result = async {
            for (index, chunk) in data.chunks(CHUNK).enumerate() {
                self.write_chunk(fd, (index * CHUNK) as u64, chunk.to_vec())
                    .await?;
            }
            Ok(())
        }
        .await;
        let closed = self.close_file(fd).await;
        result.and(closed)
    }

    async fn file_operation(
        &mut self,
        operation: &str,
        args: Dictionary,
    ) -> Result<plist::Value, String> {
        let mut merged = Dictionary::from_iter([
            (
                "Cmd".to_string(),
                XPCObject::String("FileSystemOperation".into()),
            ),
            (
                "OperationType".to_string(),
                XPCObject::String(operation.into()),
            ),
            (
                "SessionID".to_string(),
                XPCObject::String(self.session.clone()),
            ),
        ]);
        for (k, v) in args {
            merged.insert(k, v);
        }
        send_dict(&mut self.client, merged).await
    }
}

/// The subset of `GetAttributes` we display.
pub(crate) struct Attributes {
    pub(crate) is_dir: bool,
    pub(crate) is_link: bool,
    pub(crate) size: u64,
    pub(crate) modified: String,
    pub(crate) created: String,
}

impl Attributes {
    fn parse(text: &str) -> Result<Self, String> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|e| format!("attributes JSON: {e}"))?;
        let kind = value
            .get("fileType")
            .and_then(|v| v.as_str())
            .unwrap_or("regular");
        Ok(Self {
            is_dir: kind == "directory",
            is_link: kind == "symbolicLink",
            size: value.get("size").and_then(|v| v.as_u64()).unwrap_or(0),
            modified: value
                .get("modificationTime")
                .and_then(|v| v.as_f64())
                .map(|t| format_cf_date(t))
                .unwrap_or_default(),
            created: value
                .get("creationTime")
                .and_then(|v| v.as_f64())
                .map(|t| format_cf_date(t))
                .unwrap_or_default(),
        })
    }
}

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

/// Send one OPACK dictionary on the root channel and return the reply.
async fn send_dict<R: idevice::ReadWrite>(
    client: &mut RemoteXpcClient<R>,
    dict: Dictionary,
) -> Result<plist::Value, String> {
    client
        .send_object(XPCObject::Dictionary(dict), true)
        .await
        .map_err(|e| format!("FileService send failed: {e:?}"))?;
    // CreateSession is answered on the reply channel, later commands on the
    // root channel; wait on both.
    let value = client
        .recv_any()
        .await
        .map_err(|e| format!("FileService reply failed: {e:?}"))?;
    let reply = value.as_dictionary();
    if let Some(encoded) = reply.and_then(|d| d.get("EncodedError")) {
        // The device usually attaches a readable message next to the error.
        let detail = reply
            .and_then(|d| d.get("LocalizedDescription"))
            .and_then(|v| v.as_string())
            .map(|s| s.to_string())
            .or_else(|| {
                encoded
                    .as_dictionary()
                    .and_then(|d| d.get("NSLocalizedDescription"))
                    .and_then(|v| v.as_string())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| format!("{encoded:?}"));
        return Err(format!("device refused the request: {detail}"));
    }
    if let Some(err) = reply.and_then(|d| d.get("CoreDevice.error")) {
        return Err(format!("device refused the request: {err:?}"));
    }
    Ok(value)
}

/// UUID-shaped request id (the device only needs uniqueness, not RFC bits).
fn message_uuid() -> String {
    let h = exploit::random_hex(16);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

fn show(value: &plist::Value) -> String {
    match value {
        plist::Value::Dictionary(d) => d.keys().map(String::as_str).collect::<Vec<_>>().join(", "),
        other => format!("{other:?}"),
    }
}

/// `GetAttributes` sends the attributes as JSON bytes (sometimes as a string).
fn attribute_text(value: &plist::Value) -> Option<String> {
    match value {
        plist::Value::String(s) => Some(s.clone()),
        plist::Value::Data(bytes) => String::from_utf8(bytes.clone()).ok(),
        _ => None,
    }
}

fn plist_data(value: &plist::Value) -> Option<Vec<u8>> {
    match value {
        plist::Value::Data(bytes) => Some(bytes.clone()),
        plist::Value::String(s) => Some(s.clone().into_bytes()),
        _ => None,
    }
}

/// CoreFoundation timestamps count seconds from 2001-01-01, not 1970.
fn format_cf_date(seconds: f64) -> String {
    const EPOCH: i64 = 978_307_200;
    let unix = EPOCH + seconds as i64;
    let days = unix.div_euclid(86_400);
    let rem = unix.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant's days→date algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ---------------------------------------------------------------------------
// High-level helpers used by the engine and the access probe
// ---------------------------------------------------------------------------

pub(crate) async fn list_entries(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    directory: &str,
    logger: &Logger,
) -> Result<Vec<serde_json::Value>, String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, true, logger)
            .await?;
    let names = session.list(directory).await?;
    let base = directory.trim_end_matches('/');
    let mut entries = Vec::new();
    for name in names.into_iter().take(MAX_ENTRY) {
        if name == "." || name == ".." {
            continue;
        }
        let path = if base.is_empty() || base == "." {
            name.clone()
        } else {
            format!("{base}/{name}")
        };
        match session.attributes(&path).await {
            Ok(attrs) => entries.push(json!({
                "name": name,
                "isDir": attrs.is_dir,
                "isLink": attrs.is_link,
                "size": attrs.size,
                "modified": attrs.modified,
                "created": attrs.created,
            })),
            Err(e) => {
                logger.log(format!("file_service: attributes for '{path}' failed: {e}"));
                entries.push(json!({
                    "name": name,
                    "isDir": false,
                    "isLink": false,
                    "size": 0,
                    "modified": "",
                    "created": "",
                }));
            }
        }
    }
    Ok(entries)
}

pub(crate) async fn stat_entry(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    name: &str,
    logger: &Logger,
) -> Result<serde_json::Value, String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, true, logger)
            .await?;
    let attrs = session.attributes(path).await?;
    Ok(json!({
        "name": name,
        "isDir": attrs.is_dir,
        "isLink": attrs.is_link,
        "size": attrs.size,
        "modified": attrs.modified,
        "created": attrs.created,
    }))
}

pub(crate) async fn read_to_local(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    dest: &str,
    logger: &Logger,
) -> Result<u64, String> {
    use tokio::io::AsyncWriteExt;
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, true, logger)
            .await?;
    let fd = session.open_file(path, 0, 0o644).await?;
    let mut file = tokio::fs::File::create(dest)
        .await
        .map_err(|e| format!("create {dest}: {e}"))?;
    let mut offset = 0u64;
    let result = loop {
        match session.read_chunk(fd, offset, CHUNK).await {
            Ok(chunk) if chunk.is_empty() => break Ok(offset),
            Ok(chunk) => {
                if let Err(e) = file.write_all(&chunk).await {
                    break Err(format!("write {dest}: {e}"));
                }
                offset += chunk.len() as u64;
            }
            Err(e) => break Err(e),
        }
    };
    let _ = session.close_file(fd).await;
    let _ = file.flush().await;
    result
}

pub(crate) async fn mkdir(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    logger: &Logger,
) -> Result<(), String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, false, logger)
            .await?;
    session.create_directory(path).await
}

pub(crate) async fn remove(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    logger: &Logger,
) -> Result<(), String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, false, logger)
            .await?;
    session.remove(path).await
}

pub(crate) async fn remove_tree(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    logger: &Logger,
) -> Result<(), String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, false, logger)
            .await?;
    session.remove_tree(path, logger).await
}

pub(crate) async fn exists(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    logger: &Logger,
) -> Result<bool, String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, true, logger)
            .await?;
    match session.attributes(path).await {
        Ok(_) => Ok(true),
        Err(e) if e.contains("No such file") || e.contains("does not exist") => Ok(false),
        Err(e) => Err(e),
    }
}

pub(crate) async fn rename(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    old_path: &str,
    new_path: &str,
    logger: &Logger,
) -> Result<(), String> {
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, false, logger)
            .await?;
    session.rename(old_path, new_path).await
}

pub(crate) async fn write_from_local(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    path: &str,
    src_local_path: &str,
    logger: &Logger,
) -> Result<u64, String> {
    let data = std::fs::read(src_local_path).map_err(|e| format!("read {src_local_path}: {e}"))?;
    let domain = Domain::for_container(container_path);
    let (mut session, _) =
        Session::open_for_container(tunnel, domain, identifier, container_path, false, logger)
            .await?;
    session.write_new_file(path, &data, 0o644).await?;
    Ok(data.len() as u64)
}

/// Probe used by the automatic access check. Tries, in order:
///   1. the identifier (bundle id / group id) as user "mobile";
///   2. the container UUID as user "mobile" (open_for_container does both);
///   3. the identifier as user "root";
/// and always finishes with a `temporary`-domain control session, so the log
/// can tell "the service works but iOS refuses this container's lookup" apart
/// from "the service is unusable". This mirrors what the stock file browser
/// apps see on iOS 27 for App Store containers.
pub(crate) async fn probe_service(
    tunnel: &mut AppDeviceTunnel,
    container_path: &str,
    identifier: &str,
    logger: &Logger,
) -> Result<String, String> {
    let mut tried: Vec<String> = Vec::new();
    let domain = Domain::for_container(container_path);

    if !identifier.is_empty() {
        match Session::open_as(tunnel, domain, identifier, "mobile", logger).await {
            Ok(mut session) => match session.list(".").await {
                Ok(names) => {
                    return Ok(format!(
                        "fileservice: granted via '{identifier}' ({} entries in the container root)",
                        names.len()
                    ));
                }
                Err(e) => tried.push(format!(
                    "id '{identifier}': session ok but list failed: {e}"
                )),
            },
            Err(e) => tried.push(format!("id '{identifier}': {e}")),
        }

        let uuid = uuid_of(container_path);
        if !uuid.is_empty() && uuid != identifier {
            match Session::open_as(tunnel, domain, uuid, "mobile", logger).await {
                Ok(mut session) => match session.list(".").await {
                    Ok(names) => {
                        return Ok(format!(
                            "fileservice: granted via container UUID '{uuid}' ({} entries)",
                            names.len()
                        ));
                    }
                    Err(e) => tried.push(format!("uuid '{uuid}': session ok but list failed: {e}")),
                },
                Err(e) => tried.push(format!("uuid '{uuid}': {e}")),
            }
        }

        match Session::open_as(tunnel, domain, identifier, "root", logger).await {
            Ok(mut session) => match session.list(".").await {
                Ok(names) => {
                    return Ok(format!(
                        "fileservice: granted as user 'root' via '{identifier}' ({} entries)",
                        names.len()
                    ));
                }
                Err(e) => tried.push(format!("user root: session ok but list failed: {e}")),
            },
            Err(e) => tried.push(format!("user root: {e}")),
        }
    } else {
        tried.push("no identifier for this container".into());
    }

    // Control: does the service open sessions at all?
    match Session::open_as(tunnel, Domain::Temporary, "", "mobile", logger).await {
        Ok(mut session) => match session.list(".").await {
            Ok(names) => tried.push(format!(
                "control (temporary domain): granted ({} entries) — the service works, iOS refuses this container's lookup",
                names.len()
            )),
            Err(e) => tried.push(format!("control (temporary domain): session ok, list failed: {e}")),
        },
        Err(e) => tried.push(format!("control (temporary domain): {e}")),
    }

    Err(format!(
        "device refused every FileService variant — {}",
        tried.join(" | ")
    ))
}

// ---------------------------------------------------------------------------
// FFI: list a directory in a container (one domain)
// ---------------------------------------------------------------------------

pub unsafe fn list_directory(
    pairing_path: *const c_char,
    container_path: *const c_char,
    identifier: *const c_char,
    directory: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let container_path = opt_str(container_path, "");
    let identifier = opt_str(identifier, "");
    let directory = opt_str(directory, ".");
    let ctx_usize = ctx as usize;

    if !crate::fsengine::allowed_container(&container_path) {
        if !out_error.is_null() {
            *out_error = cstr("container_path is not allowed");
        }
        return 1;
    }

    if identifier.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("identifier is required");
        }
        return 1;
    }

    let res = crate::ffi_util::run_with_large_stack("al_file_service_list", move || {
        let logger = Logger {
            cb: log_cb,
            ctx: ctx_usize as *mut c_void,
        };
        idevice_ffi::run_sync_local(list_async(
            pairing_path.clone(),
            container_path.clone(),
            identifier.clone(),
            directory.clone(),
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

async fn list_async(
    pairing_path: String,
    container_path: String,
    identifier: String,
    directory: String,
    logger: &Logger,
) -> Result<String, String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
    let entries = list_entries(
        &mut tunnel,
        &container_path,
        &identifier,
        &directory,
        logger,
    )
    .await?;
    serde_json::to_string_pretty(&json!({ "directory": directory, "entries": entries }))
        .map_err(|e| e.to_string())
}
