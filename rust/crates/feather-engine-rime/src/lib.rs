use feather_core::{
    EngineCandidate, EngineCandidateId, EngineCommand, EngineError, EngineResponse, EngineSnapshot,
    InputEngine,
};
use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

const CANDIDATE_CAPACITY: usize = 64;
const CANDIDATE_CAPACITY_C: c_int = 64;
const KEY_BACKSPACE: c_int = 0xff08;
const KEY_ENTER: c_int = 0xff0d;
const KEY_ESCAPE: c_int = 0xff1b;
const KEY_UP: c_int = 0xff52;
const KEY_DOWN: c_int = 0xff54;
const KEY_PAGE_UP: c_int = 0xff55;
const KEY_PAGE_DOWN: c_int = 0xff56;
const KEY_DELETE: c_int = 0xffff;

static RUNTIME_ACTIVE: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn feather_rime_initialize(shared: *const c_char, user: *const c_char) -> c_int;
    fn feather_rime_finalize();
    fn feather_rime_create_session(schema: *const c_char) -> usize;
    fn feather_rime_destroy_session(session: usize);
    fn feather_rime_process_key(session: usize, key: c_int, modifiers: c_int) -> c_int;
    fn feather_rime_clear(session: usize);
    fn feather_rime_take_commit(session: usize) -> *mut c_char;
    fn feather_rime_preedit(session: usize, cursor: *mut usize) -> *mut c_char;
    fn feather_rime_candidates(
        session: usize,
        texts: *mut *mut c_char,
        comments: *mut *mut c_char,
        ids: *mut u64,
        capacity: c_int,
        highlight: *mut c_int,
    ) -> c_int;
    fn feather_rime_select_candidate(session: usize, index: u64) -> c_int;
    fn feather_rime_free_string(text: *mut c_char);
}

#[derive(Clone, Debug)]
pub struct RimePaths {
    pub shared_data: PathBuf,
    pub user_data: PathBuf,
}

impl RimePaths {
    #[must_use]
    pub fn new(shared_data: impl Into<PathBuf>, user_data: impl Into<PathBuf>) -> Self {
        Self {
            shared_data: shared_data.into(),
            user_data: user_data.into(),
        }
    }
}

struct RuntimeInner {
    gate: Mutex<()>,
}

impl RuntimeInner {
    fn lock(&self) -> Result<MutexGuard<'_, ()>, EngineError> {
        self.gate
            .lock()
            .map_err(|_| EngineError::new("librime 运行时锁已损坏"))
    }
}

impl Drop for RuntimeInner {
    fn drop(&mut self) {
        unsafe { feather_rime_finalize() };
        RUNTIME_ACTIVE.store(false, Ordering::Release);
    }
}

#[derive(Clone)]
pub struct RimeRuntime {
    inner: Arc<RuntimeInner>,
}

impl RimeRuntime {
    /// Initializes the process-wide librime runtime.
    ///
    /// # Errors
    ///
    /// Returns an error when another runtime is active, a path is invalid, or
    /// librime cannot initialize its shared and user data directories.
    pub fn initialize(paths: &RimePaths) -> Result<Self, EngineError> {
        if RUNTIME_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(EngineError::new("当前进程已经存在一个 librime 运行时"));
        }

        let result = (|| {
            if !paths.shared_data.is_dir() {
                return Err(EngineError::new(format!(
                    "Rime 共享数据目录不存在：{}",
                    paths.shared_data.display()
                )));
            }
            std::fs::create_dir_all(&paths.user_data).map_err(|error| {
                EngineError::new(format!(
                    "无法创建 Rime 用户数据目录 {}：{error}",
                    paths.user_data.display()
                ))
            })?;
            let shared = path_to_cstring(&paths.shared_data)?;
            let user = path_to_cstring(&paths.user_data)?;
            if unsafe { feather_rime_initialize(shared.as_ptr(), user.as_ptr()) } == 0 {
                return Err(EngineError::new("librime 初始化失败"));
            }
            Ok(Self {
                inner: Arc::new(RuntimeInner {
                    gate: Mutex::new(()),
                }),
            })
        })();

        if result.is_err() {
            RUNTIME_ACTIVE.store(false, Ordering::Release);
        }
        result
    }

    /// Creates a session using one deployed Rime schema.
    ///
    /// # Errors
    ///
    /// Returns an error when the schema name is invalid or librime cannot
    /// create and select the requested schema.
    pub fn create_engine(&self, schema: &str) -> Result<RimeEngine, EngineError> {
        let schema =
            CString::new(schema).map_err(|_| EngineError::new("Rime schema 名称包含 NUL 字符"))?;
        let _guard = self.inner.lock()?;
        let session = unsafe { feather_rime_create_session(schema.as_ptr()) };
        if session == 0 {
            return Err(EngineError::new(format!(
                "无法创建或选择 Rime schema：{}",
                schema.to_string_lossy()
            )));
        }
        Ok(RimeEngine {
            runtime: Arc::clone(&self.inner),
            session,
            revision: 1,
        })
    }
}

pub struct RimeEngine {
    runtime: Arc<RuntimeInner>,
    session: usize,
    revision: u64,
}

impl RimeEngine {
    fn process_key(&mut self, key: c_int) -> Result<bool, EngineError> {
        let _guard = self.runtime.lock()?;
        let handled = unsafe { feather_rime_process_key(self.session, key, 0) } != 0;
        if handled {
            self.revision = next_revision(self.revision);
        }
        Ok(handled)
    }

    fn take_commit(&self) -> Result<Option<String>, EngineError> {
        let _guard = self.runtime.lock()?;
        let text = unsafe { feather_rime_take_commit(self.session) };
        Ok(unsafe { take_string(text) })
    }

    fn select_candidate(&mut self, id: EngineCandidateId) -> Result<bool, EngineError> {
        let _guard = self.runtime.lock()?;
        let handled = unsafe { feather_rime_select_candidate(self.session, id.0) } != 0;
        if handled {
            self.revision = next_revision(self.revision);
        }
        Ok(handled)
    }
}

impl Drop for RimeEngine {
    fn drop(&mut self) {
        if let Ok(_guard) = self.runtime.gate.lock() {
            unsafe { feather_rime_destroy_session(self.session) };
        }
    }
}

impl InputEngine for RimeEngine {
    fn reset(&mut self) {
        if let Ok(_guard) = self.runtime.gate.lock() {
            unsafe { feather_rime_clear(self.session) };
            self.revision = next_revision(self.revision);
        }
    }

    fn handle(&mut self, command: EngineCommand) -> Result<EngineResponse, EngineError> {
        let handled = match command {
            EngineCommand::Insert(text) => {
                if text.is_empty() || !text.is_ascii() {
                    false
                } else {
                    let mut handled = false;
                    for byte in text.bytes() {
                        handled |= self.process_key(c_int::from(byte))?;
                    }
                    handled
                }
            }
            EngineCommand::Backspace => self.process_key(KEY_BACKSPACE)?,
            EngineCommand::Delete => self.process_key(KEY_DELETE)?,
            EngineCommand::CommitHighlighted => self.process_key(c_int::from(b' '))?,
            EngineCommand::CommitRaw => self.process_key(KEY_ENTER)?,
            EngineCommand::Cancel => self.process_key(KEY_ESCAPE)?,
            EngineCommand::MovePrevious => self.process_key(KEY_UP)?,
            EngineCommand::MoveNext => self.process_key(KEY_DOWN)?,
            EngineCommand::PagePrevious => self.process_key(KEY_PAGE_UP)?,
            EngineCommand::PageNext => self.process_key(KEY_PAGE_DOWN)?,
            EngineCommand::Select(id) => self.select_candidate(id)?,
        };
        let commit = if handled { self.take_commit()? } else { None };
        Ok(EngineResponse { handled, commit })
    }

    fn snapshot(&self) -> Result<EngineSnapshot, EngineError> {
        let _guard = self.runtime.lock()?;
        let mut cursor = 0_usize;
        let preedit = unsafe { take_string(feather_rime_preedit(self.session, &raw mut cursor)) }
            .unwrap_or_default();

        let mut texts = [ptr::null_mut(); CANDIDATE_CAPACITY];
        let mut comments = [ptr::null_mut(); CANDIDATE_CAPACITY];
        let mut ids = [0_u64; CANDIDATE_CAPACITY];
        let mut highlight: c_int = 0;
        let count = unsafe {
            feather_rime_candidates(
                self.session,
                texts.as_mut_ptr(),
                comments.as_mut_ptr(),
                ids.as_mut_ptr(),
                CANDIDATE_CAPACITY_C,
                &raw mut highlight,
            )
        };
        if count < 0 {
            if preedit.is_empty() {
                return Ok(EngineSnapshot {
                    revision: self.revision,
                    ..EngineSnapshot::default()
                });
            }
            return Err(EngineError::new("无法读取 Rime 候选状态"));
        }

        let count = usize::try_from(count).map_err(|_| EngineError::new("Rime 候选数量无效"))?;
        let mut candidates = Vec::with_capacity(count);
        for index in 0..count {
            let text = unsafe { take_string(texts[index]) }.unwrap_or_default();
            let annotation =
                unsafe { take_string(comments[index]) }.filter(|text| !text.is_empty());
            candidates.push(EngineCandidate {
                id: EngineCandidateId(ids[index]),
                text,
                annotation,
            });
        }
        let highlighted = usize::try_from(highlight)
            .ok()
            .filter(|index| *index < candidates.len());
        Ok(EngineSnapshot {
            revision: self.revision,
            preedit,
            cursor_utf8: cursor,
            candidates,
            highlighted,
        })
    }
}

fn path_to_cstring(path: &Path) -> Result<CString, EngineError> {
    CString::new(path.to_string_lossy().as_bytes())
        .map_err(|_| EngineError::new(format!("路径包含 NUL 字符：{}", path.display())))
}

fn next_revision(revision: u64) -> u64 {
    revision.wrapping_add(1).max(1)
}

unsafe fn take_string(text: *mut c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    let value = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    unsafe { feather_rime_free_string(text) };
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use feather_core::{InputCoordinator, InputEffect, InputEvent, Key};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    #[ignore = "需要 FEATHER_RIME_SHARED_DATA_DIR 指向已经部署的 Rime 数据"]
    fn real_full_pinyin_session_commits_nihao() {
        let shared = std::env::var_os("FEATHER_RIME_SHARED_DATA_DIR")
            .expect("需要 FEATHER_RIME_SHARED_DATA_DIR");
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let user = std::env::temp_dir().join(format!("feather-rime-rust-{suffix}"));
        let runtime = RimeRuntime::initialize(&RimePaths::new(shared, &user)).unwrap();
        let engine = runtime.create_engine("luna_pinyin_simp").unwrap();
        let mut core = InputCoordinator::new(engine);
        core.dispatch(InputEvent::Activate).unwrap();
        for character in "nihao".chars() {
            core.dispatch(InputEvent::Key(Key::Text(character.to_string())))
                .unwrap();
        }
        let presentation = core.presentation().unwrap();
        let candidate = presentation
            .candidates
            .iter()
            .find(|candidate| candidate.text == "你好")
            .expect("真实 Rime 候选应该包含你好")
            .id;
        let result = core
            .dispatch(InputEvent::SelectCandidate(candidate))
            .unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText("你好".into())));
        drop(core);
        drop(runtime);
        std::fs::remove_dir_all(user).unwrap();
    }
}
