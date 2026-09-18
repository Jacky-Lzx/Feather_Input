mod coordinator;
mod engine;
mod model;

pub use coordinator::InputCoordinator;
pub use engine::{EngineCommand, EngineError, EngineResponse, InputEngine};
pub use model::{
    Candidate, CandidateId, CandidatePresentation, CandidateSlice, DispatchResult, EngineCandidate,
    EngineCandidateId, EngineCandidateSlice, EngineSnapshot, InputEffect, InputEvent, InputMode,
    Key,
};

pub const ABI_VERSION: u32 = 2;

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeEngine {
        revision: u64,
        text: String,
    }

    impl InputEngine for FakeEngine {
        fn reset(&mut self) {
            self.text.clear();
            self.revision += 1;
        }

        fn handle(&mut self, command: EngineCommand) -> Result<EngineResponse, EngineError> {
            match command {
                EngineCommand::Insert(text) => self.text.push_str(&text),
                EngineCommand::Backspace => {
                    self.text.pop();
                }
                EngineCommand::Cancel => self.text.clear(),
                EngineCommand::CommitHighlighted | EngineCommand::CommitRaw => {
                    let commit = std::mem::take(&mut self.text);
                    self.revision += 1;
                    return Ok(EngineResponse {
                        handled: !commit.is_empty(),
                        commit: (!commit.is_empty()).then_some(commit),
                    });
                }
                EngineCommand::Select(EngineCandidateId(7)) => {
                    let commit = std::mem::take(&mut self.text);
                    self.revision += 1;
                    return Ok(EngineResponse {
                        handled: true,
                        commit: Some(format!("selected:{commit}")),
                    });
                }
                EngineCommand::Select(_) => {
                    return Ok(EngineResponse::default());
                }
                _ => {}
            }
            self.revision += 1;
            Ok(EngineResponse {
                handled: true,
                commit: None,
            })
        }

        fn snapshot(&self) -> Result<EngineSnapshot, EngineError> {
            Ok(EngineSnapshot {
                revision: self.revision,
                preedit: self.text.clone(),
                cursor_utf8: self.text.len(),
                candidates: (!self.text.is_empty())
                    .then(|| EngineCandidate {
                        id: EngineCandidateId(7),
                        text: format!("candidate:{}", self.text),
                        annotation: None,
                    })
                    .into_iter()
                    .collect(),
                highlighted: (!self.text.is_empty()).then_some(0),
            })
        }
    }

    #[test]
    fn inactive_and_direct_modes_pass_text_through() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        assert!(
            !core
                .dispatch(InputEvent::Key(Key::Text("n".into())))
                .unwrap()
                .handled
        );
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::SetMode(InputMode::Direct))
            .unwrap();
        assert!(
            !core
                .dispatch(InputEvent::Key(Key::Text("n".into())))
                .unwrap()
                .handled
        );
    }

    #[test]
    fn stale_candidate_identity_is_rejected() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("n".into())))
            .unwrap();
        let old = core.presentation().unwrap().candidates[0].id;
        core.dispatch(InputEvent::Key(Key::Text("i".into())))
            .unwrap();
        assert!(
            !core
                .dispatch(InputEvent::SelectCandidate(old))
                .unwrap()
                .handled
        );
    }

    #[test]
    fn candidate_slices_are_revision_bound_and_keep_opaque_ids() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("n".into())))
            .unwrap();
        let revision = core.presentation().unwrap().revision;
        let slice = core.candidate_slice(revision, 0, 8).unwrap().unwrap();
        assert_eq!(slice.revision, revision);
        assert_eq!(slice.candidates[0].id, CandidateId { revision, value: 7 });
        assert!(!slice.has_more);

        core.dispatch(InputEvent::Key(Key::Text("i".into())))
            .unwrap();
        assert!(core.candidate_slice(revision, 0, 8).unwrap().is_none());
    }

    #[test]
    fn unknown_candidate_identity_is_rejected_by_engine() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("n".into())))
            .unwrap();
        let revision = core.presentation().unwrap().revision;
        let result = core
            .dispatch(InputEvent::SelectCandidate(CandidateId {
                revision,
                value: 999,
            }))
            .unwrap();
        assert!(!result.handled);
    }

    #[test]
    fn engine_commit_becomes_platform_effect() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("ni".into())))
            .unwrap();
        let result = core.dispatch(InputEvent::Key(Key::Space)).unwrap();
        assert_eq!(
            result.effects,
            vec![
                InputEffect::CommitText("ni".into()),
                InputEffect::ClearMarkedText,
                InputEffect::HideCandidates,
            ]
        );
    }

    #[test]
    fn switching_to_direct_mode_commits_raw_composition() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("nihao".into())))
            .unwrap();

        let result = core.dispatch(InputEvent::Key(Key::ToggleMode)).unwrap();

        assert_eq!(
            result.effects,
            vec![
                InputEffect::CommitText("nihao".into()),
                InputEffect::ClearMarkedText,
                InputEffect::HideCandidates,
                InputEffect::ModeChanged(InputMode::Direct),
            ]
        );
        assert_eq!(core.mode(), InputMode::Direct);
        assert!(core.presentation().unwrap().preedit.is_empty());
    }

    #[test]
    fn ascii_symbols_commit_raw_composition_without_selecting_candidate() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        core.dispatch(InputEvent::Activate).unwrap();
        core.dispatch(InputEvent::Key(Key::Text("ni".into())))
            .unwrap();

        let result = core
            .dispatch(InputEvent::Key(Key::Text(".@".into())))
            .unwrap();

        assert_eq!(
            result.effects,
            vec![
                InputEffect::CommitText("ni.@".into()),
                InputEffect::ClearMarkedText,
                InputEffect::HideCandidates,
            ]
        );
        assert!(core.presentation().unwrap().preedit.is_empty());
    }

    #[test]
    fn page_size_is_dispatched_as_an_engine_setting() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        let result = core.dispatch(InputEvent::SetPageSize(7)).unwrap();
        assert!(result.handled);
        assert_eq!(result.effects, vec![InputEffect::PageSizeChanged(7)]);
    }

    #[test]
    fn english_candidate_minimum_is_dispatched_as_an_engine_setting() {
        let mut core = InputCoordinator::new(FakeEngine::default());
        let result = core
            .dispatch(InputEvent::SetEnglishCandidateMinimum(5))
            .unwrap();
        assert!(result.handled);
        assert_eq!(
            result.effects,
            vec![InputEffect::EnglishCandidateMinimumChanged(5)]
        );
    }
}
