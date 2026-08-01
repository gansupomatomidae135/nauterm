use std::ffi::c_void;
#[cfg(unix)]
use std::ffi::{CStr, CString};
use std::io::{self, ErrorKind, Read, Write};
use std::num::NonZeroUsize;
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use alacritty_terminal::event::{OnResize, WindowSize};
use alacritty_terminal::tty::{self, EventedPty, EventedReadWrite, Options, Pty, Shell};
use polling::{Event as PollingEvent, Events, PollMode, Poller};

use crate::output_queue::{append_output, clear_output, drain_output_chunk};
use crate::terminal::{TerminalCommand, TerminalGeometry, TerminalOptions};

const CELL_WIDTH_PIXELS: u16 = 8;
const CELL_HEIGHT_PIXELS: u16 = 16;
const PTY_READ_BUFFER_SIZE: usize = 64 * 1024;
const PTY_MAX_READ_BURST_BYTES: usize = 16 * 1024;
#[cfg(windows)]
const PTY_READ_WRITE_TOKEN: usize = 2;
#[cfg(not(windows))]
const PTY_READ_WRITE_TOKEN: usize = 0;
const PTY_CHILD_EVENT_TOKEN: usize = 1;

pub struct LocalPty {
    commands: PtyCommandSender,
    exited: Arc<AtomicBool>,
    input_visible: Arc<AtomicBool>,
    output: Arc<Mutex<Vec<u8>>>,
    wakeup: WakeupSlot,
    worker: Option<JoinHandle<()>>,
}

pub struct PtyPump {
    pub output: Vec<u8>,
    pub exited: bool,
    pub has_more: bool,
}

#[derive(Clone, Copy)]
pub struct WakeupCallback {
    callback: extern "C" fn(*mut c_void),
    user_data: usize,
}

type WakeupSlot = Arc<Mutex<Option<WakeupCallback>>>;
static WAKEUP_CALLBACKS_ENABLED: AtomicBool = AtomicBool::new(true);

enum PtyCommand {
    Input(Vec<u8>),
    Resize(TerminalGeometry),
    Shutdown,
}

struct PtyCommandSender {
    poller: Arc<Poller>,
    sender: Sender<PtyCommand>,
}

impl LocalPty {
    pub fn spawn(
        geometry: TerminalGeometry,
        terminal_options: &TerminalOptions,
    ) -> io::Result<Self> {
        let mut options = Options::default();
        if let Some(command) = &terminal_options.command {
            options.shell = shell_for_command_session(command);
        } else if let Some(shell_path) = &terminal_options.shell_path {
            options.shell = shell_for_local_session(shell_path);
        } else {
            options.shell = default_local_shell();
        }
        options.working_directory =
            resolve_working_directory(terminal_options.working_directory.as_deref());
        options.env.insert(
            "TERM".to_owned(),
            terminal_options.terminal_type.term().to_owned(),
        );
        if let Some(color_term) = terminal_options.color_term.env_value() {
            options
                .env
                .insert("COLORTERM".to_owned(), color_term.to_owned());
        }
        for entry in &terminal_options.environment {
            let variable = entry.variable.trim();
            if variable.is_empty() || variable.contains('=') {
                continue;
            }
            options.env.insert(variable.to_owned(), entry.value.clone());
        }
        configure_history_filtering(&mut options, terminal_options.shell_path.as_deref());

        let pty = tty::new(&options, window_size(geometry), 0)?;
        let poller = Arc::new(Poller::new()?);
        let (sender, receiver) = mpsc::channel();
        let exited = Arc::new(AtomicBool::new(false));
        let input_visible = Arc::new(AtomicBool::new(true));
        let output = Arc::new(Mutex::new(Vec::new()));
        let wakeup = Arc::new(Mutex::new(None));

        let worker = spawn_pty_worker(
            pty,
            poller.clone(),
            receiver,
            exited.clone(),
            input_visible.clone(),
            output.clone(),
            wakeup.clone(),
        )?;

        Ok(Self {
            commands: PtyCommandSender { poller, sender },
            exited,
            input_visible,
            output,
            wakeup,
            worker: Some(worker),
        })
    }

    pub fn resize(&mut self, geometry: TerminalGeometry) {
        self.commands.send(PtyCommand::Resize(geometry));
    }

    pub fn queue_input(&mut self, bytes: &[u8]) {
        self.commands.send(PtyCommand::Input(bytes.to_vec()));
    }

    pub fn set_wakeup_callback(&mut self, callback: Option<WakeupCallback>) {
        if let Ok(mut wakeup) = self.wakeup.lock() {
            *wakeup = callback;
        }
        notify_wakeup(&self.wakeup);
    }

    pub fn input_visible(&self) -> bool {
        self.input_visible.load(Ordering::Acquire)
    }

    pub fn drain_output(&mut self) -> PtyPump {
        let (output, has_more) = drain_output_chunk(&self.output);
        if has_more {
            notify_wakeup(&self.wakeup);
        }
        let exited = self.exited.load(Ordering::Acquire);

        PtyPump {
            output,
            exited,
            has_more,
        }
    }

    pub fn clear_pending_output(&mut self) {
        clear_output(&self.output);
    }
}

fn shell_for_command_session(command: &TerminalCommand) -> Option<Shell> {
    let program = command.program.trim();
    if program.is_empty() {
        return None;
    }
    Some(Shell::new(program.to_owned(), command.args.clone()))
}

#[cfg(target_os = "macos")]
fn shell_for_local_session(shell_path: &str) -> Option<Shell> {
    let shell_program = resolve_shell_program(shell_path)?;
    let Some(user) = std::env::var("USER").ok().filter(|user| !user.is_empty()) else {
        return Some(Shell::new(shell_program, Vec::new()));
    };
    let home = std::env::var("HOME").unwrap_or_default();
    let has_home_hushlogin = !home.is_empty() && Path::new(&home).join(".hushlogin").exists();
    let flags = if has_home_hushlogin { "-qflp" } else { "-flp" };
    let mut args = vec![flags.to_owned(), user, shell_program.clone()];
    args.extend(macos_login_shell_args(&shell_program));

    Some(Shell::new("/usr/bin/login".to_owned(), args))
}

#[cfg(target_os = "macos")]
fn macos_login_shell_args(shell_program: &str) -> Vec<String> {
    match shell_name(shell_program) {
        Some("zsh") => vec!["-l".to_owned(), "--histignorespace".to_owned()],
        Some("fish") => vec!["--login".to_owned()],
        Some("bash" | "dash" | "sh" | "ksh" | "ksh93" | "mksh" | "csh" | "tcsh" | "ash") => {
            vec!["-l".to_owned()]
        }
        Some("pwsh" | "powershell") => vec!["-Login".to_owned()],
        _ => Vec::new(),
    }
}

#[cfg(not(target_os = "macos"))]
fn shell_for_local_session(shell_path: &str) -> Option<Shell> {
    resolve_shell_program(shell_path).map(|program| {
        let args = if shell_name(&program) == Some("zsh") {
            vec!["--histignorespace".to_owned()]
        } else {
            Vec::new()
        };
        Shell::new(program, args)
    })
}

fn configure_history_filtering(options: &mut Options, shell_path: Option<&str>) {
    let Some(shell_path) = shell_path else {
        return;
    };
    if let Some("bash") = shell_name(shell_path) {
        let history_control = options
            .env
            .get("HISTCONTROL")
            .map(String::as_str)
            .unwrap_or_default();
        if !history_control
            .split(':')
            .any(|value| matches!(value.trim(), "ignorespace" | "ignoreboth"))
        {
            let value = if history_control.is_empty() {
                "ignorespace".to_owned()
            } else {
                format!("ignorespace:{history_control}")
            };
            options.env.insert("HISTCONTROL".to_owned(), value);
        }
    }
}

fn shell_name(shell_path: &str) -> Option<&str> {
    Path::new(shell_path).file_name()?.to_str()
}

#[cfg(windows)]
fn default_local_shell() -> Option<Shell> {
    for shell in ["pwsh.exe", "powershell.exe", "cmd.exe"] {
        if let Some(program) = resolve_shell_program(shell) {
            return Some(Shell::new(program, Vec::new()));
        }
    }
    None
}

#[cfg(not(windows))]
fn default_local_shell() -> Option<Shell> {
    None
}

fn resolve_shell_program(shell_path: &str) -> Option<String> {
    let shell_path = shell_path.trim();
    if shell_path.is_empty() {
        return None;
    }

    let path = Path::new(shell_path);
    if path.is_absolute() || shell_path.contains(std::path::MAIN_SEPARATOR) {
        return path.is_file().then(|| shell_path.to_owned());
    }

    let path_env = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path_env) {
        let candidate = directory.join(shell_path);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }

    None
}

fn resolve_working_directory(path: Option<&Path>) -> Option<PathBuf> {
    let home = user_home_dir();
    let expanded = path.and_then(|path| expand_working_directory(path, home.as_deref()));

    if let Some(path) = expanded {
        if path.is_dir() {
            return Some(path);
        }
    }

    home.map(PathBuf::from).filter(|path| path.is_dir())
}

#[cfg(windows)]
fn user_home_dir() -> Option<String> {
    std::env::var("USERPROFILE")
        .ok()
        .filter(|home| !home.is_empty())
        .or_else(|| {
            let drive = std::env::var("HOMEDRIVE")
                .ok()
                .filter(|drive| !drive.is_empty())?;
            let path = std::env::var("HOMEPATH")
                .ok()
                .filter(|path| !path.is_empty())?;
            Some(format!("{drive}{path}"))
        })
        .or_else(|| std::env::var("HOME").ok().filter(|home| !home.is_empty()))
}

#[cfg(not(windows))]
fn user_home_dir() -> Option<String> {
    std::env::var("HOME").ok().filter(|home| !home.is_empty())
}

fn expand_working_directory(path: &Path, home: Option<&str>) -> Option<PathBuf> {
    let text = path.to_string_lossy().trim().to_owned();
    if text.is_empty() {
        return None;
    }

    if text == "~" {
        return home.map(PathBuf::from);
    }
    if let Some(rest) = text.strip_prefix("~/") {
        return home.map(|home| PathBuf::from(home).join(rest));
    }

    let path = PathBuf::from(text);
    if path.is_absolute() {
        return Some(path);
    }

    home.map(|home| PathBuf::from(home).join(&path))
}

impl Drop for LocalPty {
    fn drop(&mut self) {
        if let Ok(mut wakeup) = self.wakeup.lock() {
            *wakeup = None;
        }
        self.commands.send(PtyCommand::Shutdown);
        join_worker(&mut self.worker, "local PTY");
    }
}

impl WakeupCallback {
    pub fn new(callback: extern "C" fn(*mut c_void), user_data: *mut c_void) -> Self {
        Self {
            callback,
            user_data: user_data as usize,
        }
    }

    pub(crate) fn raw_parts(self) -> (extern "C" fn(*mut c_void), *mut c_void) {
        (self.callback, self.user_data as *mut c_void)
    }

    pub fn call(self) {
        if !WAKEUP_CALLBACKS_ENABLED.load(Ordering::Acquire) {
            return;
        }
        (self.callback)(self.user_data as *mut c_void);
    }
}

pub(crate) fn disable_wakeup_callbacks() {
    WAKEUP_CALLBACKS_ENABLED.store(false, Ordering::Release);
}

pub(crate) fn enable_wakeup_callbacks() {
    WAKEUP_CALLBACKS_ENABLED.store(true, Ordering::Release);
}

pub(crate) fn join_worker(worker: &mut Option<JoinHandle<()>>, name: &str) {
    let Some(worker) = worker.take() else {
        return;
    };
    if worker.thread().id() == thread::current().id() {
        eprintln!("nauterm: refusing to join {name} worker from itself");
        return;
    }
    if worker.join().is_err() {
        eprintln!("nauterm: {name} worker panicked during shutdown");
    }
}

impl PtyCommandSender {
    fn send(&self, command: PtyCommand) {
        let _ = self.sender.send(command);
        let _ = self.poller.notify();
    }
}

fn spawn_pty_worker(
    pty: Pty,
    poller: Arc<Poller>,
    receiver: Receiver<PtyCommand>,
    exited: Arc<AtomicBool>,
    input_visible: Arc<AtomicBool>,
    output: Arc<Mutex<Vec<u8>>>,
    wakeup: WakeupSlot,
) -> io::Result<JoinHandle<()>> {
    thread::Builder::new()
        .name("nauterm-pty".to_owned())
        .spawn(move || run_pty_worker(pty, poller, receiver, exited, input_visible, output, wakeup))
}

fn run_pty_worker(
    mut pty: Pty,
    poller: Arc<Poller>,
    receiver: Receiver<PtyCommand>,
    exited: Arc<AtomicBool>,
    input_visible: Arc<AtomicBool>,
    output: Arc<Mutex<Vec<u8>>>,
    wakeup: WakeupSlot,
) {
    let poll_mode = PollMode::Level;
    let mut interest = PollingEvent::readable(PTY_READ_WRITE_TOKEN);
    if unsafe { pty.register(&poller, interest, poll_mode) }.is_err() {
        terminate_pty(&pty);
        exited.store(true, Ordering::Release);
        notify_wakeup(&wakeup);
        return;
    }
    update_input_visibility(&pty, &input_visible);

    let mut events = Events::with_capacity(NonZeroUsize::new(1024).expect("non-zero capacity"));
    let mut pending_input = Vec::new();

    loop {
        if !drain_commands(&receiver, &mut pty, &mut pending_input) {
            break;
        }
        if flush_pending_input(&mut pty, &mut pending_input).is_err() {
            break;
        }
        update_input_visibility(&pty, &input_visible);
        if sync_write_interest(&mut pty, &poller, &mut interest, poll_mode, &pending_input).is_err()
        {
            break;
        }

        events.clear();
        if let Err(error) = poller.wait(&mut events, None) {
            if error.kind() == ErrorKind::Interrupted {
                continue;
            }
            break;
        }

        if !drain_commands(&receiver, &mut pty, &mut pending_input) {
            break;
        }

        let mut should_stop = false;
        for event in events.iter() {
            match event.key {
                PTY_READ_WRITE_TOKEN => {
                    if event.readable && read_available_output(&mut pty, &output, &wakeup).is_err()
                    {
                        should_stop = true;
                        break;
                    }
                    if event.readable {
                        update_input_visibility(&pty, &input_visible);
                    }
                    if event.writable && flush_pending_input(&mut pty, &mut pending_input).is_err()
                    {
                        should_stop = true;
                        break;
                    }
                    if event.writable {
                        update_input_visibility(&pty, &input_visible);
                    }
                }
                PTY_CHILD_EVENT_TOKEN if pty.next_child_event().is_some() => {
                    exited.store(true, Ordering::Release);
                    notify_wakeup(&wakeup);
                    let _ = pty.deregister(&poller);
                    return;
                }
                _ => {}
            }
        }
        if should_stop {
            break;
        }

        if sync_write_interest(&mut pty, &poller, &mut interest, poll_mode, &pending_input).is_err()
        {
            break;
        }
    }

    let _ = pty.deregister(&poller);
    terminate_pty(&pty);
    exited.store(true, Ordering::Release);
    notify_wakeup(&wakeup);
}

#[cfg(unix)]
fn update_input_visibility(pty: &Pty, input_visible: &Arc<AtomicBool>) {
    let mode = read_slave_input_visibility(pty).or_else(|| read_master_input_visibility(pty));
    if let Some(enabled) = mode {
        input_visible.store(enabled, Ordering::Release);
    }
}

#[cfg(unix)]
fn read_slave_input_visibility(pty: &Pty) -> Option<bool> {
    let path = slave_name_for_pty(pty)?;
    read_input_visibility_from_path(&path)
}

#[cfg(target_os = "macos")]
fn read_master_input_visibility(_pty: &Pty) -> Option<bool> {
    None
}

#[cfg(all(unix, not(target_os = "macos")))]
fn read_master_input_visibility(pty: &Pty) -> Option<bool> {
    read_input_visibility_from_fd(pty.file().as_raw_fd())
}

#[cfg(target_os = "macos")]
fn slave_name_for_pty(pty: &Pty) -> Option<CString> {
    let mut buffer = [0 as libc::c_char; 128];
    let result = unsafe {
        libc::ioctl(
            pty.file().as_raw_fd(),
            libc::TIOCPTYGNAME.into(),
            buffer.as_mut_ptr(),
        )
    };
    if result == 0 {
        return Some(unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_owned());
    }
    slave_name_from_ptsname(pty)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn slave_name_for_pty(pty: &Pty) -> Option<CString> {
    slave_name_from_ptsname(pty)
}

#[cfg(unix)]
fn slave_name_from_ptsname(pty: &Pty) -> Option<CString> {
    let path = unsafe { libc::ptsname(pty.file().as_raw_fd()) };
    if path.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(path) }.to_owned())
}

#[cfg(unix)]
fn read_input_visibility_from_path(path: &CStr) -> Option<bool> {
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_NOCTTY) };
    if fd < 0 {
        return None;
    }
    let result = read_input_visibility_from_fd(fd);
    unsafe {
        libc::close(fd);
    }
    result
}

#[cfg(unix)]
fn read_input_visibility_from_fd(fd: std::os::fd::RawFd) -> Option<bool> {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
    let result = unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) };
    if result == 0 {
        let termios = unsafe { termios.assume_init() };
        let echo = (termios.c_lflag & libc::ECHO) != 0;
        let canonical = (termios.c_lflag & libc::ICANON) != 0;
        return Some(echo || !canonical);
    }
    None
}

#[cfg(not(unix))]
fn update_input_visibility(_pty: &Pty, input_visible: &Arc<AtomicBool>) {
    input_visible.store(true, Ordering::Release);
}

fn drain_commands(
    receiver: &Receiver<PtyCommand>,
    pty: &mut Pty,
    pending_input: &mut Vec<u8>,
) -> bool {
    loop {
        match receiver.try_recv() {
            Ok(PtyCommand::Input(bytes)) => pending_input.extend_from_slice(&bytes),
            Ok(PtyCommand::Resize(geometry)) => pty.on_resize(window_size(geometry)),
            Ok(PtyCommand::Shutdown) | Err(TryRecvError::Disconnected) => return false,
            Err(TryRecvError::Empty) => return true,
        }
    }
}

#[cfg(unix)]
fn terminate_pty(pty: &Pty) {
    let pid = pty.child().id() as libc::pid_t;
    let master_fd = pty.file().as_raw_fd();
    unsafe {
        // Login wrappers can put the interactive shell in a different foreground
        // process group. Killing only the spawned child/group leaves that shell
        // alive and Alacritty's Pty::drop then blocks forever in Child::wait.
        let foreground_pgid = libc::tcgetpgrp(master_fd);
        if foreground_pgid > 0 {
            libc::kill(-foreground_pgid, libc::SIGKILL);
        }
        libc::kill(-pid, libc::SIGKILL);
        libc::kill(pid, libc::SIGKILL);

        // Alacritty waits for the child before dropping its master fd. Replace
        // the master with /dev/null first so the controlling terminal is closed
        // and every process still attached to it receives the kernel hangup.
        // dup2 keeps the owned fd valid, avoiding a double-close when Pty drops.
        let dev_null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR | libc::O_CLOEXEC);
        if dev_null >= 0 && dev_null != master_fd {
            libc::dup2(dev_null, master_fd);
            libc::close(dev_null);
        }
    }
}

#[cfg(not(unix))]
fn terminate_pty(_pty: &Pty) {}

fn flush_pending_input(pty: &mut Pty, pending_input: &mut Vec<u8>) -> io::Result<()> {
    while !pending_input.is_empty() {
        match pty.writer().write(pending_input) {
            Ok(0) => break,
            Ok(written) => {
                pending_input.drain(..written);
            }
            Err(error) if is_transient_io(&error) => break,
            Err(error) => return Err(error),
        }
    }

    Ok(())
}

fn read_available_output(
    pty: &mut Pty,
    output: &Arc<Mutex<Vec<u8>>>,
    wakeup: &WakeupSlot,
) -> io::Result<()> {
    let mut buffer = [0; PTY_READ_BUFFER_SIZE];
    let mut has_output = false;
    let mut bytes_read = 0;

    loop {
        match pty.reader().read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                has_output = true;
                bytes_read += read;
                append_output(output, &buffer[..read]);
                if bytes_read >= PTY_MAX_READ_BURST_BYTES {
                    break;
                }
            }
            Err(error) if is_transient_io(&error) => break,
            #[cfg(target_os = "linux")]
            Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
            Err(error) => return Err(error),
        }
    }

    if has_output {
        notify_wakeup(wakeup);
    }

    Ok(())
}

fn sync_write_interest(
    pty: &mut Pty,
    poller: &Arc<Poller>,
    interest: &mut PollingEvent,
    poll_mode: PollMode,
    pending_input: &[u8],
) -> io::Result<()> {
    let wants_write = !pending_input.is_empty();
    if interest.writable == wants_write {
        return Ok(());
    }

    interest.writable = wants_write;
    pty.reregister(poller, *interest, poll_mode)
}

fn notify_wakeup(wakeup: &WakeupSlot) {
    if let Ok(wakeup) = wakeup.lock() {
        if let Some(callback) = *wakeup {
            callback.call();
        }
    }
}

fn is_transient_io(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::Interrupted | ErrorKind::WouldBlock)
}

fn window_size(geometry: TerminalGeometry) -> WindowSize {
    WindowSize {
        num_lines: geometry.rows as u16,
        num_cols: geometry.columns as u16,
        cell_width: CELL_WIDTH_PIXELS,
        cell_height: CELL_HEIGHT_PIXELS,
    }
}

#[cfg(test)]
mod shutdown_tests {
    #[cfg(target_os = "macos")]
    use super::LocalPty;
    use super::{configure_history_filtering, join_worker};
    #[cfg(target_os = "macos")]
    use crate::terminal::{TerminalGeometry, TerminalOptions};
    use alacritty_terminal::tty::Options;
    use std::sync::atomic::{AtomicBool, Ordering};
    #[cfg(target_os = "macos")]
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::thread;
    #[cfg(target_os = "macos")]
    use std::time::{Duration, Instant};

    #[test]
    fn join_worker_waits_for_completion_and_consumes_handle() {
        let completed = Arc::new(AtomicBool::new(false));
        let worker_completed = completed.clone();
        let mut worker = Some(thread::spawn(move || {
            worker_completed.store(true, Ordering::Release);
        }));

        join_worker(&mut worker, "test");

        assert!(worker.is_none());
        assert!(completed.load(Ordering::Acquire));
    }

    #[test]
    fn bash_sessions_ignore_leading_space_bootstrap_commands() {
        let mut options = Options::default();
        configure_history_filtering(&mut options, Some("/bin/bash"));

        assert_eq!(
            options.env.get("HISTCONTROL").map(String::as_str),
            Some("ignorespace")
        );

        options
            .env
            .insert("HISTCONTROL".to_owned(), "ignoredups".to_owned());
        configure_history_filtering(&mut options, Some("/bin/bash"));
        assert_eq!(
            options.env.get("HISTCONTROL").map(String::as_str),
            Some("ignorespace:ignoredups")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn local_pty_closes_after_login_shell_reaches_first_prompt() {
        let (finished_tx, finished_rx) = mpsc::channel();
        thread::spawn(move || {
            for _ in 0..8 {
                let options = TerminalOptions {
                    shell_path: Some("/bin/zsh".to_owned()),
                    ..TerminalOptions::default()
                };
                let mut pty = LocalPty::spawn(
                    TerminalGeometry {
                        columns: 80,
                        rows: 24,
                    },
                    &options,
                )
                .expect("spawn local PTY");

                let output_deadline = Instant::now() + Duration::from_secs(3);
                while Instant::now() < output_deadline {
                    if !pty.drain_output().output.is_empty() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                drop(pty);
            }
            let _ = finished_tx.send(());
        });

        finished_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("local PTY shutdown must not wait forever for /usr/bin/login");
    }
}
