//! aporia's core: the conversation model and, later, the agent loop.
//!
//! Nothing in this crate knows about Neovim or how bytes reach it. The
//! `aporia` binary crate owns the RPC transport and calls in here.

pub mod session;
