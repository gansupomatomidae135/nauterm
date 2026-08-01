use std::ffi::{c_char, c_void};
use std::ptr;
use std::slice;

use crate::pty::WakeupCallback;
use crate::terminal::{TerminalEngine, TerminalSearchDirection, TerminalSearchResult};

use super::common::{guard, string_from_ptr, string_to_c_ptr, terminal_options_from_args};
use super::snapshot::{free_snapshot, snapshot_into_ffi, FfiTerminalSnapshot};

fn engine_mut<'a>(handle: *mut TerminalEngine) -> Option<&'a mut TerminalEngine> {
    if handle.is_null() {
        None
    } else {
        Some(unsafe { &mut *handle })
    }
}

#[no_mangle]
pub extern "C" fn nauterm_terminal_create(columns: u32, rows: u32) -> *mut TerminalEngine {
    guard(ptr::null_mut(), || {
        let engine = TerminalEngine::new(columns as usize, rows as usize);
        Box::into_raw(Box::new(engine))
    })
}

#[no_mangle]
pub extern "C" fn nauterm_terminal_create_configured(
    columns: u32,
    rows: u32,
    scrollback_lines: u32,
    terminal_type: *const c_char,
    color_term: u32,
    osc52_mode: u32,
    cursor_shape: u32,
    cursor_blinking: bool,
    default_foreground: u32,
    default_background: u32,
    default_cursor: u32,
) -> *mut TerminalEngine {
    guard(ptr::null_mut(), || {
        let options = terminal_options_from_args(
            scrollback_lines,
            terminal_type,
            color_term,
            osc52_mode,
            cursor_shape,
            cursor_blinking,
            default_foreground,
            default_background,
            default_cursor,
            ptr::null(),
            ptr::null(),
            ptr::null(),
        );
        let engine = TerminalEngine::new_with_options(columns as usize, rows as usize, options);
        Box::into_raw(Box::new(engine))
    })
}

/// # Safety
///
/// `handle` must either be null or a pointer returned by `nauterm_terminal_create`.
/// After this call returns, the handle must not be used again.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_destroy(handle: *mut TerminalEngine) {
    guard((), || {
        if !handle.is_null() {
            drop(unsafe { Box::from_raw(handle) });
        }
    });
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_resize(
    handle: *mut TerminalEngine,
    columns: u32,
    rows: u32,
) {
    guard((), || {
        if let Some(engine) = engine_mut(handle) {
            engine.resize(columns as usize, rows as usize);
        }
    });
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_scroll_lines(
    handle: *mut TerminalEngine,
    lines: i32,
) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };

        engine.scroll_lines(lines);
        true
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_scroll_page_up(handle: *mut TerminalEngine) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };

        engine.scroll_page_up();
        true
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_scroll_page_down(handle: *mut TerminalEngine) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };

        engine.scroll_page_down();
        true
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. `query` must either be null or a valid
/// null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_search(
    handle: *mut TerminalEngine,
    query: *const c_char,
    direction: u32,
    origin_row: u32,
    origin_column: u32,
) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let Some(engine) = engine_mut(handle) else {
            return string_to_c_ptr(
                serde_json::to_string(&TerminalSearchResult::not_found(0, 0))
                    .unwrap_or_else(|_| "{}".to_owned()),
            );
        };

        let query = string_from_ptr(query).unwrap_or_default();
        let result = engine.search(
            &query,
            TerminalSearchDirection::from_u32(direction),
            origin_row as usize,
            origin_column as usize,
        );
        string_to_c_ptr(serde_json::to_string(&result).unwrap_or_else(|_| "{}".to_owned()))
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. The returned string must be released with
/// `nauterm_string_free`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_plain_text(handle: *mut TerminalEngine) -> *mut c_char {
    guard(ptr::null_mut(), || {
        engine_mut(handle)
            .map(|engine| string_to_c_ptr(engine.plain_text()))
            .unwrap_or(ptr::null_mut())
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. The returned string must be released with
/// `nauterm_string_free`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_selection_text(
    handle: *mut TerminalEngine,
    start: i64,
    end: i64,
) -> *mut c_char {
    guard(ptr::null_mut(), || {
        engine_mut(handle)
            .map(|engine| string_to_c_ptr(engine.selection_text(start, end)))
            .unwrap_or(ptr::null_mut())
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. The returned string must be released with
/// `nauterm_string_free`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_command_block_at(
    handle: *mut TerminalEngine,
    offset: i64,
) -> *mut c_char {
    guard(ptr::null_mut(), || {
        let Some(engine) = engine_mut(handle) else {
            return ptr::null_mut();
        };
        string_to_c_ptr(
            serde_json::to_string(&engine.command_block_at(offset))
                .unwrap_or_else(|_| "null".to_owned()),
        )
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_start_local_pty(handle: *mut TerminalEngine) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };

        engine.start_local_pty()
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. `callback`, when present, must remain valid until
/// this function is called again with `None` or the terminal handle is destroyed.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_set_wakeup_callback(
    handle: *mut TerminalEngine,
    callback: Option<extern "C" fn(*mut c_void)>,
    user_data: *mut c_void,
) {
    guard((), || {
        if let Some(engine) = engine_mut(handle) {
            engine.set_wakeup_callback(
                callback.map(|callback| WakeupCallback::new(callback, user_data)),
            );
        }
    });
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_poll_local_pty(handle: *mut TerminalEngine) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };

        engine.pump_local_pty()
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_write_codepoint(
    handle: *mut TerminalEngine,
    codepoint: u32,
) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };
        let Some(character) = char::from_u32(codepoint) else {
            return false;
        };

        engine.write_char(character);
        true
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_send_input_codepoint(
    handle: *mut TerminalEngine,
    codepoint: u32,
) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };
        let Some(character) = char::from_u32(codepoint) else {
            return false;
        };

        engine.send_input_char(character)
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. When `len` is non-zero, `bytes` must point to at
/// least `len` readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_write_bytes(
    handle: *mut TerminalEngine,
    bytes: *const u8,
    len: usize,
) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };
        if len == 0 {
            return true;
        }
        if bytes.is_null() {
            return false;
        }

        let bytes = unsafe { slice::from_raw_parts(bytes, len) };
        engine.write_bytes_without_capture(bytes);
        true
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. When `len` is non-zero, `bytes` must point to at
/// least `len` readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_send_input_bytes(
    handle: *mut TerminalEngine,
    bytes: *const u8,
    len: usize,
) -> bool {
    guard(false, || {
        let Some(engine) = engine_mut(handle) else {
            return false;
        };
        if len == 0 {
            return true;
        }
        if bytes.is_null() {
            return false;
        }

        let bytes = unsafe { slice::from_raw_parts(bytes, len) };
        engine.send_input_bytes(bytes)
    })
}

/// # Safety
///
/// `handle` must either be null or a live pointer returned by
/// `nauterm_terminal_create`. The returned snapshot must be released with
/// `nauterm_terminal_free_snapshot`.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_snapshot(
    handle: *mut TerminalEngine,
) -> *mut FfiTerminalSnapshot {
    guard(ptr::null_mut(), || {
        let Some(engine) = engine_mut(handle) else {
            return ptr::null_mut();
        };

        let snapshot = engine.snapshot();
        Box::into_raw(Box::new(snapshot_into_ffi(snapshot)))
    })
}

/// # Safety
///
/// `snapshot` must either be null or a pointer returned by
/// `nauterm_terminal_snapshot`. After this call returns, the snapshot pointer
/// must not be used again.
#[no_mangle]
pub unsafe extern "C" fn nauterm_terminal_free_snapshot(snapshot: *mut FfiTerminalSnapshot) {
    guard((), || unsafe { free_snapshot(snapshot) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_snapshot_round_trip() {
        let handle = nauterm_terminal_create(4, 1);
        assert!(!handle.is_null());

        unsafe {
            assert!(nauterm_terminal_write_codepoint(handle, 'A' as u32));

            let snapshot = nauterm_terminal_snapshot(handle);
            assert!(!snapshot.is_null());
            assert_eq!((*snapshot).columns, 4);
            assert_eq!((*snapshot).rows, 1);
            assert_eq!((*snapshot).cells_len, 4);

            let cells = slice::from_raw_parts((*snapshot).cells, (*snapshot).cells_len);
            assert_eq!(cells[0].text_len, 1);

            nauterm_terminal_free_snapshot(snapshot);
            nauterm_terminal_destroy(handle);
        }
    }

    #[test]
    fn ffi_create_configured_uses_options() {
        let terminal_type = c"xterm-16color";
        let handle = nauterm_terminal_create_configured(
            4,
            1,
            2000,
            terminal_type.as_ptr(),
            1,
            0,
            2,
            true,
            0x383a42,
            0xfafafa,
            0x526fff,
        );
        assert!(!handle.is_null());

        unsafe {
            let snapshot = nauterm_terminal_snapshot(handle);
            assert!(!snapshot.is_null());
            assert_eq!((*snapshot).cursor_shape, 2);
            assert_eq!((*snapshot).cursor_blinking, 1);

            nauterm_terminal_free_snapshot(snapshot);
            nauterm_terminal_destroy(handle);
        }
    }
}
