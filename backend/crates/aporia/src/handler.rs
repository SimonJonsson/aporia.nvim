//! Incoming RPC from Neovim: the methods listed in `aporia_core::protocol`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use nvim_rs::compat::tokio::Compat;
use nvim_rs::{Handler, Neovim, Value};
use tokio::task::JoinHandle;

use aporia_core::protocol::ChatStart;

pub type Nvim = Neovim<Compat<tokio::fs::File>>;

/// nvim-rs clones the handler for every message, so shared state lives
/// behind an `Arc`. A std `Mutex` is enough: it is never held across an
/// `.await`.
#[derive(Clone, Default)]
pub struct Backend {
    turns: Arc<Mutex<HashMap<u64, JoinHandle<()>>>>,
}

#[async_trait]
impl Handler for Backend {
    type Writer = Compat<tokio::fs::File>;

    async fn handle_request(
        &self,
        name: String,
        _args: Vec<Value>,
        _nvim: Nvim,
    ) -> Result<Value, Value> {
        match name.as_str() {
            "ping" => Ok(Value::from("pong")),
            other => Err(Value::from(format!("unknown method: {other}"))),
        }
    }

    // Notifications are handled one at a time, and nvim-rs reads nothing
    // else until this returns. A turn takes seconds, so it runs in its own
    // task; otherwise `cancel` (and the replies to our own tool calls)
    // would wait behind it.
    async fn handle_notify(&self, name: String, args: Vec<Value>, nvim: Nvim) {
        match name.as_str() {
            "chat" => {
                let Some(arg) = args.into_iter().next() else {
                    return eprintln!("aporia: chat without an argument");
                };
                let start: ChatStart = match rmpv::ext::from_value(arg) {
                    Ok(start) => start,
                    Err(e) => return eprintln!("aporia: malformed chat request: {e}"),
                };
                let id = start.id;
                let task = tokio::spawn(crate::turn::run(nvim, start));
                let mut turns = self.turns.lock().unwrap();
                turns.retain(|_, t| !t.is_finished());
                turns.insert(id, task);
            }
            "cancel" => {
                let Some(id) = args.first().and_then(Value::as_u64) else {
                    return;
                };
                if let Some(task) = self.turns.lock().unwrap().remove(&id) {
                    // dropping the task's future closes its HTTP stream too
                    task.abort();
                }
            }
            other => eprintln!("aporia: unknown notification: {other}"),
        }
    }
}
