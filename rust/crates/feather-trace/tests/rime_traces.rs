use feather_engine_rime::{RimePaths, RimeRuntime};
use feather_trace::{parse_trace, run_trace};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

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
        "paging.json",
        include_str!("../../../traces/rime/paging.json"),
    ),
];

#[test]
#[ignore = "需要 FEATHER_RIME_SHARED_DATA_DIR 指向已经部署的 Rime 数据"]
fn common_traces_pass_with_real_rime() {
    let shared = PathBuf::from(
        std::env::var_os("FEATHER_RIME_SHARED_DATA_DIR")
            .expect("需要 FEATHER_RIME_SHARED_DATA_DIR"),
    );
    for (index, (file, source)) in TRACES.iter().enumerate() {
        let user = TemporaryUserDirectory::new(index);
        run_one(file, source, &shared, user.path());
        user.cleanup();
        eprintln!("通过：{file}");
    }
}

fn run_one(file: &str, source: &str, shared: &Path, user: &Path) {
    let runtime = RimeRuntime::initialize(&RimePaths::new(shared, user))
        .unwrap_or_else(|error| panic!("{file}: {error}"));
    let engine = runtime
        .create_engine("luna_pinyin_simp")
        .unwrap_or_else(|error| panic!("{file}: {error}"));
    let trace = parse_trace(source).unwrap_or_else(|error| panic!("{file}: {error}"));
    run_trace(&trace, engine).unwrap_or_else(|error| panic!("{file}: {error}"));
    drop(runtime);
}

fn temporary_user_directory(index: usize) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("feather-rime-trace-{suffix}-{index}"))
}

struct TemporaryUserDirectory(PathBuf);

impl TemporaryUserDirectory {
    fn new(index: usize) -> Self {
        Self(temporary_user_directory(index))
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn cleanup(self) {
        if self.0.exists() {
            std::fs::remove_dir_all(&self.0).unwrap_or_else(|error| {
                panic!("无法清理临时 Rime 用户目录 {}：{error}", self.0.display())
            });
        }
    }
}

impl Drop for TemporaryUserDirectory {
    fn drop(&mut self) {
        if self.0.exists() {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
