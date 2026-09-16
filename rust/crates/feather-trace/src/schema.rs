use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Trace {
    pub name: String,
    pub steps: Vec<TraceStep>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum TraceStep {
    Activate {
        #[serde(default)]
        expect: ExpectedState,
    },
    Deactivate {
        #[serde(default)]
        expect: ExpectedState,
    },
    Text {
        value: String,
        #[serde(default)]
        expect: ExpectedState,
    },
    Key {
        key: TraceKey,
        #[serde(default)]
        expect: ExpectedState,
    },
    SetMode {
        mode: TraceMode,
        #[serde(default)]
        expect: ExpectedState,
    },
    SaveCandidate {
        name: String,
        text: String,
        #[serde(default)]
        occurrence: usize,
    },
    SelectCandidate {
        text: String,
        #[serde(default)]
        occurrence: usize,
        #[serde(default)]
        expect: ExpectedState,
    },
    SelectSavedCandidate {
        name: String,
        #[serde(default)]
        require_stale: bool,
        #[serde(default)]
        expect: ExpectedState,
    },
    Assert {
        expect: ExpectedState,
    },
}

impl TraceStep {
    pub(crate) fn label(&self) -> &'static str {
        match self {
            Self::Activate { .. } => "activate",
            Self::Deactivate { .. } => "deactivate",
            Self::Text { .. } => "text",
            Self::Key { .. } => "key",
            Self::SetMode { .. } => "set_mode",
            Self::SaveCandidate { .. } => "save_candidate",
            Self::SelectCandidate { .. } => "select_candidate",
            Self::SelectSavedCandidate { .. } => "select_saved_candidate",
            Self::Assert { .. } => "assert",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TraceKey {
    Backspace,
    Delete,
    Space,
    Enter,
    Escape,
    Left,
    Right,
    Up,
    Down,
    PageUp,
    PageDown,
    ToggleMode,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TraceMode {
    Native,
    Direct,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ExpectedState {
    pub handled: Option<bool>,
    pub active: Option<bool>,
    pub mode: Option<TraceMode>,
    pub commit: Option<String>,
    pub no_commit: bool,
    pub preedit: Option<String>,
    pub cursor_utf8: Option<usize>,
    pub candidates_contain: Vec<String>,
    pub candidates_exact: Option<Vec<String>>,
    pub candidate_count: Option<usize>,
    pub candidate_count_min: Option<usize>,
    pub highlighted_index: Option<usize>,
    pub highlighted_text: Option<String>,
}
