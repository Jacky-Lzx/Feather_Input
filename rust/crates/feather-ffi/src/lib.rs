use feather_core::{
    CandidateId, DispatchResult, InputCoordinator, InputEffect, InputEvent, InputMode, Key,
};
use feather_engine_lexicon::LexiconEngine;
use feather_engine_rime::{RimePaths, RimeRuntime};
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::slice;
use std::thread::{self, ThreadId};

const CAP_RIME_ENGINE: u64 = 1 << 0;
const CAP_OPAQUE_CANDIDATE_ID: u64 = 1 << 1;
const CAP_EXPLICIT_CLOSE: u64 = 1 << 2;
const CAP_STRUCTURED_ERROR: u64 = 1 << 3;
const CAP_MULTI_SESSION: u64 = 1 << 4;
const CAP_CANDIDATE_SLICES: u64 = 1 << 5;
const CAP_SCHEMA_SELECTION: u64 = 1 << 6;
const MAX_CANDIDATE_SLICE_LIMIT: usize = 256;

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StatusCode {
    Ok = 0,
    InvalidArgument = 1,
    InvalidUtf8 = 2,
    InvalidKey = 3,
    SessionClosed = 5,
    WrongThread = 6,
    EngineInitializationFailed = 7,
    EngineOperationFailed = 8,
    SnapshotFailed = 9,
    InternalError = 10,
    StaleRevision = 11,
}

impl StatusCode {
    const fn value(self) -> u32 {
        self as u32
    }
}

#[derive(Debug)]
struct FfiFailure {
    code: StatusCode,
    message: String,
}

impl FfiFailure {
    fn new(code: StatusCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub struct FeatherIme {
    core: Option<InputCoordinator>,
    owner_thread: ThreadId,
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

struct CandidateSliceStorage {
    _texts: Vec<CString>,
    candidates: Vec<FeatherCandidate>,
}

#[repr(C)]
pub struct FeatherCandidateSlice {
    pub revision: u64,
    pub offset: usize,
    pub candidates: *const FeatherCandidate,
    pub candidate_count: usize,
    pub has_more: u8,
    pub storage: *mut c_void,
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

struct ErrorStorage {
    message: CString,
}

#[repr(C)]
pub struct FeatherError {
    pub code: u32,
    pub message: *const c_char,
    pub storage: *mut c_void,
}

fn cstring(value: &str) -> CString {
    CString::new(value.replace('\0', "\u{fffd}")).expect("替换后的诊断字符串不包含内部 NUL")
}

fn new_session(core: InputCoordinator) -> *mut FeatherIme {
    Box::into_raw(Box::new(FeatherIme {
        core: Some(core),
        owner_thread: thread::current().id(),
    }))
}

fn response(
    core: &InputCoordinator,
    result: &DispatchResult,
) -> Result<*mut FeatherResponse, FfiFailure> {
    let presentation = core.presentation().map_err(|error| {
        FfiFailure::new(
            StatusCode::SnapshotFailed,
            format!("无法读取输入引擎快照：{error}"),
        )
    })?;
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
        active: u8::from(core.is_active()),
        mode: u8::from(core.mode() != InputMode::Native),
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
    Ok(Box::into_raw(Box::new(FeatherResponse {
        storage: storage.cast(),
        ..response
    })))
}

fn candidate_slice(
    core: &InputCoordinator,
    revision: u64,
    offset: usize,
    limit: usize,
) -> Result<*mut FeatherCandidateSlice, FfiFailure> {
    if limit == 0 || limit > MAX_CANDIDATE_SLICE_LIMIT {
        return Err(FfiFailure::new(
            StatusCode::InvalidArgument,
            format!("候选批次大小必须在 1..={MAX_CANDIDATE_SLICE_LIMIT} 之间"),
        ));
    }
    let slice = core
        .candidate_slice(revision, offset, limit)
        .map_err(|error| {
            FfiFailure::new(
                StatusCode::SnapshotFailed,
                format!("无法读取完整候选列表：{error}"),
            )
        })?
        .ok_or_else(|| FfiFailure::new(StatusCode::StaleRevision, "候选版本已经过期"))?;
    let texts = slice
        .candidates
        .iter()
        .map(|candidate| cstring(&candidate.text))
        .collect::<Vec<_>>();
    let candidates = slice
        .candidates
        .iter()
        .zip(&texts)
        .map(|(candidate, text)| FeatherCandidate {
            revision: candidate.id.revision,
            value: candidate.id.value,
            text: text.as_ptr(),
        })
        .collect::<Vec<_>>();
    let storage = Box::new(CandidateSliceStorage {
        _texts: texts,
        candidates,
    });
    let result = FeatherCandidateSlice {
        revision: slice.revision,
        offset: slice.offset,
        candidates: storage.candidates.as_ptr(),
        candidate_count: storage.candidates.len(),
        has_more: u8::from(slice.has_more),
        storage: ptr::null_mut(),
    };
    let storage = Box::into_raw(storage);
    Ok(Box::into_raw(Box::new(FeatherCandidateSlice {
        storage: storage.cast(),
        ..result
    })))
}

unsafe fn checked_session<'a>(ime: *mut FeatherIme) -> Result<&'a mut FeatherIme, FfiFailure> {
    let Some(ime) = (unsafe { ime.as_mut() }) else {
        return Err(FfiFailure::new(
            StatusCode::InvalidArgument,
            "输入法 session 指针为空",
        ));
    };
    if ime.owner_thread != thread::current().id() {
        return Err(FfiFailure::new(
            StatusCode::WrongThread,
            "输入法 session 必须在创建它的线程上使用",
        ));
    }
    Ok(ime)
}

unsafe fn checked_core<'a>(ime: *mut FeatherIme) -> Result<&'a mut InputCoordinator, FfiFailure> {
    let session = unsafe { checked_session(ime) }?;
    session
        .core
        .as_mut()
        .ok_or_else(|| FfiFailure::new(StatusCode::SessionClosed, "输入法 session 已经关闭"))
}

unsafe fn dispatch_impl(
    ime: *mut FeatherIme,
    event: InputEvent,
) -> Result<*mut FeatherResponse, FfiFailure> {
    let core = unsafe { checked_core(ime) }?;
    let result = core.dispatch(event).map_err(|error| {
        FfiFailure::new(
            StatusCode::EngineOperationFailed,
            format!("输入引擎操作失败：{error}"),
        )
    })?;
    response(core, &result)
}

unsafe fn clear_error_output(out_error: *mut *mut FeatherError) {
    if let Some(out_error) = unsafe { out_error.as_mut() } {
        *out_error = ptr::null_mut();
    }
}

unsafe fn store_failure(failure: &FfiFailure, out_error: *mut *mut FeatherError) -> u32 {
    let code = failure.code.value();
    if let Some(out_error) = unsafe { out_error.as_mut() } {
        let storage = Box::new(ErrorStorage {
            message: cstring(&failure.message),
        });
        let error = FeatherError {
            code,
            message: storage.message.as_ptr(),
            storage: Box::into_raw(storage).cast(),
        };
        *out_error = Box::into_raw(Box::new(error));
    }
    code
}

unsafe fn output_call<T>(
    out_value: *mut *mut T,
    out_error: *mut *mut FeatherError,
    call: impl FnOnce() -> Result<*mut T, FfiFailure>,
) -> u32 {
    unsafe { clear_error_output(out_error) };
    let Some(out_value) = (unsafe { out_value.as_mut() }) else {
        return unsafe {
            store_failure(
                &FfiFailure::new(StatusCode::InvalidArgument, "输出指针为空"),
                out_error,
            )
        };
    };
    *out_value = ptr::null_mut();

    let result = catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| {
        Err(FfiFailure::new(
            StatusCode::InternalError,
            "Rust FFI 内部发生 panic",
        ))
    });
    match result {
        Ok(value) => {
            *out_value = value;
            StatusCode::Ok.value()
        }
        Err(failure) => unsafe { store_failure(&failure, out_error) },
    }
}

unsafe fn status_call(
    out_error: *mut *mut FeatherError,
    call: impl FnOnce() -> Result<(), FfiFailure>,
) -> u32 {
    unsafe { clear_error_output(out_error) };
    let result = catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| {
        Err(FfiFailure::new(
            StatusCode::InternalError,
            "Rust FFI 内部发生 panic",
        ))
    });
    match result {
        Ok(()) => StatusCode::Ok.value(),
        Err(failure) => unsafe { store_failure(&failure, out_error) },
    }
}

unsafe fn utf8_argument<'a>(value: *const c_char, name: &str) -> Result<&'a str, FfiFailure> {
    if value.is_null() {
        return Err(FfiFailure::new(
            StatusCode::InvalidArgument,
            format!("参数 {name} 为空"),
        ));
    }
    unsafe { CStr::from_ptr(value) }.to_str().map_err(|_| {
        FfiFailure::new(
            StatusCode::InvalidUtf8,
            format!("参数 {name} 不是合法 UTF-8"),
        )
    })
}

fn supported_schema(schema: &str) -> Result<&str, FfiFailure> {
    match schema {
        "luna_pinyin_simp" | "double_pinyin_flypy" => Ok(schema),
        _ => Err(FfiFailure::new(
            StatusCode::InvalidArgument,
            format!("不支持的输入方案：{schema}"),
        )),
    }
}

unsafe fn key_from(kind: u32, text: *const u8, text_length: usize) -> Result<Key, FfiFailure> {
    match kind {
        1 => {
            if text.is_null() && text_length != 0 {
                return Err(FfiFailure::new(
                    StatusCode::InvalidArgument,
                    "文字按键的字节指针为空但长度不为 0",
                ));
            }
            let bytes = if text_length == 0 {
                &[]
            } else {
                unsafe { slice::from_raw_parts(text, text_length) }
            };
            let text = std::str::from_utf8(bytes)
                .map_err(|_| FfiFailure::new(StatusCode::InvalidUtf8, "文字按键不是合法 UTF-8"))?;
            Ok(Key::Text(text.to_owned()))
        }
        2 => Ok(Key::Backspace),
        3 => Ok(Key::Delete),
        4 => Ok(Key::Space),
        5 => Ok(Key::Enter),
        6 => Ok(Key::Escape),
        7 => Ok(Key::Left),
        8 => Ok(Key::Right),
        9 => Ok(Key::Up),
        10 => Ok(Key::Down),
        11 => Ok(Key::PageUp),
        12 => Ok(Key::PageDown),
        13 => Ok(Key::ToggleMode),
        _ => Err(FfiFailure::new(
            StatusCode::InvalidKey,
            format!("未知按键类型：{kind}"),
        )),
    }
}

#[no_mangle]
pub extern "C" fn feather_ime_abi_version() -> u32 {
    feather_core::ABI_VERSION
}

#[no_mangle]
pub extern "C" fn feather_ime_capabilities() -> u64 {
    CAP_RIME_ENGINE
        | CAP_OPAQUE_CANDIDATE_ID
        | CAP_EXPLICIT_CLOSE
        | CAP_STRUCTURED_ERROR
        | CAP_MULTI_SESSION
        | CAP_CANDIDATE_SLICES
        | CAP_SCHEMA_SELECTION
}

#[no_mangle]
/// Creates a reference-engine session.
///
/// # Safety
///
/// `out_ime` must point to writable storage for one pointer. `out_error` may
/// be null or point to writable storage for one null error pointer.
pub unsafe extern "C" fn feather_ime_new(
    out_ime: *mut *mut FeatherIme,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_ime, out_error, || {
            Ok(new_session(InputCoordinator::new(LexiconEngine::default())))
        })
    }
}

#[no_mangle]
/// Creates an input session backed by a deployed librime schema.
///
/// # Safety
///
/// String arguments must point to valid NUL-terminated byte strings for the
/// duration of the call. Output pointers follow `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_new_rime(
    shared_data: *const c_char,
    user_data: *const c_char,
    schema: *const c_char,
    out_ime: *mut *mut FeatherIme,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_ime, out_error, || {
            let shared_data = utf8_argument(shared_data, "shared_data")?;
            let user_data = utf8_argument(user_data, "user_data")?;
            let schema = utf8_argument(schema, "schema")?;
            let paths = RimePaths::new(PathBuf::from(shared_data), PathBuf::from(user_data));
            let runtime = RimeRuntime::initialize(&paths).map_err(|error| {
                FfiFailure::new(
                    StatusCode::EngineInitializationFailed,
                    format!("librime 初始化失败：{error}"),
                )
            })?;
            let engine = runtime.create_engine(schema).map_err(|error| {
                FfiFailure::new(
                    StatusCode::EngineInitializationFailed,
                    format!("Rime schema 初始化失败：{error}"),
                )
            })?;
            Ok(new_session(InputCoordinator::new(engine)))
        })
    }
}

#[no_mangle]
/// Closes the engine owned by a session while leaving the handle valid.
///
/// # Safety
///
/// `ime` must be null or a live handle returned by a Feather constructor.
pub unsafe extern "C" fn feather_ime_close(
    ime: *mut FeatherIme,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        status_call(out_error, || {
            let session = checked_session(ime)?;
            let Some(mut core) = session.core.take() else {
                return Ok(());
            };
            let result = core.dispatch(InputEvent::Deactivate).map_err(|error| {
                FfiFailure::new(
                    StatusCode::EngineOperationFailed,
                    format!("关闭输入引擎失败：{error}"),
                )
            });
            drop(core);
            result.map(|_| ())
        })
    }
}

#[no_mangle]
/// Releases a session handle. A null pointer is accepted.
///
/// # Safety
///
/// `ime` must be null or a live pointer returned by a Feather constructor. It
/// must not be released more than once or used after this call.
pub unsafe extern "C" fn feather_ime_free(ime: *mut FeatherIme) {
    if !ime.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(ime) });
        }));
    }
}

#[no_mangle]
/// Activates a session and returns its latest presentation.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_activate(
    ime: *mut FeatherIme,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            dispatch_impl(ime, InputEvent::Activate)
        })
    }
}

#[no_mangle]
/// Deactivates a session and returns its latest presentation.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_deactivate(
    ime: *mut FeatherIme,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            dispatch_impl(ime, InputEvent::Deactivate)
        })
    }
}

#[no_mangle]
/// Changes the input mode for a session.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_set_mode(
    ime: *mut FeatherIme,
    mode: u8,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            let mode = match mode {
                0 => InputMode::Native,
                1 => InputMode::Direct,
                _ => {
                    return Err(FfiFailure::new(
                        StatusCode::InvalidArgument,
                        format!("未知输入模式：{mode}"),
                    ));
                }
            };
            dispatch_impl(ime, InputEvent::SetMode(mode))
        })
    }
}

#[no_mangle]
/// Selects one supported Rime schema without replacing the session handle.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. `schema` must point
/// to a valid NUL-terminated UTF-8 string. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_set_schema(
    ime: *mut FeatherIme,
    schema: *const c_char,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            let schema = supported_schema(utf8_argument(schema, "schema")?)?;
            dispatch_impl(ime, InputEvent::SetSchema(schema.to_owned()))
        })
    }
}

#[no_mangle]
/// Dispatches one normalized key to the input core.
///
/// # Safety
///
/// When `text_length` is nonzero, `text` must point to that many readable
/// bytes. Output pointers follow `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_key(
    ime: *mut FeatherIme,
    kind: u32,
    text: *const u8,
    text_length: usize,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            let key = key_from(kind, text, text_length)?;
            dispatch_impl(ime, InputEvent::Key(key))
        })
    }
}

#[no_mangle]
/// Selects a candidate by its opaque identity.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_select_candidate(
    ime: *mut FeatherIme,
    revision: u64,
    value: u64,
    out_response: *mut *mut FeatherResponse,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_response, out_error, || {
            dispatch_impl(
                ime,
                InputEvent::SelectCandidate(CandidateId { revision, value }),
            )
        })
    }
}

#[no_mangle]
/// Reads a bounded slice of the complete candidate list for one revision.
///
/// # Safety
///
/// `ime` must be a live handle used on its owner thread. Output pointers follow
/// `feather_ime_new`.
pub unsafe extern "C" fn feather_ime_candidate_slice(
    ime: *mut FeatherIme,
    revision: u64,
    offset: usize,
    limit: usize,
    out_slice: *mut *mut FeatherCandidateSlice,
    out_error: *mut *mut FeatherError,
) -> u32 {
    unsafe {
        output_call(out_slice, out_error, || {
            let core = checked_core(ime)?;
            candidate_slice(core, revision, offset, limit)
        })
    }
}

#[no_mangle]
/// Releases an error returned by this library. A null pointer is accepted.
///
/// # Safety
///
/// `error` must be null or a live pointer returned through `out_error`.
pub unsafe extern "C" fn feather_error_free(error: *mut FeatherError) {
    if error.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let error = unsafe { Box::from_raw(error) };
        if !error.storage.is_null() {
            drop(unsafe { Box::from_raw(error.storage.cast::<ErrorStorage>()) });
        }
    }));
}

#[no_mangle]
/// Releases a response returned by this library. A null pointer is accepted.
///
/// # Safety
///
/// `response` must be null or a live pointer returned through `out_response`.
pub unsafe extern "C" fn feather_ime_response_free(response: *mut FeatherResponse) {
    if response.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let response = unsafe { Box::from_raw(response) };
        if !response.storage.is_null() {
            drop(unsafe { Box::from_raw(response.storage.cast::<ResponseStorage>()) });
        }
    }));
}

#[no_mangle]
/// Releases a candidate slice returned by this library. A null pointer is accepted.
///
/// # Safety
///
/// `slice` must be null or a live pointer returned through `out_slice`.
pub unsafe extern "C" fn feather_ime_candidate_slice_free(slice: *mut FeatherCandidateSlice) {
    if slice.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { Box::from_raw(slice) };
        if !slice.storage.is_null() {
            drop(unsafe { Box::from_raw(slice.storage.cast::<CandidateSliceStorage>()) });
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    unsafe fn new_lexicon() -> *mut FeatherIme {
        let mut ime = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe { feather_ime_new(&raw mut ime, &raw mut error) };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        assert!(!ime.is_null());
        ime
    }

    unsafe fn call_key(
        ime: *mut FeatherIme,
        kind: u32,
        text: *const u8,
        length: usize,
    ) -> (*mut FeatherResponse, *mut FeatherError, u32) {
        let mut response = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status =
            unsafe { feather_ime_key(ime, kind, text, length, &raw mut response, &raw mut error) };
        (response, error, status)
    }

    unsafe fn error_message(error: *mut FeatherError) -> String {
        assert!(!error.is_null());
        unsafe { CStr::from_ptr((*error).message) }
            .to_string_lossy()
            .into_owned()
    }

    unsafe fn new_rime(shared: &CString, user: &CString, schema: &CString) -> *mut FeatherIme {
        let mut ime = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe {
            feather_ime_new_rime(
                shared.as_ptr(),
                user.as_ptr(),
                schema.as_ptr(),
                &raw mut ime,
                &raw mut error,
            )
        };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        ime
    }

    unsafe fn activate(ime: *mut FeatherIme) {
        let mut response = ptr::null_mut();
        assert_eq!(
            unsafe { feather_ime_activate(ime, &raw mut response, ptr::null_mut()) },
            StatusCode::Ok.value()
        );
        unsafe { feather_ime_response_free(response) };
    }

    unsafe fn type_ascii(ime: *mut FeatherIme, text: &[u8]) {
        for byte in text {
            let (response, error, status) = unsafe { call_key(ime, 1, byte, 1) };
            assert_eq!(status, StatusCode::Ok.value());
            assert!(error.is_null());
            unsafe { feather_ime_response_free(response) };
        }
    }

    unsafe fn set_schema(ime: *mut FeatherIme, schema: &CString) {
        let mut response = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe {
            feather_ime_set_schema(ime, schema.as_ptr(), &raw mut response, &raw mut error)
        };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        assert_eq!(unsafe { (*response).handled }, 1);
        unsafe { feather_ime_response_free(response) };
    }

    unsafe fn commit_highlighted(ime: *mut FeatherIme) -> String {
        let (response, error, status) = unsafe { call_key(ime, 4, ptr::null(), 0) };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        let committed = unsafe { CStr::from_ptr((*response).commit) }
            .to_string_lossy()
            .into_owned();
        unsafe { feather_ime_response_free(response) };
        committed
    }

    unsafe fn close_and_free(ime: *mut FeatherIme) {
        assert_eq!(
            unsafe { feather_ime_close(ime, ptr::null_mut()) },
            StatusCode::Ok.value()
        );
        unsafe { feather_ime_free(ime) };
    }

    #[test]
    fn c_abi_v2_publishes_version_and_capabilities() {
        assert_eq!(feather_ime_abi_version(), 2);
        assert_eq!(
            feather_ime_capabilities(),
            CAP_RIME_ENGINE
                | CAP_OPAQUE_CANDIDATE_ID
                | CAP_EXPLICIT_CLOSE
                | CAP_STRUCTURED_ERROR
                | CAP_MULTI_SESSION
                | CAP_CANDIDATE_SLICES
                | CAP_SCHEMA_SELECTION
        );
    }

    #[test]
    fn c_abi_v2_reads_revision_bound_candidate_slices() {
        let ime = unsafe { new_lexicon() };
        unsafe {
            activate(ime);
            type_ascii(ime, b"n");
        }
        let revision = unsafe {
            (*checked_core(ime).unwrap())
                .presentation()
                .unwrap()
                .revision
        };
        let mut slice = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe {
            feather_ime_candidate_slice(ime, revision, 0, 1, &raw mut slice, &raw mut error)
        };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        assert_eq!(unsafe { (*slice).candidate_count }, 1);
        assert_eq!(unsafe { (*slice).has_more }, 1);
        assert_eq!(unsafe { (*(*slice).candidates).revision }, revision);
        unsafe { feather_ime_candidate_slice_free(slice) };

        unsafe { type_ascii(ime, b"i") };
        let status = unsafe {
            feather_ime_candidate_slice(ime, revision, 0, 1, &raw mut slice, &raw mut error)
        };
        assert_eq!(status, StatusCode::StaleRevision.value());
        assert!(slice.is_null());
        assert!(unsafe { error_message(error) }.contains("过期"));
        unsafe { feather_error_free(error) };

        let current_revision =
            unsafe { checked_core(ime).unwrap().presentation().unwrap().revision };
        let status = unsafe {
            feather_ime_candidate_slice(ime, current_revision, 0, 0, &raw mut slice, &raw mut error)
        };
        assert_eq!(status, StatusCode::InvalidArgument.value());
        assert!(slice.is_null());
        assert!(unsafe { error_message(error) }.contains("1..=256"));
        unsafe {
            feather_error_free(error);
            close_and_free(ime);
        }
    }

    #[test]
    fn c_abi_v2_composes_closes_and_reports_closed_session() {
        let ime = unsafe { new_lexicon() };
        let mut active = ptr::null_mut();
        let status = unsafe { feather_ime_activate(ime, &raw mut active, ptr::null_mut()) };
        assert_eq!(status, StatusCode::Ok.value());
        unsafe { feather_ime_response_free(active) };

        for byte in b"nihao" {
            let (response, error, status) = unsafe { call_key(ime, 1, byte, 1) };
            assert_eq!(status, StatusCode::Ok.value());
            assert!(error.is_null());
            unsafe { feather_ime_response_free(response) };
        }
        let (response, error, status) = unsafe { call_key(ime, 4, ptr::null(), 0) };
        assert_eq!(status, StatusCode::Ok.value());
        assert!(error.is_null());
        let committed = unsafe { CStr::from_ptr((*response).commit) };
        assert_eq!(committed.to_str().unwrap(), "你好");
        unsafe { feather_ime_response_free(response) };

        assert_eq!(
            unsafe { feather_ime_close(ime, ptr::null_mut()) },
            StatusCode::Ok.value()
        );
        assert_eq!(
            unsafe { feather_ime_close(ime, ptr::null_mut()) },
            StatusCode::Ok.value()
        );

        let mut response = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe { feather_ime_activate(ime, &raw mut response, &raw mut error) };
        assert_eq!(status, StatusCode::SessionClosed.value());
        assert!(response.is_null());
        assert!(unsafe { error_message(error) }.contains("已经关闭"));
        unsafe {
            feather_error_free(error);
            feather_ime_free(ime);
        }
    }

    #[test]
    fn c_abi_v2_reports_invalid_arguments_and_utf8() {
        let mut error = ptr::null_mut();
        let status = unsafe { feather_ime_new(ptr::null_mut(), &raw mut error) };
        assert_eq!(status, StatusCode::InvalidArgument.value());
        assert!(unsafe { error_message(error) }.contains("输出指针"));
        unsafe { feather_error_free(error) };

        let ime = unsafe { new_lexicon() };
        let invalid = [0xff_u8];
        let (response, error, status) =
            unsafe { call_key(ime, 1, invalid.as_ptr(), invalid.len()) };
        assert_eq!(status, StatusCode::InvalidUtf8.value());
        assert!(response.is_null());
        assert!(unsafe { error_message(error) }.contains("UTF-8"));
        unsafe { feather_error_free(error) };

        let (response, error, status) = unsafe { call_key(ime, 99, ptr::null(), 0) };
        assert_eq!(status, StatusCode::InvalidKey.value());
        assert!(response.is_null());
        assert!(unsafe { error_message(error) }.contains("未知按键"));
        unsafe { feather_error_free(error) };

        let mut response = ptr::null_mut();
        let mut error = ptr::null_mut();
        let unsupported = CString::new("unsupported_schema").unwrap();
        let status = unsafe {
            feather_ime_set_schema(ime, unsupported.as_ptr(), &raw mut response, &raw mut error)
        };
        assert_eq!(status, StatusCode::InvalidArgument.value());
        assert!(response.is_null());
        assert!(unsafe { error_message(error) }.contains("不支持的输入方案"));
        unsafe {
            feather_error_free(error);
            feather_ime_free(ime);
        }
    }

    #[test]
    fn c_abi_v2_rejects_calls_from_another_thread() {
        let ime = unsafe { new_lexicon() };
        let address = ime as usize;
        let status = std::thread::spawn(move || {
            let ime = address as *mut FeatherIme;
            let mut response = ptr::null_mut();
            let mut error = ptr::null_mut();
            let status = unsafe { feather_ime_activate(ime, &raw mut response, &raw mut error) };
            let message = unsafe { error_message(error) };
            unsafe { feather_error_free(error) };
            (status, response.is_null(), message)
        })
        .join()
        .unwrap();
        assert_eq!(status.0, StatusCode::WrongThread.value());
        assert!(status.1);
        assert!(status.2.contains("创建它的线程"));
        unsafe { feather_ime_free(ime) };
    }

    #[test]
    fn c_abi_v2_reports_rime_initialization_failure() {
        let shared = CString::new("/definitely/missing/feather-rime-data").unwrap();
        let user = CString::new("/tmp/feather-rime-unused").unwrap();
        let schema = CString::new("luna_pinyin_simp").unwrap();
        let mut ime = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe {
            feather_ime_new_rime(
                shared.as_ptr(),
                user.as_ptr(),
                schema.as_ptr(),
                &raw mut ime,
                &raw mut error,
            )
        };
        assert_eq!(status, StatusCode::EngineInitializationFailed.value());
        assert!(ime.is_null());
        assert!(unsafe { error_message(error) }.contains("共享数据目录不存在"));
        unsafe { feather_error_free(error) };
    }

    #[test]
    #[ignore = "需要 FEATHER_RIME_SHARED_DATA_DIR 指向已经部署的 Rime 数据"]
    fn c_abi_v2_supports_overlapping_rime_sessions() {
        let shared = std::env::var("FEATHER_RIME_SHARED_DATA_DIR")
            .expect("需要 FEATHER_RIME_SHARED_DATA_DIR");
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let user = std::env::temp_dir().join(format!("feather-rime-ffi-{suffix}"));
        let shared = CString::new(shared).unwrap();
        let user_string = user.to_string_lossy();
        let user_argument = CString::new(user_string.as_bytes()).unwrap();
        let schema = CString::new("luna_pinyin_simp").unwrap();
        let ime = unsafe { new_rime(&shared, &user_argument, &schema) };
        let other_ime = unsafe { new_rime(&shared, &user_argument, &schema) };
        unsafe {
            activate(ime);
            activate(other_ime);
            type_ascii(ime, b"nihao");
            type_ascii(other_ime, b"shijie");
        }

        let conflicting_user =
            std::env::temp_dir().join(format!("feather-rime-ffi-conflict-{suffix}"));
        let conflicting_user_string = conflicting_user.to_string_lossy();
        let conflicting_user_argument = CString::new(conflicting_user_string.as_bytes()).unwrap();
        let mut conflicting_ime = ptr::null_mut();
        let mut error = ptr::null_mut();
        let status = unsafe {
            feather_ime_new_rime(
                shared.as_ptr(),
                conflicting_user_argument.as_ptr(),
                schema.as_ptr(),
                &raw mut conflicting_ime,
                &raw mut error,
            )
        };
        assert_eq!(status, StatusCode::EngineInitializationFailed.value());
        assert!(conflicting_ime.is_null());
        assert!(unsafe { error_message(error) }.contains("使用不同的数据目录"));
        unsafe { feather_error_free(error) };

        unsafe {
            assert_eq!(commit_highlighted(ime), "你好");
            close_and_free(ime);
            assert_eq!(commit_highlighted(other_ime), "世界");
            let flypy = CString::new("double_pinyin_flypy").unwrap();
            set_schema(other_ime, &flypy);
            type_ascii(other_ime, b"uijp");
            assert_eq!(commit_highlighted(other_ime), "世界");
            close_and_free(other_ime);
        }
        std::fs::remove_dir_all(user).unwrap();
        std::fs::remove_dir_all(conflicting_user).unwrap();
    }
}
