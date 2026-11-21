//! The C ABI the Flutter app calls through `dart:ffi`.
//!
//! `rmc_start` registers a callback that receives every event as a NUL-terminated
//! JSON string, which the app must release with `rmc_free`. The app registers it
//! through `NativeCallable.listener`, so the callback may be called from any thread.

use crate::{Core, Events};
use std::{
    ffi::{CStr, CString, c_char},
    sync::{Arc, OnceLock},
};

pub type Callback = extern "C" fn(*mut c_char);

static CORE: OnceLock<Core> = OnceLock::new();

fn events(callback: Callback) -> Events {
    Arc::new(move |event| {
        if let Ok(text) = CString::new(event.to_string()) {
            callback(text.into_raw());
        }
    })
}

/// Starts the core, or points an already started one at a new callback.
#[unsafe(no_mangle)]
pub extern "C" fn rmc_start(callback: Callback) {
    let mut fresh = false;
    let core = CORE.get_or_init(|| {
        fresh = true;
        Core::new(events(callback))
    });
    if !fresh {
        core.set_events(events(callback));
    }
}

/// Starts a command given as JSON. Returns 0, or -1 if the core is not started or
/// the text is not a command; the command's outcome arrives as a `reply` event.
///
/// # Safety
/// `command` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rmc_send(command: *const c_char) -> i32 {
    let Some(core) = CORE.get() else { return -1 };
    if command.is_null() {
        return -1;
    }
    // SAFETY: the caller passes a valid NUL-terminated string.
    let Ok(text) = unsafe { CStr::from_ptr(command) }.to_str() else {
        return -1;
    };
    match core.send(text) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// Releases an event string passed to the callback.
///
/// # Safety
/// `event` must be a pointer the callback received, released only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rmc_free(event: *mut c_char) {
    if !event.is_null() {
        // SAFETY: the pointer came from `CString::into_raw` in `events`.
        drop(unsafe { CString::from_raw(event) });
    }
}
