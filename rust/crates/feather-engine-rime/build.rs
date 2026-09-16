use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn pkg_config(flag: &str) -> Option<PathBuf> {
    let output = Command::new("pkg-config")
        .args([flag, "rime"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let prefix = if flag.contains("cflags") { "-I" } else { "-L" };
    String::from_utf8(output.stdout)
        .ok()?
        .split_whitespace()
        .find_map(|item| item.strip_prefix(prefix).map(PathBuf::from))
}

fn required_path(variable: &str, pkg_flag: &str) -> PathBuf {
    env::var_os(variable)
        .map(PathBuf::from)
        .or_else(|| pkg_config(pkg_flag))
        .unwrap_or_else(|| {
            panic!("找不到 librime；请安装 pkg-config 可发现的 librime，或设置 {variable}")
        })
}

fn run(command: &mut Command, description: &str) {
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("无法执行{description}：{error}"));
    assert!(status.success(), "{description}失败：{status}");
}

fn main() {
    println!("cargo:rerun-if-changed=src/bridge.c");
    println!("cargo:rerun-if-env-changed=RIME_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=RIME_LIB_DIR");

    let include = required_path("RIME_INCLUDE_DIR", "--cflags-only-I");
    let library = required_path("RIME_LIB_DIR", "--libs-only-L");
    assert!(
        include.join("rime_api.h").is_file(),
        "{} 中没有 rime_api.h",
        include.display()
    );

    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo 必须提供 OUT_DIR"));
    let object = output.join("bridge.o");
    let archive = output.join("libfeather_rime_bridge.a");
    let compiler = env::var_os("CC").unwrap_or_else(|| "cc".into());
    let archiver = env::var_os("AR").unwrap_or_else(|| "ar".into());

    run(
        Command::new(compiler)
            .arg("-std=c11")
            .arg("-fPIC")
            .arg("-Wall")
            .arg("-Wextra")
            .arg("-Werror")
            .arg("-I")
            .arg(&include)
            .arg("-c")
            .arg(Path::new("src/bridge.c"))
            .arg("-o")
            .arg(&object),
        "编译 librime C bridge",
    );
    run(
        Command::new(archiver).arg("crs").arg(&archive).arg(&object),
        "归档 librime C bridge",
    );

    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-search=native={}", library.display());
    println!("cargo:rustc-link-lib=static=feather_rime_bridge");
    println!("cargo:rustc-link-lib=dylib=rime");
}
