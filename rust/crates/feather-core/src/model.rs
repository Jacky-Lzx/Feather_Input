#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum InputMode {
    #[default]
    Native,
    Direct,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct EngineCandidateId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct CandidateId {
    pub revision: u64,
    pub value: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineCandidate {
    pub id: EngineCandidateId,
    pub text: String,
    pub annotation: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EngineCandidateSlice {
    pub candidates: Vec<EngineCandidate>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EngineSnapshot {
    pub revision: u64,
    pub preedit: String,
    pub cursor_utf8: usize,
    pub candidates: Vec<EngineCandidate>,
    pub highlighted: Option<usize>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Candidate {
    pub id: CandidateId,
    pub text: String,
    pub annotation: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CandidateSlice {
    pub revision: u64,
    pub offset: usize,
    pub candidates: Vec<Candidate>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CandidatePresentation {
    pub revision: u64,
    pub preedit: String,
    pub cursor_utf8: usize,
    pub candidates: Vec<Candidate>,
    pub highlighted: Option<usize>,
}

impl From<EngineSnapshot> for CandidatePresentation {
    fn from(snapshot: EngineSnapshot) -> Self {
        Self {
            revision: snapshot.revision,
            preedit: snapshot.preedit,
            cursor_utf8: snapshot.cursor_utf8,
            highlighted: snapshot.highlighted,
            candidates: snapshot
                .candidates
                .into_iter()
                .map(|candidate| Candidate {
                    id: CandidateId {
                        revision: snapshot.revision,
                        value: candidate.id.0,
                    },
                    text: candidate.text,
                    annotation: candidate.annotation,
                })
                .collect(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Key {
    Text(String),
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InputEvent {
    Activate,
    Deactivate,
    Key(Key),
    SelectCandidate(CandidateId),
    SetMode(InputMode),
    SetSchema(String),
    SetPageSize(usize),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InputEffect {
    CommitText(String),
    SetMarkedText { text: String, cursor_utf8: usize },
    ClearMarkedText,
    ShowCandidates(CandidatePresentation),
    HideCandidates,
    ModeChanged(InputMode),
    SchemaChanged(String),
    PageSizeChanged(usize),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DispatchResult {
    pub handled: bool,
    pub effects: Vec<InputEffect>,
}
