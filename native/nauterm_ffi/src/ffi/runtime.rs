#[no_mangle]
pub extern "C" fn nauterm_runtime_initialize() {
    crate::pty::enable_wakeup_callbacks();
}

#[no_mangle]
pub extern "C" fn nauterm_runtime_prepare_shutdown() {
    crate::pty::disable_wakeup_callbacks();
    crate::ffi::capture::nauterm_capture_shutdown();
    crate::ffi::session::prepare_sessions_for_runtime_shutdown();
    crate::ssh::cancel_all_sftp_tasks();
    if let Ok(mut manager) = crate::port_forward::port_forward_manager().lock() {
        manager.stop_all();
    }
}
