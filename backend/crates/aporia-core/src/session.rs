//! Milestone 1: the session model.
//!
//! Model a saved conversation so that every file in `tests/fixtures/`
//! deserializes and serializes back to the same JSON value.
//!
//! The format is what the Lua side writes today (see `lua/aporia/store.lua`
//! and `lua/aporia/chat.lua`), so it is the contract, warts included:
//!
//! - a document has `version`, `mode`, `id` and `messages`
//! - a message is either a user turn or an assistant turn, told apart by
//!   `role`; they carry different fields
//! - a user turn's `parts` mix two shapes: `{ text }` and
//!   `{ sep, short, block, expanded? }`
//! - fold state (`expanded_full`, `expanded_system`, a part's `expanded`)
//!   is optional and absent when false
//! - an assistant turn may be a failed reply, marked `error: true`
//!
//! Prefer types that make invalid conversations unrepresentable over
//! types that mirror the JSON loosely.
