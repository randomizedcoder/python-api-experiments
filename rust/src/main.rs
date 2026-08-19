//! `rust-df` binary entry point: set the global allocator and run the workers.

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() {
    rust_df::run(rust_df::Config::from_env());
}
