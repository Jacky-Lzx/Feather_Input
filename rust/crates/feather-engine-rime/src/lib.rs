use feather_core::{
    EngineCandidate, EngineCandidateId, EngineCandidateSlice, EngineCommand, EngineError,
    EngineResponse, EngineSnapshot, InputEngine,
};
use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

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

static RUNTIME_REGISTRY: OnceLock<Mutex<RuntimeRegistry>> = OnceLock::new();

unsafe extern "C" {
    fn feather_rime_initialize(shared: *const c_char, user: *const c_char) -> c_int;
    fn feather_rime_finalize();
    fn feather_rime_create_session(schema: *const c_char) -> usize;
    fn feather_rime_select_schema(session: usize, schema: *const c_char) -> c_int;
    fn feather_rime_set_page_size(session: usize, schema: *const c_char, page_size: c_int)
        -> c_int;
    fn feather_rime_set_english_candidate_minimum(
        session: usize,
        schema: *const c_char,
        minimum: c_int,
    ) -> usize;
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
    fn feather_rime_candidate_slice(
        session: usize,
        offset: usize,
        texts: *mut *mut c_char,
        comments: *mut *mut c_char,
        ids: *mut u64,
        capacity: c_int,
        has_more: *mut c_int,
    ) -> c_int;
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct RuntimeConfig {
    shared_data: PathBuf,
    user_data: PathBuf,
}

impl RuntimeConfig {
    fn prepare(paths: &RimePaths) -> Result<Self, EngineError> {
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
        let shared_data = paths.shared_data.canonicalize().map_err(|error| {
            EngineError::new(format!(
                "无法解析 Rime 共享数据目录 {}：{error}",
                paths.shared_data.display()
            ))
        })?;
        let user_data = paths.user_data.canonicalize().map_err(|error| {
            EngineError::new(format!(
                "无法解析 Rime 用户数据目录 {}：{error}",
                paths.user_data.display()
            ))
        })?;
        Ok(Self {
            shared_data,
            user_data,
        })
    }
}

#[derive(Debug)]
struct ActiveRuntime {
    id: u64,
    config: RuntimeConfig,
    owners: usize,
}

#[derive(Debug, Default)]
struct RuntimeRegistry {
    active: Option<ActiveRuntime>,
    next_id: u64,
}

fn runtime_conflict(active: &ActiveRuntime, requested: &RuntimeConfig) -> EngineError {
    EngineError::new(format!(
        "当前进程的 librime 运行时使用不同的数据目录：当前 shared={} user={}，请求 shared={} user={}",
        active.config.shared_data.display(),
        active.config.user_data.display(),
        requested.shared_data.display(),
        requested.user_data.display()
    ))
}

fn runtime_registry() -> &'static Mutex<RuntimeRegistry> {
    RUNTIME_REGISTRY.get_or_init(|| Mutex::new(RuntimeRegistry::default()))
}

struct RuntimeLease {
    id: u64,
}

impl RuntimeLease {
    fn lock(&self) -> Result<MutexGuard<'static, RuntimeRegistry>, EngineError> {
        let registry = runtime_registry()
            .lock()
            .map_err(|_| EngineError::new("librime 运行时注册表已损坏"))?;
        let is_active = registry
            .active
            .as_ref()
            .is_some_and(|active| active.id == self.id);
        if !is_active {
            return Err(EngineError::new("librime 运行时已经失效"));
        }
        Ok(registry)
    }
}

impl Drop for RuntimeLease {
    fn drop(&mut self) {
        let mut registry = match runtime_registry().lock() {
            Ok(registry) => registry,
            Err(poisoned) => poisoned.into_inner(),
        };
        let Some(active) = registry
            .active
            .as_mut()
            .filter(|active| active.id == self.id)
        else {
            return;
        };
        active.owners = active.owners.saturating_sub(1);
        if active.owners == 0 {
            unsafe { feather_rime_finalize() };
            registry.active = None;
        }
    }
}

#[derive(Clone)]
pub struct RimeRuntime {
    lease: Arc<RuntimeLease>,
}

impl RimeRuntime {
    /// Initializes the process-wide librime runtime.
    ///
    /// # Errors
    ///
    /// Reuses the active process-wide runtime when its paths match. Returns an
    /// error when the active runtime uses different paths, a path is invalid,
    /// or librime cannot initialize its data directories.
    pub fn initialize(paths: &RimePaths) -> Result<Self, EngineError> {
        let config = RuntimeConfig::prepare(paths)?;
        let shared = path_to_cstring(&config.shared_data)?;
        let user = path_to_cstring(&config.user_data)?;
        let mut registry = runtime_registry()
            .lock()
            .map_err(|_| EngineError::new("librime 运行时注册表已损坏"))?;

        if let Some(active) = registry.active.as_mut() {
            if active.config != config {
                return Err(runtime_conflict(active, &config));
            }
            active.owners = active
                .owners
                .checked_add(1)
                .ok_or_else(|| EngineError::new("librime 运行时引用计数溢出"))?;
            return Ok(Self {
                lease: Arc::new(RuntimeLease { id: active.id }),
            });
        }

        if unsafe { feather_rime_initialize(shared.as_ptr(), user.as_ptr()) } == 0 {
            return Err(EngineError::new("librime 初始化失败"));
        }
        registry.next_id = registry.next_id.wrapping_add(1).max(1);
        let id = registry.next_id;
        registry.active = Some(ActiveRuntime {
            id,
            config,
            owners: 1,
        });
        Ok(Self {
            lease: Arc::new(RuntimeLease { id }),
        })
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
        let _registry = self.lease.lock()?;
        let session = unsafe { feather_rime_create_session(schema.as_ptr()) };
        if session == 0 {
            return Err(EngineError::new(format!(
                "无法创建或选择 Rime schema：{}",
                schema.to_string_lossy()
            )));
        }
        Ok(RimeEngine {
            lease: Arc::clone(&self.lease),
            session,
            revision: 1,
            schema: schema.to_string_lossy().into_owned(),
        })
    }
}

pub struct RimeEngine {
    lease: Arc<RuntimeLease>,
    session: usize,
    revision: u64,
    schema: String,
}

impl RimeEngine {
    fn select_schema(&mut self, schema: &str) -> Result<bool, EngineError> {
        let schema =
            CString::new(schema).map_err(|_| EngineError::new("Rime schema 名称包含 NUL 字符"))?;
        let _registry = self.lease.lock()?;
        let handled = unsafe { feather_rime_select_schema(self.session, schema.as_ptr()) } != 0;
        if !handled {
            return Err(EngineError::new(format!(
                "无法选择 Rime schema：{}",
                schema.to_string_lossy()
            )));
        }
        self.revision = next_revision(self.revision);
        self.schema = schema.to_string_lossy().into_owned();
        Ok(true)
    }

    fn set_page_size(&mut self, page_size: usize) -> Result<bool, EngineError> {
        if !(1..=9).contains(&page_size) {
            return Err(EngineError::new(format!(
                "Rime 每页候选数量超出范围：{page_size}"
            )));
        }
        if !self.snapshot()?.preedit.is_empty() {
            return Ok(false);
        }
        let schema = CString::new(self.schema.as_str())
            .map_err(|_| EngineError::new("Rime schema 名称包含 NUL 字符"))?;
        let page_size = c_int::try_from(page_size)
            .map_err(|_| EngineError::new("Rime 每页候选数量无法转换为 C 整数"))?;
        let _registry = self.lease.lock()?;
        let handled =
            unsafe { feather_rime_set_page_size(self.session, schema.as_ptr(), page_size) } != 0;
        if !handled {
            return Err(EngineError::new(format!(
                "无法设置 Rime 每页候选数量：{page_size}"
            )));
        }
        self.revision = next_revision(self.revision);
        Ok(true)
    }

    fn set_english_candidate_minimum(&mut self, minimum: usize) -> Result<bool, EngineError> {
        if !(1..=12).contains(&minimum) {
            return Err(EngineError::new(format!(
                "英文候选最少输入长度超出范围：{minimum}"
            )));
        }
        if !self.snapshot()?.preedit.is_empty() {
            return Ok(false);
        }
        let schema = CString::new(self.schema.as_str())
            .map_err(|_| EngineError::new("Rime schema 名称包含 NUL 字符"))?;
        let minimum = c_int::try_from(minimum)
            .map_err(|_| EngineError::new("英文候选最少输入长度无法转换为 C 整数"))?;
        let _registry = self.lease.lock()?;
        let replacement = unsafe {
            feather_rime_set_english_candidate_minimum(self.session, schema.as_ptr(), minimum)
        };
        if replacement == 0 {
            return Err(EngineError::new(format!(
                "无法设置英文候选最少输入长度：{minimum}"
            )));
        }
        self.session = replacement;
        self.revision = next_revision(self.revision);
        Ok(true)
    }

    fn process_key(&mut self, key: c_int) -> Result<bool, EngineError> {
        let _registry = self.lease.lock()?;
        let handled = unsafe { feather_rime_process_key(self.session, key, 0) } != 0;
        if handled {
            self.revision = next_revision(self.revision);
        }
        Ok(handled)
    }

    fn take_commit(&self) -> Result<Option<String>, EngineError> {
        let _registry = self.lease.lock()?;
        let text = unsafe { feather_rime_take_commit(self.session) };
        Ok(unsafe { take_string(text) })
    }

    fn select_candidate(&mut self, id: EngineCandidateId) -> Result<bool, EngineError> {
        let _registry = self.lease.lock()?;
        let handled = unsafe { feather_rime_select_candidate(self.session, id.0) } != 0;
        if handled {
            self.revision = next_revision(self.revision);
        }
        Ok(handled)
    }
}

impl Drop for RimeEngine {
    fn drop(&mut self) {
        if let Ok(_registry) = self.lease.lock() {
            unsafe { feather_rime_destroy_session(self.session) };
        }
    }
}

impl InputEngine for RimeEngine {
    fn reset(&mut self) {
        if let Ok(_registry) = self.lease.lock() {
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
            EngineCommand::SelectSchema(schema) => self.select_schema(&schema)?,
            EngineCommand::SetPageSize(page_size) => self.set_page_size(page_size)?,
            EngineCommand::SetEnglishCandidateMinimum(minimum) => {
                self.set_english_candidate_minimum(minimum)?
            }
        };
        let commit = if handled { self.take_commit()? } else { None };
        Ok(EngineResponse { handled, commit })
    }

    fn snapshot(&self) -> Result<EngineSnapshot, EngineError> {
        let _registry = self.lease.lock()?;
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

    fn candidate_slice(
        &self,
        offset: usize,
        limit: usize,
    ) -> Result<EngineCandidateSlice, EngineError> {
        let capacity =
            c_int::try_from(limit).map_err(|_| EngineError::new("Rime 候选批次大小超出范围"))?;
        let _registry = self.lease.lock()?;
        let mut texts = vec![ptr::null_mut(); limit];
        let mut comments = vec![ptr::null_mut(); limit];
        let mut ids = vec![0_u64; limit];
        let mut has_more = 0;
        let count = unsafe {
            feather_rime_candidate_slice(
                self.session,
                offset,
                texts.as_mut_ptr(),
                comments.as_mut_ptr(),
                ids.as_mut_ptr(),
                capacity,
                &raw mut has_more,
            )
        };
        if count < 0 {
            return Err(EngineError::new("无法读取完整 Rime 候选列表"));
        }
        let count = usize::try_from(count).map_err(|_| EngineError::new("Rime 候选数量无效"))?;
        let mut candidates = Vec::with_capacity(count);
        for index in 0..count {
            candidates.push(EngineCandidate {
                id: EngineCandidateId(ids[index]),
                text: unsafe { take_string(texts[index]) }.unwrap_or_default(),
                annotation: unsafe { take_string(comments[index]) }.filter(|text| !text.is_empty()),
            });
        }
        Ok(EngineCandidateSlice {
            candidates,
            has_more: has_more != 0,
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
    use feather_core::{InputCoordinator, InputEffect, InputEvent, InputMode, Key};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn type_text(core: &mut InputCoordinator, text: &str) {
        for character in text.chars() {
            core.dispatch(InputEvent::Key(Key::Text(character.to_string())))
                .unwrap();
        }
    }

    fn select_text(core: &mut InputCoordinator, text: &str) {
        let candidate = core
            .presentation()
            .unwrap()
            .candidates
            .iter()
            .find(|candidate| candidate.text == text)
            .unwrap_or_else(|| panic!("真实 Rime 候选应该包含{text}"))
            .id;
        let result = core
            .dispatch(InputEvent::SelectCandidate(candidate))
            .unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText(text.into())));
    }

    #[test]
    #[ignore = "需要 FEATHER_RIME_SHARED_DATA_DIR 指向已经部署的 Rime 数据"]
    fn real_runtime_supports_overlapping_sessions_and_reinitialization() {
        let shared = std::env::var_os("FEATHER_RIME_SHARED_DATA_DIR")
            .expect("需要 FEATHER_RIME_SHARED_DATA_DIR");
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let user = std::env::temp_dir().join(format!("feather-rime-rust-{suffix}"));
        let paths = RimePaths::new(&shared, &user);
        let runtime_a = RimeRuntime::initialize(&paths).unwrap();
        let runtime_b = RimeRuntime::initialize(&paths).unwrap();
        let mut core_a =
            InputCoordinator::new(runtime_a.create_engine("luna_pinyin_simp").unwrap());
        let mut core_b =
            InputCoordinator::new(runtime_b.create_engine("luna_pinyin_simp").unwrap());
        core_a.dispatch(InputEvent::Activate).unwrap();
        core_b.dispatch(InputEvent::Activate).unwrap();

        type_text(&mut core_a, "nihao");
        type_text(&mut core_b, "shijie");
        assert!(core_a
            .presentation()
            .unwrap()
            .candidates
            .iter()
            .any(|candidate| candidate.text == "你好"));
        assert!(core_b
            .presentation()
            .unwrap()
            .candidates
            .iter()
            .any(|candidate| candidate.text == "世界"));

        let presentation = core_b.presentation().unwrap();
        let revision = presentation.revision;
        let first = core_b.candidate_slice(revision, 0, 3).unwrap().unwrap();
        let second = core_b.candidate_slice(revision, 3, 3).unwrap().unwrap();
        assert_eq!(first.candidates.len(), 3);
        assert_eq!(second.candidates.len(), 3);
        assert!(first.has_more);
        assert_eq!(first.candidates[0], presentation.candidates[0]);
        assert_ne!(first.candidates[0].id, second.candidates[0].id);
        let off_page = second.candidates[2].clone();
        let result = core_b
            .dispatch(InputEvent::SelectCandidate(off_page.id))
            .unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText(off_page.text)));
        type_text(&mut core_b, "shijie");

        select_text(&mut core_a, "你好");
        type_text(&mut core_a, "shijie");
        let stale_candidate = core_a.presentation().unwrap().candidates[0].id;
        let revision_before_switch = core_a.presentation().unwrap().revision;
        core_a
            .dispatch(InputEvent::SetMode(InputMode::Direct))
            .unwrap();
        let switched = core_a
            .dispatch(InputEvent::SetSchema("double_pinyin_flypy".into()))
            .unwrap();
        assert!(switched
            .effects
            .contains(&InputEffect::SchemaChanged("double_pinyin_flypy".into())));
        assert_eq!(core_a.mode(), InputMode::Direct);
        assert!(core_a.presentation().unwrap().preedit.is_empty());
        assert_ne!(
            core_a.presentation().unwrap().revision,
            revision_before_switch
        );
        core_a
            .dispatch(InputEvent::SetMode(InputMode::Native))
            .unwrap();
        assert!(
            !core_a
                .dispatch(InputEvent::SelectCandidate(stale_candidate))
                .unwrap()
                .handled
        );
        type_text(&mut core_a, "uijp");
        select_text(&mut core_a, "世界");
        drop(core_a);
        drop(runtime_a);
        select_text(&mut core_b, "世界");

        let conflicting_user =
            std::env::temp_dir().join(format!("feather-rime-rust-conflict-{suffix}"));
        let conflict = RimeRuntime::initialize(&RimePaths::new(&shared, &conflicting_user));
        assert!(conflict
            .err()
            .expect("不同用户目录必须被拒绝")
            .to_string()
            .contains("使用不同的数据目录"));

        drop(core_b);
        drop(runtime_b);
        std::fs::remove_dir_all(user).unwrap();
        std::fs::remove_dir_all(&conflicting_user).unwrap();

        let next_user = std::env::temp_dir().join(format!("feather-rime-rust-next-{suffix}"));
        let next_runtime = RimeRuntime::initialize(&RimePaths::new(&shared, &next_user)).unwrap();
        let next_engine = next_runtime.create_engine("luna_pinyin_simp").unwrap();
        drop(next_engine);
        drop(next_runtime);
        std::fs::remove_dir_all(next_user).unwrap();
    }
}
