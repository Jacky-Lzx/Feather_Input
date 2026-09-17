use crate::{
    Candidate, CandidateId, CandidatePresentation, CandidateSlice, DispatchResult, EngineCommand,
    EngineError, InputEffect, InputEngine, InputEvent, InputMode, Key,
};

pub struct InputCoordinator {
    engine: Box<dyn InputEngine>,
    active: bool,
    mode: InputMode,
}

impl InputCoordinator {
    #[must_use]
    pub fn new(engine: impl InputEngine + 'static) -> Self {
        Self {
            engine: Box::new(engine),
            active: false,
            mode: InputMode::Native,
        }
    }

    #[must_use]
    pub fn is_active(&self) -> bool {
        self.active
    }

    #[must_use]
    pub fn mode(&self) -> InputMode {
        self.mode
    }

    /// Reads the current platform-independent presentation.
    ///
    /// # Errors
    ///
    /// Returns an engine error when a consistent snapshot is unavailable.
    pub fn presentation(&self) -> Result<CandidatePresentation, EngineError> {
        Ok(self.engine.snapshot()?.into())
    }

    /// Reads a revision-bound slice of the engine's complete candidate list.
    ///
    /// `None` means the requested revision is stale.
    ///
    /// # Errors
    ///
    /// Returns an engine error when the current snapshot or candidate list
    /// cannot be read consistently.
    pub fn candidate_slice(
        &self,
        revision: u64,
        offset: usize,
        limit: usize,
    ) -> Result<Option<CandidateSlice>, EngineError> {
        let snapshot = self.engine.snapshot()?;
        if snapshot.revision != revision {
            return Ok(None);
        }
        let slice = self.engine.candidate_slice(offset, limit)?;
        Ok(Some(CandidateSlice {
            revision,
            offset,
            candidates: slice
                .candidates
                .into_iter()
                .map(|candidate| Candidate {
                    id: CandidateId {
                        revision,
                        value: candidate.id.0,
                    },
                    text: candidate.text,
                    annotation: candidate.annotation,
                })
                .collect(),
            has_more: slice.has_more,
        }))
    }

    /// Dispatches one normalized platform event.
    ///
    /// # Errors
    ///
    /// Returns an engine error when the active engine cannot process the
    /// command while preserving a valid session.
    pub fn dispatch(&mut self, event: InputEvent) -> Result<DispatchResult, EngineError> {
        match event {
            InputEvent::Activate => {
                self.active = true;
                Ok(DispatchResult {
                    handled: true,
                    effects: vec![InputEffect::ModeChanged(self.mode)],
                })
            }
            InputEvent::Deactivate => {
                self.engine.reset();
                self.active = false;
                Ok(DispatchResult {
                    handled: true,
                    effects: vec![InputEffect::ClearMarkedText, InputEffect::HideCandidates],
                })
            }
            InputEvent::SetMode(mode) => self.set_mode(mode),
            InputEvent::SetSchema(schema) => self.set_schema(schema),
            InputEvent::SetPageSize(page_size) => self.set_page_size(page_size),
            InputEvent::SetEnglishCandidateMinimum(minimum) => {
                self.set_english_candidate_minimum(minimum)
            }
            InputEvent::SelectCandidate(id) => self.select_candidate(id),
            InputEvent::Key(key) => self.handle_key(key),
        }
    }

    fn set_mode(&mut self, mode: InputMode) -> Result<DispatchResult, EngineError> {
        if self.mode == mode {
            return Ok(DispatchResult::default());
        }
        self.engine.handle(EngineCommand::Cancel)?;
        self.mode = mode;
        Ok(DispatchResult {
            handled: true,
            effects: vec![
                InputEffect::ClearMarkedText,
                InputEffect::HideCandidates,
                InputEffect::ModeChanged(mode),
            ],
        })
    }

    fn set_schema(&mut self, schema: String) -> Result<DispatchResult, EngineError> {
        let response = self
            .engine
            .handle(EngineCommand::SelectSchema(schema.clone()))?;
        if !response.handled {
            return Ok(DispatchResult::default());
        }
        Ok(DispatchResult {
            handled: true,
            effects: vec![
                InputEffect::ClearMarkedText,
                InputEffect::HideCandidates,
                InputEffect::SchemaChanged(schema),
            ],
        })
    }

    fn set_page_size(&mut self, page_size: usize) -> Result<DispatchResult, EngineError> {
        let response = self.engine.handle(EngineCommand::SetPageSize(page_size))?;
        if !response.handled {
            return Ok(DispatchResult::default());
        }
        Ok(DispatchResult {
            handled: true,
            effects: vec![InputEffect::PageSizeChanged(page_size)],
        })
    }

    fn set_english_candidate_minimum(
        &mut self,
        minimum: usize,
    ) -> Result<DispatchResult, EngineError> {
        let response = self
            .engine
            .handle(EngineCommand::SetEnglishCandidateMinimum(minimum))?;
        if !response.handled {
            return Ok(DispatchResult::default());
        }
        Ok(DispatchResult {
            handled: true,
            effects: vec![InputEffect::EnglishCandidateMinimumChanged(minimum)],
        })
    }

    fn select_candidate(&mut self, id: CandidateId) -> Result<DispatchResult, EngineError> {
        if !self.active || self.mode == InputMode::Direct {
            return Ok(DispatchResult::default());
        }
        let snapshot = self.engine.snapshot()?;
        if id.revision != snapshot.revision {
            return Ok(DispatchResult::default());
        }
        self.run_engine(EngineCommand::Select(crate::EngineCandidateId(id.value)))
    }

    fn handle_key(&mut self, key: Key) -> Result<DispatchResult, EngineError> {
        if !self.active {
            return Ok(DispatchResult::default());
        }
        if key == Key::ToggleMode {
            let next = if self.mode == InputMode::Native {
                InputMode::Direct
            } else {
                InputMode::Native
            };
            return self.set_mode(next);
        }
        if self.mode == InputMode::Direct {
            return Ok(DispatchResult::default());
        }

        let command = match key {
            Key::Text(text) => EngineCommand::Insert(text),
            Key::Backspace => EngineCommand::Backspace,
            Key::Delete => EngineCommand::Delete,
            Key::Space => EngineCommand::CommitHighlighted,
            Key::Enter => EngineCommand::CommitRaw,
            Key::Escape => EngineCommand::Cancel,
            Key::Left | Key::Up => EngineCommand::MovePrevious,
            Key::Right | Key::Down => EngineCommand::MoveNext,
            Key::PageUp => EngineCommand::PagePrevious,
            Key::PageDown => EngineCommand::PageNext,
            Key::ToggleMode => unreachable!("mode toggle handled above"),
        };
        self.run_engine(command)
    }

    fn run_engine(&mut self, command: EngineCommand) -> Result<DispatchResult, EngineError> {
        let response = self.engine.handle(command)?;
        if !response.handled {
            return Ok(DispatchResult::default());
        }

        let presentation: CandidatePresentation = self.engine.snapshot()?.into();
        let mut effects = Vec::with_capacity(3);
        if let Some(commit) = response.commit {
            effects.push(InputEffect::CommitText(commit));
        }
        if presentation.preedit.is_empty() {
            effects.push(InputEffect::ClearMarkedText);
            effects.push(InputEffect::HideCandidates);
        } else {
            effects.push(InputEffect::SetMarkedText {
                text: presentation.preedit.clone(),
                cursor_utf8: presentation.cursor_utf8,
            });
            effects.push(InputEffect::ShowCandidates(presentation));
        }
        Ok(DispatchResult {
            handled: true,
            effects,
        })
    }
}
