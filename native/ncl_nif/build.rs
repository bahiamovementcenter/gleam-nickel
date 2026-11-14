//! Reads the version of `nickel-lang-core` from the lock file, for `core_version/0`.

fn main() {
    let lock_path = concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.lock");
    println!("cargo::rerun-if-changed={lock_path}");
    let lock = std::fs::read_to_string(lock_path).expect("Cargo.lock is readable");
    let version = lock
        .split("[[package]]")
        .find(|p| p.contains("name = \"nickel-lang-core\""))
        .and_then(|p| p.lines().find_map(|l| l.strip_prefix("version = ")))
        .map(|v| v.trim_matches('"').to_owned())
        .expect("Cargo.lock lists nickel-lang-core");
    println!("cargo::rustc-env=NICKEL_CORE_VERSION={version}");
}
