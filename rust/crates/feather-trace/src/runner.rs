use crate::{ExpectedState, Trace, TraceKey, TraceMode, TraceStep};
use feather_core::{
    CandidateId, CandidatePresentation, DispatchResult, InputCoordinator, InputEffect, InputEngine,
    InputEvent, InputMode, Key,
};
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt::{Display, Formatter, Write};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceReport {
    pub name: String,
    pub steps_completed: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceFailure {
    pub trace: String,
    pub step: usize,
    pub action: String,
    pub message: String,
    pub actual: String,
}

impl Display for TraceFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "Trace “{}” 第 {} 步（{}）失败：{}\n实际状态：\n{}",
            self.trace,
            self.step + 1,
            self.action,
            self.message,
            self.actual
        )
    }
}

impl Error for TraceFailure {}

struct ObservedState {
    handled: Option<bool>,
    commit: Option<String>,
    active: bool,
    mode: InputMode,
    presentation: CandidatePresentation,
}

/// Runs a declarative behavior trace against one input engine.
///
/// Candidate selections are resolved to the current opaque candidate ID at
/// runtime. Saved candidates retain their original revision so traces can
/// verify stale-selection rejection without depending on engine indices.
///
/// # Errors
///
/// Returns a detailed failure containing the step and current state when the
/// engine rejects an operation, violates an invariant, or misses an expected
/// semantic result.
pub fn run_trace(
    trace: &Trace,
    engine: impl InputEngine + 'static,
) -> Result<TraceReport, TraceFailure> {
    let mut runner = Runner {
        trace,
        core: InputCoordinator::new(engine),
        saved_candidates: HashMap::new(),
        last_handled: None,
        last_commit: None,
    };
    for (index, step) in trace.steps.iter().enumerate() {
        runner.run_step(index, step)?;
    }
    Ok(TraceReport {
        name: trace.name.clone(),
        steps_completed: trace.steps.len(),
    })
}

struct Runner<'a> {
    trace: &'a Trace,
    core: InputCoordinator,
    saved_candidates: HashMap<String, CandidateId>,
    last_handled: Option<bool>,
    last_commit: Option<String>,
}

impl Runner<'_> {
    fn run_step(&mut self, index: usize, step: &TraceStep) -> Result<(), TraceFailure> {
        match step {
            TraceStep::Activate { expect } => {
                self.dispatch(index, step, InputEvent::Activate, expect)
            }
            TraceStep::Deactivate { expect } => {
                self.dispatch(index, step, InputEvent::Deactivate, expect)
            }
            TraceStep::Text { value, expect } => self.dispatch(
                index,
                step,
                InputEvent::Key(Key::Text(value.clone())),
                expect,
            ),
            TraceStep::Key { key, expect } => {
                self.dispatch(index, step, InputEvent::Key((*key).into()), expect)
            }
            TraceStep::SetMode { mode, expect } => {
                self.dispatch(index, step, InputEvent::SetMode((*mode).into()), expect)
            }
            TraceStep::SaveCandidate {
                name,
                text,
                occurrence,
            } => {
                let candidate = self.current_candidate_id(index, step, text, *occurrence)?;
                self.saved_candidates.insert(name.clone(), candidate);
                Ok(())
            }
            TraceStep::SelectCandidate {
                text,
                occurrence,
                expect,
            } => {
                let candidate = self.current_candidate_id(index, step, text, *occurrence)?;
                self.dispatch(index, step, InputEvent::SelectCandidate(candidate), expect)
            }
            TraceStep::SelectSavedCandidate {
                name,
                require_stale,
                expect,
            } => {
                let Some(candidate) = self.saved_candidates.get(name).copied() else {
                    let state = self.observe(index, step)?;
                    return Err(self.failure(
                        index,
                        step,
                        format!("没有名为“{name}”的已保存候选"),
                        &state,
                    ));
                };
                if *require_stale {
                    let state = self.observe(index, step)?;
                    if candidate.revision == state.presentation.revision {
                        return Err(self.failure(
                            index,
                            step,
                            format!("候选“{name}”仍属于当前 revision，无法验证过期选择"),
                            &state,
                        ));
                    }
                }
                self.dispatch(index, step, InputEvent::SelectCandidate(candidate), expect)
            }
            TraceStep::Assert { expect } => {
                let state = self.observe(index, step)?;
                self.check_expectation(index, step, expect, &state)
            }
        }
    }

    fn current_candidate_id(
        &self,
        index: usize,
        step: &TraceStep,
        text: &str,
        occurrence: usize,
    ) -> Result<CandidateId, TraceFailure> {
        let state = self.observe(index, step)?;
        state
            .presentation
            .candidates
            .iter()
            .filter(|candidate| candidate.text == text)
            .nth(occurrence)
            .map(|candidate| candidate.id)
            .ok_or_else(|| {
                self.failure(
                    index,
                    step,
                    format!("当前候选中不存在第 {} 个“{text}”", occurrence + 1),
                    &state,
                )
            })
    }

    fn dispatch(
        &mut self,
        index: usize,
        step: &TraceStep,
        event: InputEvent,
        expect: &ExpectedState,
    ) -> Result<(), TraceFailure> {
        let result = self.core.dispatch(event).map_err(|error| {
            let state = self.observe_fallible();
            TraceFailure {
                trace: self.trace.name.clone(),
                step: index,
                action: step.label().to_owned(),
                message: format!("引擎返回错误：{error}"),
                actual: state,
            }
        })?;
        self.last_handled = Some(result.handled);
        self.last_commit = commit_from(&result);
        let state = self.observe(index, step)?;
        self.check_expectation(index, step, expect, &state)
    }

    fn observe(&self, index: usize, step: &TraceStep) -> Result<ObservedState, TraceFailure> {
        let presentation = self.core.presentation().map_err(|error| TraceFailure {
            trace: self.trace.name.clone(),
            step: index,
            action: step.label().to_owned(),
            message: format!("无法读取引擎快照：{error}"),
            actual: self.observe_fallible(),
        })?;
        let state = ObservedState {
            handled: self.last_handled,
            commit: self.last_commit.clone(),
            active: self.core.is_active(),
            mode: self.core.mode(),
            presentation,
        };
        self.check_invariants(index, step, &state)?;
        Ok(state)
    }

    fn check_invariants(
        &self,
        index: usize,
        step: &TraceStep,
        state: &ObservedState,
    ) -> Result<(), TraceFailure> {
        let presentation = &state.presentation;
        if presentation.cursor_utf8 > presentation.preedit.len()
            || !presentation
                .preedit
                .is_char_boundary(presentation.cursor_utf8)
        {
            return Err(self.failure(
                index,
                step,
                "cursor_utf8 不在预编辑字符串的 UTF-8 边界上".into(),
                state,
            ));
        }
        if presentation
            .highlighted
            .is_some_and(|highlighted| highlighted >= presentation.candidates.len())
        {
            return Err(self.failure(index, step, "高亮候选越界".into(), state));
        }

        let mut values = HashSet::new();
        for candidate in &presentation.candidates {
            if candidate.id.revision != presentation.revision {
                return Err(self.failure(
                    index,
                    step,
                    format!(
                        "候选“{}”的 revision {} 与快照 revision {} 不一致",
                        candidate.text, candidate.id.revision, presentation.revision
                    ),
                    state,
                ));
            }
            if !values.insert(candidate.id.value) {
                return Err(self.failure(
                    index,
                    step,
                    format!("候选 ID {} 在当前快照中重复", candidate.id.value),
                    state,
                ));
            }
        }
        Ok(())
    }

    fn check_expectation(
        &self,
        index: usize,
        step: &TraceStep,
        expected: &ExpectedState,
        state: &ObservedState,
    ) -> Result<(), TraceFailure> {
        macro_rules! check {
            ($condition:expr, $message:expr) => {
                if !$condition {
                    return Err(self.failure(index, step, $message, state));
                }
            };
        }

        if let Some(handled) = expected.handled {
            check!(
                state.handled == Some(handled),
                format!("预期 handled={handled}")
            );
        }
        if let Some(active) = expected.active {
            check!(state.active == active, format!("预期 active={active}"));
        }
        if let Some(mode) = expected.mode {
            let actual: TraceMode = state.mode.into();
            check!(actual == mode, format!("预期 mode={mode:?}"));
        }
        if let Some(commit) = &expected.commit {
            check!(
                state.commit.as_ref() == Some(commit),
                format!("预期提交“{commit}”")
            );
        }
        if expected.no_commit {
            check!(state.commit.is_none(), "预期不产生提交".into());
        }
        if let Some(preedit) = &expected.preedit {
            check!(
                state.presentation.preedit == *preedit,
                format!("预期 preedit=“{preedit}”")
            );
        }
        if let Some(cursor) = expected.cursor_utf8 {
            check!(
                state.presentation.cursor_utf8 == cursor,
                format!("预期 cursor_utf8={cursor}")
            );
        }
        let texts: Vec<&str> = state
            .presentation
            .candidates
            .iter()
            .map(|candidate| candidate.text.as_str())
            .collect();
        for candidate in &expected.candidates_contain {
            check!(
                texts.contains(&candidate.as_str()),
                format!("预期候选包含“{candidate}”")
            );
        }
        if let Some(exact) = &expected.candidates_exact {
            let exact: Vec<&str> = exact.iter().map(String::as_str).collect();
            check!(texts == exact, format!("预期候选精确等于 {exact:?}"));
        }
        if let Some(count) = expected.candidate_count {
            check!(
                state.presentation.candidates.len() == count,
                format!("预期 candidate_count={count}")
            );
        }
        if let Some(minimum) = expected.candidate_count_min {
            check!(
                state.presentation.candidates.len() >= minimum,
                format!("预期 candidate_count >= {minimum}")
            );
        }
        if let Some(highlighted) = expected.highlighted_index {
            check!(
                state.presentation.highlighted == Some(highlighted),
                format!("预期 highlighted_index={highlighted}")
            );
        }
        if let Some(text) = &expected.highlighted_text {
            let actual = state
                .presentation
                .highlighted
                .and_then(|highlighted| state.presentation.candidates.get(highlighted))
                .map(|candidate| candidate.text.as_str());
            check!(actual == Some(text.as_str()), format!("预期高亮“{text}”"));
        }
        Ok(())
    }

    fn failure(
        &self,
        index: usize,
        step: &TraceStep,
        message: String,
        state: &ObservedState,
    ) -> TraceFailure {
        TraceFailure {
            trace: self.trace.name.clone(),
            step: index,
            action: step.label().to_owned(),
            message,
            actual: format_state(state),
        }
    }

    fn observe_fallible(&self) -> String {
        match self.core.presentation() {
            Ok(presentation) => format_state(&ObservedState {
                handled: self.last_handled,
                commit: self.last_commit.clone(),
                active: self.core.is_active(),
                mode: self.core.mode(),
                presentation,
            }),
            Err(error) => format!("<快照不可用：{error}>"),
        }
    }
}

fn commit_from(result: &DispatchResult) -> Option<String> {
    result.effects.iter().find_map(|effect| match effect {
        InputEffect::CommitText(text) => Some(text.clone()),
        _ => None,
    })
}

fn format_state(state: &ObservedState) -> String {
    let mut output = String::new();
    let _ = writeln!(output, "  handled = {:?}", state.handled);
    let _ = writeln!(output, "  active = {}", state.active);
    let _ = writeln!(output, "  mode = {:?}", state.mode);
    let _ = writeln!(output, "  commit = {:?}", state.commit);
    let _ = writeln!(output, "  revision = {}", state.presentation.revision);
    let _ = writeln!(output, "  preedit = {:?}", state.presentation.preedit);
    let _ = writeln!(output, "  cursor_utf8 = {}", state.presentation.cursor_utf8);
    let _ = writeln!(
        output,
        "  highlighted = {:?}",
        state.presentation.highlighted
    );
    let candidates: Vec<String> = state
        .presentation
        .candidates
        .iter()
        .map(|candidate| {
            format!(
                "{} [r{}, id{}]",
                candidate.text, candidate.id.revision, candidate.id.value
            )
        })
        .collect();
    let _ = write!(output, "  candidates = [{}]", candidates.join(", "));
    output
}

impl From<TraceKey> for Key {
    fn from(key: TraceKey) -> Self {
        match key {
            TraceKey::Backspace => Self::Backspace,
            TraceKey::Delete => Self::Delete,
            TraceKey::Space => Self::Space,
            TraceKey::Enter => Self::Enter,
            TraceKey::Escape => Self::Escape,
            TraceKey::Left => Self::Left,
            TraceKey::Right => Self::Right,
            TraceKey::Up => Self::Up,
            TraceKey::Down => Self::Down,
            TraceKey::PageUp => Self::PageUp,
            TraceKey::PageDown => Self::PageDown,
            TraceKey::ToggleMode => Self::ToggleMode,
        }
    }
}

impl From<TraceMode> for InputMode {
    fn from(mode: TraceMode) -> Self {
        match mode {
            TraceMode::Native => Self::Native,
            TraceMode::Direct => Self::Direct,
        }
    }
}

impl From<InputMode> for TraceMode {
    fn from(mode: InputMode) -> Self {
        match mode {
            InputMode::Native => Self::Native,
            InputMode::Direct => Self::Direct,
        }
    }
}
