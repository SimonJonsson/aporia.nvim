//! What Neovim and the backend say to each other over msgpack-RPC.
//!
//! Lua -> backend, notifications:
//!   `chat`   [ChatStart]   start a turn
//!   `cancel` [id]          stop it
//! Lua -> backend, requests:
//!   `ping`   []            -> "pong"
//! backend -> Lua, through `nvim_exec_lua`:
//!   `require('aporia.backend')._event(Event)`          UI updates
//!   `require('aporia.backend')._tool(id, name, args)`  -> tool output

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::Output;
use crate::openai::Message;

#[derive(Debug, Deserialize)]
pub struct ChatStart {
    /// Chosen by Lua; every event about this turn carries it.
    pub id: u64,
    pub provider: Provider,
    pub messages: Vec<Message>,
    /// Tool definitions in the OpenAI `tools` format, built by Lua, which
    /// also runs them. Empty means no tools.
    #[serde(default)]
    pub tools: Vec<Value>,
    #[serde(default = "default_max_rounds")]
    pub max_rounds: usize,
}

fn default_max_rounds() -> usize {
    12
}

#[derive(Debug, Deserialize)]
pub struct Provider {
    pub base_url: String,
    pub model: String,
    /// Resolved by Lua (env, command, literal); `None` for local servers.
    pub api_key: Option<String>,
}

/// An [`Output`] addressed to a turn. `flatten` puts the output's fields
/// next to `id`: `{ id = 1, type = "delta", text = ..., kind = ... }`.
#[derive(Debug, Serialize)]
pub struct Event<'a> {
    pub id: u64,
    #[serde(flatten)]
    pub output: &'a Output,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::DeltaKind;
    use serde_json::json;

    #[test]
    fn chat_start_from_lua() {
        let start: ChatStart = serde_json::from_value(json!({
            "id": 3,
            "provider": { "base_url": "http://x/v1", "model": "m" },
            "messages": [{ "role": "system", "content": "s" }, { "role": "user", "content": "u" }],
        }))
        .unwrap();
        assert_eq!(start.id, 3);
        assert!(start.provider.api_key.is_none());
        assert!(start.tools.is_empty());
        assert_eq!(start.max_rounds, 12);
    }

    #[test]
    fn event_is_flat() {
        let output = Output::Delta {
            text: "hi".into(),
            kind: DeltaKind::Content,
        };
        let event = Event {
            id: 1,
            output: &output,
        };
        assert_eq!(
            serde_json::to_value(&event).unwrap(),
            json!({ "id": 1, "type": "delta", "text": "hi", "kind": "content" })
        );
    }
}
