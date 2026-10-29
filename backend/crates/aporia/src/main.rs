//! The aporia backend. Neovim starts it with `jobstart(..., { rpc = true })`
//! and the two talk msgpack-RPC over this process's stdin and stdout, so
//! nothing else may ever be printed to stdout. Diagnostics go to stderr.
//!
//! This crate is the I/O shell: it owns the async runtime, the HTTP client
//! and the Neovim connection. Every decision is made in `aporia-core`.

mod handler;
mod turn;

use handler::Backend;

#[tokio::main]
async fn main() {
    let (_nvim, io) = match nvim_rs::create::tokio::new_parent(Backend::default()).await {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("aporia: cannot attach to neovim: {e}");
            std::process::exit(1);
        }
    };
    // `io` is the task reading messages from Neovim; it ends when Neovim
    // closes the channel (on exit or `jobstop`), and so does the process.
    match io.await {
        Ok(Ok(())) => {}
        Ok(Err(e)) if e.is_channel_closed() => {}
        Ok(Err(e)) => eprintln!("aporia: rpc loop failed: {e}"),
        Err(e) => eprintln!("aporia: rpc task panicked: {e}"),
    }
}
