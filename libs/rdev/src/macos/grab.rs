#![allow(improper_ctypes_definitions)]
use crate::macos::common::*;
use crate::rdev::{Event, GrabError};
use cocoa::base::nil;
use cocoa::foundation::NSAutoreleasePool;
use core_graphics::event::{CGEventTapLocation, CGEventType};
use std::os::raw::c_void;

static mut GLOBAL_CALLBACK: Option<Box<dyn FnMut(Event) -> Option<Event>>> = None;

unsafe extern "C" fn raw_callback(
    _proxy: CGEventTapProxy,
    _type: CGEventType,
    cg_event: CGEventRef,
    _user_info: *mut c_void,
) -> CGEventRef {
    // macOS disables an event tap when its callback runs past the system
    // timeout (kCGEventTapDisabledByTimeout) or on certain user input
    // (kCGEventTapDisabledByUserInput). Once disabled the tap stops delivering
    // events, and since the grab loop creates the tap only once per process it
    // is never recreated -- so the keyboard hook stays dead until the whole
    // client is restarted (symptom: keyboard input not reaching the remote
    // after a reconnect). Re-enable the tap in place so it recovers itself.
    if matches!(
        _type,
        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
    ) {
        if !CUR_TAP.is_null() {
            CGEventTapEnable(CUR_TAP, true);
            log::warn!("CGEventTap was disabled by the system; re-enabled it");
        }
        return cg_event;
    }
    // println!("Event ref {:?}", cg_event_ptr);
    // let cg_event: CGEvent = transmute_copy::<*mut c_void, CGEvent>(&cg_event_ptr);
    if let Ok(mut state) = KEYBOARD_STATE.lock() {
        if let Some(keyboard) = state.as_mut() {
            if let Some(event) = convert(_type, &cg_event, keyboard) {
                if let Some(callback) = &mut GLOBAL_CALLBACK {
                    if callback(event).is_none() {
                        cg_event.set_type(CGEventType::Null);
                    }
                }
            }
        }
    }
    cg_event
}

static mut CUR_LOOP: CFRunLoopSourceRef = std::ptr::null_mut();
// The active event tap, kept so raw_callback can re-enable it after macOS
// disables it (see the kCGEventTapDisabledBy* handling above).
static mut CUR_TAP: CFMachPortRef = std::ptr::null();

#[inline]
pub fn is_grabbed() -> bool {
    unsafe {
        !CUR_LOOP.is_null()
    }
}

pub fn grab<T>(callback: T) -> Result<(), GrabError>
where
    T: FnMut(Event) -> Option<Event> + 'static,
{
    if is_grabbed() {
        return Ok(());
    }

    unsafe {
        GLOBAL_CALLBACK = Some(Box::new(callback));
        let _pool = NSAutoreleasePool::new(nil);
        let tap = CGEventTapCreate(
            CGEventTapLocation::Session, // HID, Session, AnnotatedSession,
            kCGHeadInsertEventTap,
            CGEventTapOption::Default,
            kCGEventMaskForAllEvents,
            raw_callback,
            nil,
        );
        if tap.is_null() {
            return Err(GrabError::EventTapError);
        }
        CUR_TAP = tap;
        let _loop = CFMachPortCreateRunLoopSource(nil, tap, 0);
        if _loop.is_null() {
            return Err(GrabError::LoopSourceError);
        }

        CUR_LOOP = CFRunLoopGetCurrent() as _;
        CFRunLoopAddSource(CUR_LOOP, _loop, kCFRunLoopCommonModes);

        CGEventTapEnable(tap, true);
        CFRunLoopRun();
    }
    Ok(())
}

pub fn exit_grab() -> Result<(), GrabError> {
    unsafe {
        if !CUR_LOOP.is_null() {
            CFRunLoopStop(CUR_LOOP);
            CUR_LOOP = std::ptr::null_mut();
        }
        CUR_TAP = std::ptr::null();
    }
    Ok(())
}
