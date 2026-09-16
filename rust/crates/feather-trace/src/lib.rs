//! 平台无关的输入法行为 Trace 格式与执行器。

mod runner;
mod schema;

pub use runner::{run_trace, TraceFailure, TraceReport};
pub use schema::{ExpectedState, Trace, TraceKey, TraceMode, TraceStep};

/// Parses one UTF-8 JSON trace.
///
/// # Errors
///
/// Returns a JSON decoding error when the document does not match the trace
/// schema.
pub fn parse_trace(source: &str) -> Result<Trace, serde_json::Error> {
    serde_json::from_str(source)
}

#[cfg(test)]
mod tests {
    use super::*;
    use feather_engine_lexicon::LexiconEngine;

    #[test]
    fn unknown_json_fields_are_rejected() {
        let error = parse_trace(
            r#"{
                "name": "invalid",
                "steps": [{"action": "activate", "unexpected": true}]
            }"#,
        )
        .unwrap_err();
        assert!(error.to_string().contains("unknown field"));
    }

    #[test]
    fn failures_include_step_and_observed_state() {
        let trace = parse_trace(
            r#"{
                "name": "failure report",
                "steps": [
                    {"action": "activate"},
                    {
                        "action": "text",
                        "value": "ni",
                        "expect": {"commit": "不会出现"}
                    }
                ]
            }"#,
        )
        .unwrap();
        let error = run_trace(&trace, LexiconEngine::default()).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("第 2 步（text）失败"));
        assert!(message.contains("预期提交“不会出现”"));
        assert!(message.contains("preedit = \"ni\""));
        assert!(message.contains("candidates = [你"));
    }
}
