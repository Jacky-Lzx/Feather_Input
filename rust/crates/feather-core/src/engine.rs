use crate::{EngineCandidateId, EngineSnapshot};
use std::error::Error;
use std::fmt::{Display, Formatter};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EngineCommand {
    Insert(String),
    Backspace,
    Delete,
    CommitHighlighted,
    CommitRaw,
    Cancel,
    MovePrevious,
    MoveNext,
    PagePrevious,
    PageNext,
    Select(EngineCandidateId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EngineResponse {
    pub handled: bool,
    pub commit: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineError {
    message: String,
}

impl EngineError {
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl Display for EngineError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EngineError {}

pub trait InputEngine: Send {
    fn reset(&mut self);

    /// Applies one atomic engine command.
    ///
    /// # Errors
    ///
    /// Returns an error when the engine cannot preserve a valid session after
    /// processing the command. Unsupported commands should instead return an
    /// `EngineResponse` with `handled` set to false.
    fn handle(&mut self, command: EngineCommand) -> Result<EngineResponse, EngineError>;
    /// Reads an immutable view of the current engine state.
    ///
    /// # Errors
    ///
    /// Returns an error when the engine session can no longer provide a
    /// consistent composition and candidate snapshot.
    fn snapshot(&self) -> Result<EngineSnapshot, EngineError>;
}
