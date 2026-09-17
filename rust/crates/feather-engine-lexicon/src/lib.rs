use feather_core::{
    EngineCandidate, EngineCandidateId, EngineCommand, EngineError, EngineResponse, EngineSnapshot,
    InputEngine,
};

#[derive(Clone, Copy)]
struct Entry {
    code: &'static str,
    text: &'static str,
}

const DEFAULT_LEXICON: &[Entry] = &[
    Entry {
        code: "ni",
        text: "你",
    },
    Entry {
        code: "ni",
        text: "尼",
    },
    Entry {
        code: "nihao",
        text: "你好",
    },
    Entry {
        code: "hao",
        text: "好",
    },
    Entry {
        code: "zhong",
        text: "中",
    },
    Entry {
        code: "shijie",
        text: "世界",
    },
    Entry {
        code: "shuru",
        text: "输入",
    },
    Entry {
        code: "shurufa",
        text: "输入法",
    },
];

pub struct LexiconEngine {
    input: String,
    revision: u64,
    highlighted: usize,
}

impl Default for LexiconEngine {
    fn default() -> Self {
        Self {
            input: String::new(),
            revision: 1,
            highlighted: 0,
        }
    }
}

impl LexiconEngine {
    fn candidates(&self) -> Vec<(usize, Entry)> {
        DEFAULT_LEXICON
            .iter()
            .copied()
            .enumerate()
            .filter(|(_, entry)| !self.input.is_empty() && entry.code.starts_with(&self.input))
            .collect()
    }

    fn mutate(&mut self) {
        self.revision = self.revision.wrapping_add(1).max(1);
        let count = self.candidates().len();
        self.highlighted = self.highlighted.min(count.saturating_sub(1));
    }

    fn clear(&mut self) {
        self.input.clear();
        self.highlighted = 0;
        self.mutate();
    }

    fn selected_text(&self, id: Option<EngineCandidateId>) -> Option<&'static str> {
        let candidates = self.candidates();
        match id {
            Some(id) => candidates
                .into_iter()
                .find(|(index, _)| u64::try_from(*index).ok() == Some(id.0))
                .map(|(_, entry)| entry.text),
            None => candidates
                .get(self.highlighted)
                .map(|(_, entry)| entry.text),
        }
    }
}

impl InputEngine for LexiconEngine {
    fn reset(&mut self) {
        self.clear();
    }

    fn handle(&mut self, command: EngineCommand) -> Result<EngineResponse, EngineError> {
        let mut response = EngineResponse {
            handled: true,
            commit: None,
        };
        match command {
            EngineCommand::Insert(text) => {
                if text.is_empty()
                    || !text
                        .bytes()
                        .all(|byte| byte.is_ascii_alphabetic() || byte == b'\'')
                {
                    response.handled = false;
                } else {
                    self.input.push_str(&text.to_ascii_lowercase());
                    self.mutate();
                }
            }
            EngineCommand::Backspace => {
                if self.input.pop().is_none() {
                    response.handled = false;
                } else {
                    self.mutate();
                }
            }
            EngineCommand::Delete
            | EngineCommand::SelectSchema(_)
            | EngineCommand::SetPageSize(_) => response.handled = false,
            EngineCommand::Cancel => {
                if self.input.is_empty() {
                    response.handled = false;
                } else {
                    self.clear();
                }
            }
            EngineCommand::CommitHighlighted => {
                if self.input.is_empty() {
                    response.handled = false;
                } else {
                    response.commit = Some(
                        self.selected_text(None)
                            .map_or_else(|| self.input.clone(), str::to_owned),
                    );
                    self.clear();
                }
            }
            EngineCommand::CommitRaw => {
                if self.input.is_empty() {
                    response.handled = false;
                } else {
                    response.commit = Some(self.input.clone());
                    self.clear();
                }
            }
            EngineCommand::Select(id) => {
                if let Some(text) = self.selected_text(Some(id)) {
                    response.commit = Some(text.to_owned());
                    self.clear();
                } else {
                    response.handled = false;
                }
            }
            EngineCommand::MovePrevious | EngineCommand::PagePrevious => {
                let count = self.candidates().len();
                if count == 0 {
                    response.handled = false;
                } else {
                    self.highlighted = self.highlighted.checked_sub(1).unwrap_or(count - 1);
                }
            }
            EngineCommand::MoveNext | EngineCommand::PageNext => {
                let count = self.candidates().len();
                if count == 0 {
                    response.handled = false;
                } else {
                    self.highlighted = (self.highlighted + 1) % count;
                }
            }
        }
        Ok(response)
    }

    fn snapshot(&self) -> Result<EngineSnapshot, EngineError> {
        let candidates = self.candidates();
        Ok(EngineSnapshot {
            revision: self.revision,
            preedit: self.input.clone(),
            cursor_utf8: self.input.len(),
            highlighted: (!candidates.is_empty()).then_some(self.highlighted),
            candidates: candidates
                .into_iter()
                .map(|(index, entry)| EngineCandidate {
                    id: EngineCandidateId(u64::try_from(index).expect("lexicon index fits in u64")),
                    text: entry.text.to_owned(),
                    annotation: Some(entry.code.to_owned()),
                })
                .collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use feather_core::{InputCoordinator, InputEffect, InputEvent, Key};

    #[test]
    fn complete_input_method_path_commits_candidate() {
        let mut core = InputCoordinator::new(LexiconEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        for character in "nihao".chars() {
            core.dispatch(InputEvent::Key(Key::Text(character.to_string())))
                .unwrap();
        }
        let presentation = core.presentation().unwrap();
        assert_eq!(presentation.preedit, "nihao");
        assert_eq!(presentation.candidates[0].text, "你好");
        let result = core.dispatch(InputEvent::Key(Key::Space)).unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText("你好".into())));
        assert!(core.presentation().unwrap().preedit.is_empty());
    }

    #[test]
    fn candidate_selection_uses_identity_not_display_position() {
        let mut core = InputCoordinator::new(LexiconEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("ni".into())))
            .unwrap();
        let second = core.presentation().unwrap().candidates[1].id;
        let result = core.dispatch(InputEvent::SelectCandidate(second)).unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText("尼".into())));
    }

    #[test]
    fn return_commits_raw_input_and_escape_cancels() {
        let mut core = InputCoordinator::new(LexiconEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("unknown".into())))
            .unwrap();
        let result = core.dispatch(InputEvent::Key(Key::Enter)).unwrap();
        assert!(result
            .effects
            .contains(&InputEffect::CommitText("unknown".into())));
        core.dispatch(InputEvent::Key(Key::Text("ni".into())))
            .unwrap();
        core.dispatch(InputEvent::Key(Key::Escape)).unwrap();
        assert!(core.presentation().unwrap().preedit.is_empty());
    }
}
