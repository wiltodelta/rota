fn main() {
    println!("cargo:rerun-if-changed=cshim/oslog.c");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" {
        cc::Build::new()
            .file("cshim/oslog.c")
            .flag("-fPIC")
            .compile("rota_oslog");
        println!("cargo:rustc-link-lib=dylib=sqlite3");
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
        println!("cargo:rustc-link-lib=framework=CoreGraphics");
        println!("cargo:rustc-link-lib=framework=CoreText");
        println!("cargo:rustc-link-lib=framework=Network");
    } else if target_os == "linux" {
        println!("cargo:rustc-link-lib=dylib=sqlite3");
    }
}
