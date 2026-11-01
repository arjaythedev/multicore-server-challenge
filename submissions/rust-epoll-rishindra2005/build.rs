use std::env;
use std::process::Command;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap_or_else(|_| "target".into());

    let compiler = if Command::new("clang").arg("--version").output().is_ok() {
        "clang"
    } else {
        "gcc"
    };

    let obj_path = format!("{}/fast_glue.o", out_dir);
    let asm_obj_path = format!("{}/fast_asm.o", out_dir);
    let lib_path = format!("{}/libfast_glue.a", out_dir);

    let status_c = Command::new(compiler)
        .args([
            "-O3",
            "-march=native",
            "-mtune=native",
            "-fomit-frame-pointer",
            "-flto",
            "-fPIC",
            "-c",
            "c_src/fast_glue.c",
            "-o",
            &obj_path,
        ])
        .status()
        .expect("failed to execute C compiler");
    assert!(status_c.success(), "C compilation failed");

    let status_asm = Command::new("as")
        .args(["-o", &asm_obj_path, "asm/fast_asm.s"])
        .status()
        .expect("failed to execute assembler");
    assert!(status_asm.success(), "Assembly compilation failed");

    let ar_status = Command::new("ar")
        .args(["crus", &lib_path, &obj_path, &asm_obj_path])
        .status()
        .expect("failed to execute ar");
    assert!(ar_status.success(), "Archiving failed");

    println!("cargo:rustc-link-search=native={}", out_dir);
    println!("cargo:rustc-link-lib=static=fast_glue");

    println!("cargo:rerun-if-changed=c_src/fast_glue.c");
    println!("cargo:rerun-if-changed=asm/fast_asm.s");
}
