use russh_sftp::client::SftpSession;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

use super::*;

static NEXT_STAGING_PATH_ID: AtomicU64 = AtomicU64::new(1);

pub(super) async fn list_sftp_directory_entries(
    host: &str,
    port: u16,
    username: &str,
    password: Option<&str>,
    private_key: Option<&str>,
    passphrase: Option<&str>,
    known_hosts_path: Option<&str>,
    proxy: Option<&SshProxyConfig>,
    directory: &str,
    host_key_trust_mode: HostKeyTrustMode,
    cancel: Arc<AtomicBool>,
) -> SftpDirectoryEntries {
    let config = ssh_client_config();
    let events = Arc::new(Mutex::new(Vec::<SessionEvent>::new()));
    let output = Arc::new(Mutex::new(Vec::new()));
    let wakeup = Arc::new(Mutex::new(None));
    let handler = SshClientHandler {
        host: host.to_owned(),
        port,
        known_hosts_path: known_hosts_path.map(PathBuf::from),
        host_key_trust_mode,
        output: output.clone(),
        events: events.clone(),
        wakeup: wakeup.clone(),
    };
    let result = async {
        let mut handle = cancel_on_sftp_cancel(
            &cancel,
            connect_ssh_with_timeout(config, host, port, proxy, handler),
        )
        .await?;

        cancel_on_sftp_cancel(&cancel, async {
            authenticate(
                &mut handle,
                username,
                private_key,
                passphrase,
                password,
                &events,
                &wakeup,
            )
            .await
            .map_err(|error| format!("authentication failed: {error}"))
        })
        .await?;

        let channel = cancel_on_sftp_cancel(&cancel, async {
            handle
                .channel_open_session()
                .await
                .map_err(|error| format!("failed to open SFTP channel: {error}"))
        })
        .await?;
        let channel = cancel_on_sftp_cancel(&cancel, async {
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|error| format!("failed to request SFTP subsystem: {error}"))?;
            Ok(channel)
        })
        .await?;
        let sftp = cancel_on_sftp_cancel(&cancel, async {
            SftpSession::new(channel.into_stream())
                .await
                .map_err(|error| format!("failed to initialize SFTP session: {error}"))
        })
        .await?;
        let resolved_directory =
            cancel_on_sftp_cancel(&cancel, resolve_sftp_directory(&sftp, directory)).await?;
        let read_dir = cancel_on_sftp_cancel(&cancel, async {
            sftp.read_dir(resolved_directory.clone())
                .await
                .map_err(|error| format!("failed to read SFTP directory: {error}"))
        })
        .await?;
        let mut entries = Vec::new();
        for entry in read_dir {
            if cancel.load(Ordering::SeqCst) {
                return Err("SFTP listing cancelled.".to_owned());
            }
            let name = entry.file_name();
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let path = join_remote_path(&resolved_directory, &name);
            let metadata =
                cancel_on_sftp_cancel(&cancel, async { Ok(sftp.metadata(path).await.ok()) })
                    .await?;
            let is_directory = metadata
                .as_ref()
                .map(|metadata| metadata.is_dir())
                .unwrap_or_else(|| entry.file_type().is_dir());
            let modified = metadata.as_ref().and_then(|metadata| metadata.mtime);
            entries.push(SshDirectoryEntry {
                name,
                is_directory,
                size: metadata.and_then(|metadata| metadata.size).unwrap_or(0),
                modified: modified.map(u64::from),
            });
        }
        let _ = sftp.close().await;
        let _ = handle
            .disconnect(russh::Disconnect::ByApplication, "", "en")
            .await;
        entries.sort_by(|a, b| {
            b.is_directory
                .cmp(&a.is_directory)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        entries.dedup_by(|a, b| a.name == b.name && a.is_directory == b.is_directory);
        Ok((resolved_directory, entries))
    }
    .await;
    let captured_events = events
        .lock()
        .map(|events| events.clone())
        .unwrap_or_default();
    match result {
        Ok((directory, entries)) => SftpDirectoryEntries {
            directory,
            entries,
            events: captured_events,
            error: None,
        },
        Err(error) => SftpDirectoryEntries {
            directory: directory.to_owned(),
            entries: Vec::new(),
            events: captured_events,
            error: Some(error),
        },
    }
}

pub(super) async fn open_sftp_session(
    host: &str,
    port: u16,
    username: &str,
    password: Option<&str>,
    private_key: Option<&str>,
    passphrase: Option<&str>,
    known_hosts_path: Option<&str>,
    proxy: Option<&SshProxyConfig>,
    host_key_trust_mode: HostKeyTrustMode,
    events: Arc<Mutex<Vec<SessionEvent>>>,
) -> Result<(client::Handle<SshClientHandler>, SftpSession), String> {
    let config = ssh_client_config();
    let output = Arc::new(Mutex::new(Vec::new()));
    let wakeup = Arc::new(Mutex::new(None));
    let handler = SshClientHandler {
        host: host.to_owned(),
        port,
        known_hosts_path: known_hosts_path.map(PathBuf::from),
        host_key_trust_mode,
        output: output.clone(),
        events: events.clone(),
        wakeup: wakeup.clone(),
    };
    let mut handle = connect_ssh_with_timeout(config, host, port, proxy, handler).await?;
    authenticate(
        &mut handle,
        username,
        private_key,
        passphrase,
        password,
        &events,
        &wakeup,
    )
    .await
    .map_err(|error| format!("authentication failed: {error}"))?;
    let channel = handle
        .channel_open_session()
        .await
        .map_err(|error| format!("failed to open SFTP channel: {error}"))?;
    channel
        .request_subsystem(true, "sftp")
        .await
        .map_err(|error| format!("failed to request SFTP subsystem: {error}"))?;
    let sftp = SftpSession::new(channel.into_stream())
        .await
        .map_err(|error| format!("failed to initialize SFTP session: {error}"))?;
    Ok((handle, sftp))
}

pub(super) async fn open_sudo_sftp_session(
    host: &str,
    port: u16,
    username: &str,
    password: Option<&str>,
    private_key: Option<&str>,
    passphrase: Option<&str>,
    known_hosts_path: Option<&str>,
    proxy: Option<&SshProxyConfig>,
    host_key_trust_mode: HostKeyTrustMode,
    events: Arc<Mutex<Vec<SessionEvent>>>,
    sudo_password: &str,
) -> Result<(client::Handle<SshClientHandler>, SftpSession), String> {
    const SUDO_SFTP_COMMAND: &str = concat!(
        "sudo -k -S -p '' sh -c '",
        "for p in ",
        "/usr/lib/openssh/sftp-server ",
        "/usr/lib/ssh/sftp-server ",
        "/usr/libexec/openssh/sftp-server ",
        "/usr/libexec/sftp-server; ",
        "do if [ -x \"$p\" ]; then exec \"$p\"; fi; done; ",
        "p=$(command -v sftp-server 2>/dev/null) && [ -n \"$p\" ] && exec \"$p\"; ",
        "exit 127'"
    );

    let config = ssh_client_config();
    let output = Arc::new(Mutex::new(Vec::new()));
    let wakeup = Arc::new(Mutex::new(None));
    let handler = SshClientHandler {
        host: host.to_owned(),
        port,
        known_hosts_path: known_hosts_path.map(PathBuf::from),
        host_key_trust_mode,
        output: output.clone(),
        events: events.clone(),
        wakeup: wakeup.clone(),
    };
    let mut handle = connect_ssh_with_timeout(config, host, port, proxy, handler).await?;
    authenticate(
        &mut handle,
        username,
        private_key,
        passphrase,
        password,
        &events,
        &wakeup,
    )
    .await
    .map_err(|error| format!("authentication failed: {error}"))?;
    let channel = handle
        .channel_open_session()
        .await
        .map_err(|error| format!("failed to open sudo SFTP channel: {error}"))?;
    channel
        .exec(false, SUDO_SFTP_COMMAND)
        .await
        .map_err(|error| format!("failed to start sudo SFTP server: {error}"))?;
    let mut password_line = Vec::with_capacity(sudo_password.len() + 1);
    password_line.extend_from_slice(sudo_password.as_bytes());
    password_line.push(b'\n');
    let write_result = channel.data(&password_line[..]).await;
    password_line.zeroize();
    write_result.map_err(|error| format!("failed to send sudo password: {error}"))?;
    let sftp = tokio::time::timeout(
        Duration::from_secs(12),
        SftpSession::new(channel.into_stream()),
    )
    .await
    .map_err(|_| "sudo authentication failed or the privileged SFTP server timed out".to_owned())?
    .map_err(|error| {
        format!("sudo authentication failed or the privileged SFTP server is unavailable: {error}")
    })?;
    Ok((handle, sftp))
}

impl SftpTaskProgress {
    fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }

    fn ensure_not_cancelled(&self) -> Result<(), String> {
        if self.is_cancelled() {
            Err("SFTP task cancelled.".to_owned())
        } else {
            Ok(())
        }
    }

    fn set_total(&mut self, total_bytes: u64, current_path: &str) {
        self.total_bytes = total_bytes;
        self.report(current_path);
    }

    fn add_bytes(&mut self, bytes: u64, current_path: &str) {
        self.transferred_bytes = self.transferred_bytes.saturating_add(bytes);
        self.report(current_path);
    }

    fn report(&self, current_path: &str) {
        let Some(callback) = self.callback else {
            return;
        };
        let _ = current_path;
        callback(
            self.user_data as *mut c_void,
            self.transferred_bytes,
            self.total_bytes,
            ptr::null(),
        );
    }
}

fn local_path_total(path: &Path, cancel: &AtomicBool) -> Result<u64, String> {
    if cancel.load(Ordering::SeqCst) {
        return Err("SFTP task cancelled.".to_owned());
    }
    let metadata = fs::metadata(path)
        .map_err(|error| format!("local path not found {}: {error}", path.display()))?;
    if !metadata.is_dir() {
        return Ok(metadata.len());
    }
    let mut total = 0_u64;
    let mut directories = vec![path.to_path_buf()];
    while let Some(directory) = directories.pop() {
        if cancel.load(Ordering::SeqCst) {
            return Err("SFTP task cancelled.".to_owned());
        }
        let entries = fs::read_dir(&directory).map_err(|error| {
            format!(
                "failed to read local folder {}: {error}",
                directory.display()
            )
        })?;
        for entry in entries {
            if cancel.load(Ordering::SeqCst) {
                return Err("SFTP task cancelled.".to_owned());
            }
            let entry = entry.map_err(|error| {
                format!(
                    "failed to read local folder {}: {error}",
                    directory.display()
                )
            })?;
            let metadata = entry.metadata().map_err(|error| {
                format!(
                    "failed to inspect local path {}: {error}",
                    entry.path().display()
                )
            })?;
            if metadata.is_dir() {
                directories.push(entry.path());
            } else {
                total = total.saturating_add(metadata.len());
            }
        }
    }
    Ok(total)
}

async fn remote_path_total(
    sftp: &SftpSession,
    remote_path: &str,
    progress: &SftpTaskProgress,
) -> Result<u64, String> {
    progress.ensure_not_cancelled()?;
    let metadata = sftp
        .metadata(remote_path.to_owned())
        .await
        .map_err(|error| format!("remote path not found {remote_path}: {error}"))?;
    if !metadata.is_dir() {
        return Ok(metadata.size.unwrap_or(0));
    }
    let mut total = 0_u64;
    let mut directories = vec![remote_path.to_owned()];
    while let Some(remote_dir) = directories.pop() {
        progress.ensure_not_cancelled()?;
        let entries = sftp
            .read_dir(remote_dir.clone())
            .await
            .map_err(|error| format!("failed to read remote directory {remote_dir}: {error}"))?;
        for entry in entries {
            progress.ensure_not_cancelled()?;
            let name = entry.file_name();
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            if entry.file_type().is_dir() {
                directories.push(join_remote_path(&remote_dir, &name));
            } else {
                total = total.saturating_add(entry.metadata().size.unwrap_or(0));
            }
        }
    }
    Ok(total)
}

pub(super) async fn download_sftp_path(
    sftp: &SftpSession,
    remote_path: &str,
    local_path: &Path,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    let total = remote_path_total(sftp, remote_path, progress).await?;
    progress.set_total(total, remote_path);
    let metadata = sftp
        .metadata(remote_path.to_owned())
        .await
        .map_err(|error| format!("remote path not found {remote_path}: {error}"))?;
    if metadata.is_dir() {
        let mut bytes = 0;
        fs::create_dir_all(local_path).map_err(|error| {
            format!(
                "failed to create local folder {}: {error}",
                local_path.display()
            )
        })?;
        let mut directories = vec![(remote_path.to_owned(), local_path.to_path_buf())];
        while let Some((remote_dir, local_dir)) = directories.pop() {
            progress.ensure_not_cancelled()?;
            let entries = sftp.read_dir(remote_dir.clone()).await.map_err(|error| {
                format!("failed to read remote directory {remote_dir}: {error}")
            })?;
            for entry in entries {
                progress.ensure_not_cancelled()?;
                let name = entry.file_name();
                if name.is_empty() || name == "." || name == ".." {
                    continue;
                }
                let child_remote = join_remote_path(&remote_dir, &name);
                let child_local = local_dir.join(&name);
                if entry.file_type().is_dir() {
                    fs::create_dir_all(&child_local).map_err(|error| {
                        format!(
                            "failed to create local folder {}: {error}",
                            child_local.display()
                        )
                    })?;
                    directories.push((child_remote, child_local));
                } else {
                    bytes +=
                        download_sftp_file(sftp, &child_remote, &child_local, progress).await?;
                }
            }
        }
        Ok((bytes, "folder".to_owned()))
    } else {
        let bytes = download_sftp_file(sftp, remote_path, local_path, progress).await?;
        Ok((bytes, "file".to_owned()))
    }
}

async fn download_sftp_file(
    sftp: &SftpSession,
    remote_path: &str,
    local_path: &Path,
    progress: &mut SftpTaskProgress,
) -> Result<u64, String> {
    progress.ensure_not_cancelled()?;
    if let Some(parent) = local_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create local folder {}: {error}",
                parent.display()
            )
        })?;
    }
    let mut remote_file = sftp
        .open(remote_path.to_owned())
        .await
        .map_err(|error| format!("failed to open remote file {remote_path}: {error}"))?;
    let mut local_file = fs::File::create(local_path).map_err(|error| {
        format!(
            "failed to create local file {}: {error}",
            local_path.display()
        )
    })?;
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut bytes = 0;
    loop {
        progress.ensure_not_cancelled()?;
        let read = remote_file
            .read(&mut buffer)
            .await
            .map_err(|error| format!("failed to read remote file {remote_path}: {error}"))?;
        if read == 0 {
            break;
        }
        local_file.write_all(&buffer[..read]).map_err(|error| {
            format!(
                "failed to write local file {}: {error}",
                local_path.display()
            )
        })?;
        bytes += read as u64;
        progress.add_bytes(read as u64, remote_path);
    }
    Ok(bytes)
}

pub(super) async fn upload_sftp_path(
    sftp: &SftpSession,
    local_path: &Path,
    remote_path: &str,
    replace_existing: bool,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    let total = local_path_total(local_path, &progress.cancel)?;
    progress.set_total(total, &local_path.to_string_lossy());
    let metadata = fs::metadata(local_path)
        .map_err(|error| format!("local path not found {}: {error}", local_path.display()))?;
    if !replace_existing && sftp.metadata(remote_path.to_owned()).await.is_ok() {
        return Err(format!("remote target already exists: {remote_path}"));
    }
    let staging_path = unique_remote_staging_path(sftp, remote_path, "upload").await?;
    let upload_result: Result<(u64, String), String> = async {
        if metadata.is_dir() {
            ensure_sftp_directory(sftp, &staging_path).await?;
            let mut bytes = 0;
            let mut directories = vec![(local_path.to_path_buf(), staging_path.clone())];
            while let Some((local_dir, remote_dir)) = directories.pop() {
                progress.ensure_not_cancelled()?;
                let entries = fs::read_dir(&local_dir).map_err(|error| {
                    format!(
                        "failed to read local folder {}: {error}",
                        local_dir.display()
                    )
                })?;
                for entry in entries {
                    progress.ensure_not_cancelled()?;
                    let entry = entry.map_err(|error| {
                        format!(
                            "failed to read local folder {}: {error}",
                            local_dir.display()
                        )
                    })?;
                    let child_local = entry.path();
                    let name = entry.file_name().to_string_lossy().to_string();
                    let child_remote = join_remote_path(&remote_dir, &name);
                    let child_metadata = entry.metadata().map_err(|error| {
                        format!(
                            "failed to inspect local path {}: {error}",
                            child_local.display()
                        )
                    })?;
                    if child_metadata.is_dir() {
                        ensure_sftp_directory(sftp, &child_remote).await?;
                        directories.push((child_local, child_remote));
                    } else {
                        bytes +=
                            upload_sftp_file(sftp, &child_local, &child_remote, false, progress)
                                .await?;
                    }
                }
            }
            Ok((bytes, "folder".to_owned()))
        } else {
            let bytes = upload_sftp_file(sftp, local_path, &staging_path, false, progress).await?;
            Ok((bytes, "file".to_owned()))
        }
    }
    .await;
    let uploaded = match upload_result {
        Ok(uploaded) => uploaded,
        Err(error) => {
            let _ = remove_remote_path_quiet(sftp, &staging_path).await;
            return Err(error);
        }
    };
    if let Err(error) =
        commit_remote_staging_path(sftp, &staging_path, remote_path, replace_existing).await
    {
        let _ = remove_remote_path_quiet(sftp, &staging_path).await;
        return Err(error);
    }
    Ok(uploaded)
}

async fn upload_sftp_file(
    sftp: &SftpSession,
    local_path: &Path,
    remote_path: &str,
    replace_existing: bool,
    progress: &mut SftpTaskProgress,
) -> Result<u64, String> {
    progress.ensure_not_cancelled()?;
    if let Some(parent) = remote_parent_path(remote_path) {
        ensure_sftp_directory(sftp, &parent).await?;
    }
    if !replace_existing && sftp.metadata(remote_path.to_owned()).await.is_ok() {
        return Err(format!("remote target already exists: {remote_path}"));
    }
    let mut local_file = fs::File::open(local_path).map_err(|error| {
        format!(
            "failed to open local file {}: {error}",
            local_path.display()
        )
    })?;
    let mut remote_file = sftp
        .create(remote_path.to_owned())
        .await
        .map_err(|error| format!("failed to create remote file {remote_path}: {error}"))?;
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut bytes = 0;
    loop {
        progress.ensure_not_cancelled()?;
        let read = local_file.read(&mut buffer).map_err(|error| {
            format!(
                "failed to read local file {}: {error}",
                local_path.display()
            )
        })?;
        if read == 0 {
            break;
        }
        remote_file
            .write_all(&buffer[..read])
            .await
            .map_err(|error| format!("failed to write remote file {remote_path}: {error}"))?;
        bytes += read as u64;
        progress.add_bytes(read as u64, &local_path.to_string_lossy());
    }
    remote_file
        .shutdown()
        .await
        .map_err(|error| format!("failed to close remote file {remote_path}: {error}"))?;
    Ok(bytes)
}

pub(super) async fn move_sftp_path(
    sftp: &SftpSession,
    source_path: &str,
    target_path: &str,
    replace_existing: bool,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    progress.ensure_not_cancelled()?;
    if same_remote_path(source_path, target_path) {
        return Err("source and target paths are the same".to_owned());
    }
    let source_metadata = sftp
        .metadata(source_path.to_owned())
        .await
        .map_err(|error| format!("remote path not found {source_path}: {error}"))?;
    if source_metadata.is_dir() && remote_path_is_child(target_path, source_path) {
        return Err("cannot move a folder into itself".to_owned());
    }
    let item_kind = if source_metadata.is_dir() {
        "folder".to_owned()
    } else {
        "file".to_owned()
    };
    if sftp.metadata(target_path.to_owned()).await.is_ok() {
        if !replace_existing {
            return Err(format!("remote target already exists: {target_path}"));
        }
        if remote_path_is_child(source_path, target_path) {
            return Err("cannot replace a path with one of its children".to_owned());
        }
        delete_sftp_path(sftp, target_path, progress).await?;
    }
    progress.set_total(0, source_path);
    if let Some(parent) = remote_parent_path(target_path) {
        ensure_sftp_directory(sftp, &parent).await?;
    }
    sftp.rename(source_path.to_owned(), target_path.to_owned())
        .await
        .map_err(|error| format!("failed to move {source_path} to {target_path}: {error}"))?;
    progress.report(target_path);
    Ok((0, item_kind))
}

pub(super) async fn copy_sftp_path(
    sftp: &SftpSession,
    source_path: &str,
    target_path: &str,
    replace_existing: bool,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    progress.ensure_not_cancelled()?;
    if same_remote_path(source_path, target_path) {
        return Err("source and target paths are the same".to_owned());
    }
    let metadata = sftp
        .metadata(source_path.to_owned())
        .await
        .map_err(|error| format!("remote path not found {source_path}: {error}"))?;
    if metadata.is_dir() && remote_path_is_child(target_path, source_path) {
        return Err("cannot copy a folder into itself".to_owned());
    }
    if sftp.metadata(target_path.to_owned()).await.is_ok() {
        if !replace_existing {
            return Err(format!("remote target already exists: {target_path}"));
        }
        if remote_path_is_child(source_path, target_path) {
            return Err("cannot replace a path with one of its children".to_owned());
        }
        delete_sftp_path(sftp, target_path, progress).await?;
    }
    let total = remote_path_total(sftp, source_path, progress).await?;
    progress.set_total(total, source_path);
    if metadata.is_dir() {
        ensure_sftp_directory(sftp, target_path).await?;
        let mut bytes = 0_u64;
        let mut directories = vec![(source_path.to_owned(), target_path.to_owned())];
        while let Some((source_dir, target_dir)) = directories.pop() {
            progress.ensure_not_cancelled()?;
            let entries = sftp.read_dir(source_dir.clone()).await.map_err(|error| {
                format!("failed to read remote directory {source_dir}: {error}")
            })?;
            for entry in entries {
                progress.ensure_not_cancelled()?;
                let name = entry.file_name();
                if name.is_empty() || name == "." || name == ".." {
                    continue;
                }
                let child_source = join_remote_path(&source_dir, &name);
                let child_target = join_remote_path(&target_dir, &name);
                if entry.file_type().is_dir() {
                    ensure_sftp_directory(sftp, &child_target).await?;
                    directories.push((child_source, child_target));
                } else {
                    bytes = bytes.saturating_add(
                        copy_sftp_file(sftp, &child_source, &child_target, progress).await?,
                    );
                }
            }
        }
        Ok((bytes, "folder".to_owned()))
    } else {
        let bytes = copy_sftp_file(sftp, source_path, target_path, progress).await?;
        Ok((bytes, "file".to_owned()))
    }
}

async fn copy_sftp_file(
    sftp: &SftpSession,
    source_path: &str,
    target_path: &str,
    progress: &mut SftpTaskProgress,
) -> Result<u64, String> {
    progress.ensure_not_cancelled()?;
    if let Some(parent) = remote_parent_path(target_path) {
        ensure_sftp_directory(sftp, &parent).await?;
    }
    let mut source_file = sftp
        .open(source_path.to_owned())
        .await
        .map_err(|error| format!("failed to open remote file {source_path}: {error}"))?;
    let mut target_file = sftp
        .create(target_path.to_owned())
        .await
        .map_err(|error| format!("failed to create remote file {target_path}: {error}"))?;
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut bytes = 0_u64;
    loop {
        progress.ensure_not_cancelled()?;
        let read = source_file
            .read(&mut buffer)
            .await
            .map_err(|error| format!("failed to read remote file {source_path}: {error}"))?;
        if read == 0 {
            break;
        }
        target_file
            .write_all(&buffer[..read])
            .await
            .map_err(|error| format!("failed to write remote file {target_path}: {error}"))?;
        bytes = bytes.saturating_add(read as u64);
        progress.add_bytes(read as u64, source_path);
    }
    target_file
        .shutdown()
        .await
        .map_err(|error| format!("failed to close remote file {target_path}: {error}"))?;
    Ok(bytes)
}

async fn unique_remote_staging_path(
    sftp: &SftpSession,
    target_path: &str,
    purpose: &str,
) -> Result<String, String> {
    let parent = remote_parent_path(target_path).unwrap_or_else(|| ".".to_owned());
    let name = target_path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or("item");
    for _ in 0..100 {
        let id = NEXT_STAGING_PATH_ID.fetch_add(1, AtomicOrdering::Relaxed);
        let candidate = join_remote_path(
            &parent,
            &format!(".{name}.nauterm-{purpose}-{}-{id}.tmp", std::process::id()),
        );
        if sftp.metadata(candidate.clone()).await.is_err() {
            return Ok(candidate);
        }
    }
    Err(format!(
        "failed to allocate a temporary path beside {target_path}"
    ))
}

async fn commit_remote_staging_path(
    sftp: &SftpSession,
    staging_path: &str,
    target_path: &str,
    replace_existing: bool,
) -> Result<(), String> {
    let target_exists = sftp.metadata(target_path.to_owned()).await.is_ok();
    if !target_exists {
        return sftp
            .rename(staging_path.to_owned(), target_path.to_owned())
            .await
            .map_err(|error| {
                format!("failed to publish temporary upload as {target_path}: {error}")
            });
    }
    if !replace_existing {
        return Err(format!("remote target already exists: {target_path}"));
    }

    // Servers implementing POSIX rename semantics replace the destination here
    // atomically. SFTP v3-only servers commonly reject this and use the guarded
    // backup fallback below.
    if sftp
        .rename(staging_path.to_owned(), target_path.to_owned())
        .await
        .is_ok()
    {
        return Ok(());
    }

    let backup_path = unique_remote_staging_path(sftp, target_path, "backup").await?;
    sftp.rename(target_path.to_owned(), backup_path.clone())
        .await
        .map_err(|error| format!("failed to preserve existing target {target_path}: {error}"))?;
    if let Err(error) = sftp
        .rename(staging_path.to_owned(), target_path.to_owned())
        .await
    {
        let restore_error = sftp
            .rename(backup_path.clone(), target_path.to_owned())
            .await
            .err();
        return Err(match restore_error {
            Some(restore_error) => format!(
                "failed to publish {target_path}: {error}; restoring the previous target also failed: {restore_error}"
            ),
            None => format!("failed to publish {target_path}: {error}"),
        });
    }
    let _ = remove_remote_path_quiet(sftp, &backup_path).await;
    Ok(())
}

async fn remove_remote_path_quiet(sftp: &SftpSession, target_path: &str) -> Result<(), String> {
    let metadata = match sftp.metadata(target_path.to_owned()).await {
        Ok(metadata) => metadata,
        Err(_) => return Ok(()),
    };
    if !metadata.is_dir() {
        return sftp
            .remove_file(target_path.to_owned())
            .await
            .map_err(|error| format!("failed to remove temporary file {target_path}: {error}"));
    }
    let mut directories = Vec::new();
    let mut pending = vec![target_path.to_owned()];
    while let Some(directory) = pending.pop() {
        directories.push(directory.clone());
        let entries = sftp
            .read_dir(directory.clone())
            .await
            .map_err(|error| format!("failed to inspect temporary folder {directory}: {error}"))?;
        for entry in entries {
            let name = entry.file_name();
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let child = join_remote_path(&directory, &name);
            if entry.file_type().is_dir() {
                pending.push(child);
            } else {
                sftp.remove_file(child.clone())
                    .await
                    .map_err(|error| format!("failed to remove temporary file {child}: {error}"))?;
            }
        }
    }
    for directory in directories.into_iter().rev() {
        sftp.remove_dir(directory.clone())
            .await
            .map_err(|error| format!("failed to remove temporary folder {directory}: {error}"))?;
    }
    Ok(())
}

pub(super) async fn delete_sftp_path(
    sftp: &SftpSession,
    target_path: &str,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    progress.ensure_not_cancelled()?;
    let total = remote_path_total(sftp, target_path, progress).await?;
    progress.set_total(total, target_path);
    let metadata = sftp
        .metadata(target_path.to_owned())
        .await
        .map_err(|error| format!("remote path not found {target_path}: {error}"))?;
    if metadata.is_dir() {
        let mut bytes = 0_u64;
        let mut directories = Vec::new();
        let mut pending = vec![target_path.to_owned()];
        while let Some(remote_dir) = pending.pop() {
            progress.ensure_not_cancelled()?;
            directories.push(remote_dir.clone());
            let entries = sftp.read_dir(remote_dir.clone()).await.map_err(|error| {
                format!("failed to read remote directory {remote_dir}: {error}")
            })?;
            for entry in entries {
                progress.ensure_not_cancelled()?;
                let name = entry.file_name();
                if name.is_empty() || name == "." || name == ".." {
                    continue;
                }
                let child_path = join_remote_path(&remote_dir, &name);
                if entry.file_type().is_dir() {
                    pending.push(child_path);
                } else {
                    let size = entry.metadata().size.unwrap_or(0);
                    sftp.remove_file(child_path.clone())
                        .await
                        .map_err(|error| {
                            format!("failed to delete remote file {child_path}: {error}")
                        })?;
                    bytes = bytes.saturating_add(size);
                    if size == 0 {
                        progress.report(&child_path);
                    } else {
                        progress.add_bytes(size, &child_path);
                    }
                }
            }
        }
        for remote_dir in directories.iter().rev() {
            progress.ensure_not_cancelled()?;
            sftp.remove_dir(remote_dir.clone())
                .await
                .map_err(|error| format!("failed to delete remote folder {remote_dir}: {error}"))?;
            progress.report(remote_dir);
        }
        Ok((bytes, "folder".to_owned()))
    } else {
        let size = metadata.size.unwrap_or(0);
        sftp.remove_file(target_path.to_owned())
            .await
            .map_err(|error| format!("failed to delete remote file {target_path}: {error}"))?;
        if size == 0 {
            progress.report(target_path);
        } else {
            progress.add_bytes(size, target_path);
        }
        Ok((size, "file".to_owned()))
    }
}

pub(super) async fn mkdir_sftp_path(
    sftp: &SftpSession,
    target_path: &str,
    progress: &mut SftpTaskProgress,
) -> Result<(u64, String), String> {
    progress.ensure_not_cancelled()?;
    progress.set_total(0, target_path);
    if sftp.metadata(target_path.to_owned()).await.is_ok() {
        return Err(format!("remote target already exists: {target_path}"));
    }
    if let Some(parent) = remote_parent_path(target_path) {
        ensure_sftp_directory(sftp, &parent).await?;
    }
    sftp.create_dir(target_path.to_owned())
        .await
        .map_err(|error| format!("failed to create remote folder {target_path}: {error}"))?;
    progress.report(target_path);
    Ok((0, "folder".to_owned()))
}

async fn ensure_sftp_directory(sftp: &SftpSession, path: &str) -> Result<(), String> {
    let normalized = path.trim().trim_end_matches('/');
    if normalized.is_empty() || normalized == "/" || normalized == "." {
        return Ok(());
    }
    if let Ok(metadata) = sftp.metadata(normalized.to_owned()).await {
        if metadata.is_dir() {
            return Ok(());
        }
        return Err(format!(
            "remote path exists and is not a directory: {normalized}"
        ));
    }
    let mut current = if normalized.starts_with('/') {
        "/".to_owned()
    } else {
        String::new()
    };
    for part in normalized.split('/').filter(|part| !part.is_empty()) {
        current = join_remote_path(&current, part);
        if let Ok(metadata) = sftp.metadata(current.clone()).await {
            if metadata.is_dir() {
                continue;
            }
            return Err(format!(
                "remote path exists and is not a directory: {current}"
            ));
        }
        match sftp.create_dir(current.clone()).await {
            Ok(()) => {}
            Err(_) => {
                if !sftp
                    .metadata(current.clone())
                    .await
                    .map(|metadata| metadata.is_dir())
                    .unwrap_or(false)
                {
                    return Err(format!("failed to create remote directory {current}"));
                }
            }
        }
    }
    Ok(())
}

fn remote_parent_path(path: &str) -> Option<String> {
    let trimmed = path.trim().trim_end_matches('/');
    let index = trimmed.rfind('/')?;
    if index == 0 {
        Some("/".to_owned())
    } else {
        Some(trimmed[..index].to_owned())
    }
}

fn same_remote_path(left: &str, right: &str) -> bool {
    normalize_remote_path_for_compare(left) == normalize_remote_path_for_compare(right)
}

fn remote_path_is_child(path: &str, parent: &str) -> bool {
    let path = normalize_remote_path_for_compare(path);
    let parent = normalize_remote_path_for_compare(parent);
    if parent == "/" {
        return path != "/";
    }
    path.starts_with(&format!("{parent}/"))
}

fn normalize_remote_path_for_compare(path: &str) -> String {
    let trimmed = path.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        ".".to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn join_remote_path(left: &str, right: &str) -> String {
    let clean_right = right.trim_matches('/');
    if left.is_empty() || left == "." {
        return clean_right.to_owned();
    }
    if left == "/" {
        return format!("/{clean_right}");
    }
    format!("{}/{}", left.trim_end_matches('/'), clean_right)
}

async fn resolve_sftp_directory(sftp: &SftpSession, directory: &str) -> Result<String, String> {
    let target = if directory == "~" {
        ".".to_owned()
    } else if let Some(rest) = directory.strip_prefix("~/") {
        let home = sftp
            .canonicalize(".")
            .await
            .map_err(|error| format!("failed to resolve SFTP home directory: {error}"))?;
        if rest.is_empty() {
            home
        } else {
            format!("{}/{}", home.trim_end_matches('/'), rest)
        }
    } else {
        directory.to_owned()
    };
    sftp.canonicalize(target.clone())
        .await
        .map_err(|error| format!("failed to resolve SFTP directory {target}: {error}"))
}
