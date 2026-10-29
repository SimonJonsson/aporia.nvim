//! aporia's core: everything that can be decided without touching the
//! network, the file system or Neovim. The `aporia` binary does the I/O.

pub mod agent;
pub mod openai;
pub mod protocol;
pub mod session;
pub mod sse;
