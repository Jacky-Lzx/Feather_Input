use feather_core::{
    CandidateId, DispatchResult, InputCoordinator, InputEffect, InputEvent, InputMode, Key,
};
use feather_engine_lexicon::LexiconEngine;
use std::ffi::{c_char, c_void, CString};
use std::ptr;
use std::slice;

pub struct FeatherIme {
    core: InputCoordinator,
}

#[repr(C)]
pub struct FeatherCandidate {
    pub revision: u64,
    pub value: u64,
    pub text: *const c_char,
}

struct ResponseStorage {
    commit: Option<CString>,
    preedit: CString,
    _texts: Vec<CString>,
    candidates: Vec<FeatherCandidate>,
}

#[repr(C)]
pub struct FeatherResponse {
    pub handled: u8,
    pub active: u8,
    pub mode: u8,
    pub commit: *const c_char,
    pub preedit: *const c_char,
    pub cursor_utf8: usize,
    pub revision: u64,
    pub candidates: *const FeatherCandidate,
    pub candidate_count: usize,
    pub highlighted: isize,
    pub storage: *mut c_void,
}

fn cstring(value: &str) -> CString {
    CString::new(value.replace('\0', "\u{fffd}")).expect("replacement removes interior nulls")
}

fn response(ime: &FeatherIme, result: &DispatchResult) -> *mut FeatherResponse {
    let presentation = ime.core.presentation();
    let commit = result.effects.iter().find_map(|effect| match effect {
        InputEffect::CommitText(text) => Some(cstring(text)),
        _ => None,
    });
    let preedit = cstring(&presentation.preedit);
    let texts: Vec<CString> = presentation
        .candidates
        .iter()
        .map(|candidate| cstring(&candidate.text))
        .collect();
    let candidates = presentation
        .candidates
        .iter()
        .zip(&texts)
        .map(|(candidate, text)| FeatherCandidate {
            revision: candidate.id.revision,
            value: candidate.id.value,
            text: text.as_ptr(),
        })
        .collect();
    let storage = Box::new(ResponseStorage {
        commit,
        preedit,
        _texts: texts,
        candidates,
    });
    let response = FeatherResponse {
        handled: u8::from(result.handled),
        active: u8::from(ime.core.is_active()),
        mode: u8::from(ime.core.mode() != InputMode::Native),
        commit: storage
            .commit
            .as_ref()
            .map_or(ptr::null(), |text| text.as_ptr()),
        preedit: storage.preedit.as_ptr(),
        cursor_utf8: presentation.cursor_utf8,
        revision: presentation.revision,
        candidates: storage.candidates.as_ptr(),
        candidate_count: storage.candidates.len(),
        highlighted: presentation
            .highlighted
            .and_then(|index| isize::try_from(index).ok())
            .unwrap_or(-1),
        storage: ptr::null_mut(),
    };
    let storage = Box::into_raw(storage);
    Box::into_raw(Box::new(FeatherResponse {
        storage: storage.cast(),
        ..response
    }))
}

fn dispatch(ime: *mut FeatherIme, event: InputEvent) -> *mut FeatherResponse {
    let Some(ime) = (unsafe { ime.as_mut() }) else {
        return ptr::null_mut();
    };
    match ime.core.dispatch(event) {
        Ok(result) => response(ime, &result),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn feather_ime_abi_version() -> u32 {
    feather_core::ABI_VERSION
}

#[no_mangle]
pub extern "C" fn feather_ime_new() -> *mut FeatherIme {
    Box::into_raw(Box::new(FeatherIme {
        core: InputCoordinator::new(LexiconEngine::default()),
    }))
}

#[no_mangle]
/// Releases a session created by `feather_ime_new`.
///
/// # Safety
///
/// `ime` must be null or a live pointer returned by `feather_ime_new`. It must
/// not be released more than once or used after this call.
pub unsafe extern "C" fn feather_ime_free(ime: *mut FeatherIme) {
    if !ime.is_null() {
        drop(unsafe { Box::from_raw(ime) });
    }
}

#[no_mangle]
pub extern "C" fn feather_ime_activate(ime: *mut FeatherIme) -> *mut FeatherResponse {
    dispatch(ime, InputEvent::Activate)
}

#[no_mangle]
pub extern "C" fn feather_ime_deactivate(ime: *mut FeatherIme) -> *mut FeatherResponse {
    dispatch(ime, InputEvent::Deactivate)
}

#[no_mangle]
pub extern "C" fn feather_ime_set_mode(ime: *mut FeatherIme, mode: u8) -> *mut FeatherResponse {
    let mode = if mode == 0 {
        InputMode::Native
    } else {
        InputMode::Direct
    };
    dispatch(ime, InputEvent::SetMode(mode))
}

#[no_mangle]
/// Dispatches a normalized key to the input core.
///
/// # Safety
///
/// `ime` must point to a live Feather session. When `text_length` is nonzero,
/// `text` must point to that many readable bytes for the duration of the call.
pub unsafe extern "C" fn feather_ime_key(
    ime: *mut FeatherIme,
    kind: u32,
    text: *const u8,
    text_length: usize,
) -> *mut FeatherResponse {
    let key = match kind {
        1 => {
            if text.is_null() && text_length != 0 {
                return ptr::null_mut();
            }
            let bytes = if text_length == 0 {
                &[]
            } else {
                unsafe { slice::from_raw_parts(text, text_length) }
            };
            let Ok(text) = std::str::from_utf8(bytes) else {
                return ptr::null_mut();
            };
            Key::Text(text.to_owned())
        }
        2 => Key::Backspace,
        3 => Key::Delete,
        4 => Key::Space,
        5 => Key::Enter,
        6 => Key::Escape,
        7 => Key::Left,
        8 => Key::Right,
        9 => Key::Up,
        10 => Key::Down,
        11 => Key::PageUp,
        12 => Key::PageDown,
        13 => Key::ToggleMode,
        _ => return ptr::null_mut(),
    };
    dispatch(ime, InputEvent::Key(key))
}

#[no_mangle]
pub extern "C" fn feather_ime_select_candidate(
    ime: *mut FeatherIme,
    revision: u64,
    value: u64,
) -> *mut FeatherResponse {
    dispatch(
        ime,
        InputEvent::SelectCandidate(CandidateId { revision, value }),
    )
}

#[no_mangle]
/// Releases a response returned by this library.
///
/// # Safety
///
/// `response` must be null or a live pointer returned by a Feather dispatch
/// function. Its borrowed strings and candidates must no longer be in use.
pub unsafe extern "C" fn feather_ime_response_free(response: *mut FeatherResponse) {
    if response.is_null() {
        return;
    }
    let response = unsafe { Box::from_raw(response) };
    if !response.storage.is_null() {
        drop(unsafe { Box::from_raw(response.storage.cast::<ResponseStorage>()) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn c_abi_composes_and_commits() {
        let ime = feather_ime_new();
        let active = feather_ime_activate(ime);
        unsafe { feather_ime_response_free(active) };
        for byte in b"nihao" {
            let response = unsafe { feather_ime_key(ime, 1, byte, 1) };
            assert!(!response.is_null());
            unsafe { feather_ime_response_free(response) };
        }
        let response = unsafe { feather_ime_key(ime, 4, ptr::null(), 0) };
        assert!(!response.is_null());
        let committed = unsafe { CStr::from_ptr((*response).commit) };
        assert_eq!(committed.to_str().unwrap(), "你好");
        unsafe {
            feather_ime_response_free(response);
            feather_ime_free(ime);
        }
    }
}
