mod coordinator;
mod engine;
mod model;

pub use coordinator::InputCoordinator;
pub use engine::{EngineCommand, EngineError, EngineResponse, InputEngine};
pub use model::{
    Candidate, CandidateId, CandidatePresentation, DispatchResult, EngineCandidate,
    EngineCandidateId, EngineSnapshot, InputEffect, InputEvent, InputMode, Key,
};

pub const ABI_VERSION: u32 = 1;

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
                EngineCommand::Select(_) => {
                    let commit = std::mem::take(&mut self.text);
                    self.revision += 1;
                    return Ok(EngineResponse {
                        handled: true,
                        commit: Some(format!("selected:{commit}")),
                    });
                }
                _ => {}
            }
            self.revision += 1;
            Ok(EngineResponse {
                handled: true,
                commit: None,
            })
        }

        fn snapshot(&self) -> EngineSnapshot {
            EngineSnapshot {
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
            }
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
        let old = core.presentation().candidates[0].id;
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
}
