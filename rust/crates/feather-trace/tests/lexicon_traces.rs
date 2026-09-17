use feather_engine_lexicon::LexiconEngine;
use feather_trace::{parse_trace, run_trace};

const TRACES: &[(&str, &str)] = &[
    (
        "commit_candidate.json",
        include_str!("../../../traces/common/commit_candidate.json"),
    ),
    (
        "raw_commit_and_cancel.json",
        include_str!("../../../traces/common/raw_commit_and_cancel.json"),
    ),
    (
        "raw_symbol_commit.json",
        include_str!("../../../traces/common/raw_symbol_commit.json"),
    ),
    (
        "stale_candidate.json",
        include_str!("../../../traces/common/stale_candidate.json"),
    ),
    (
        "mode_and_lifecycle.json",
        include_str!("../../../traces/common/mode_and_lifecycle.json"),
    ),
    (
        "backspace.json",
        include_str!("../../../traces/common/backspace.json"),
    ),
    (
        "navigation.json",
        include_str!("../../../traces/lexicon/navigation.json"),
    ),
];

#[test]
fn common_and_lexicon_traces_pass() {
    for (file, source) in TRACES {
        let trace = parse_trace(source).unwrap_or_else(|error| panic!("{file}: {error}"));
        run_trace(&trace, LexiconEngine::default())
            .unwrap_or_else(|error| panic!("{file}: {error}"));
    }
}
