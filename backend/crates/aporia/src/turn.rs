//! One chat turn: performs the agent's actions until it has finished.
//!
//! The agent decides, this module does: it streams from the provider,
//! asks Neovim to run tools, and forwards outputs to the UI, feeding every
//! result back in as an `Input`.

use std::collections::VecDeque;

use futures_util::StreamExt;
use nvim_rs::Value;
use serde_json::Value as Json;

use aporia_core::agent::{Action, Agent, Input, Output};
use aporia_core::openai::{ChatRequest, Chunk, Message, ToolCall, error_from_body};
use aporia_core::protocol::{ChatStart, Event, Provider};
use aporia_core::sse::{SseEvent, SseParser};

use crate::handler::Nvim;

struct Turn {
    id: u64,
    nvim: Nvim,
    http: reqwest::Client,
    provider: Provider,
    tools: Vec<Json>,
    agent: Agent,
}

pub async fn run(nvim: Nvim, start: ChatStart) {
    let (agent, first) = Agent::start(start.messages, start.max_rounds);
    let mut turn = Turn {
        id: start.id,
        nvim,
        http: reqwest::Client::new(),
        provider: start.provider,
        tools: start.tools,
        agent,
    };
    // Work queue: emits are sent as they appear (see `feed`); model and
    // tool calls wait their turn here.
    let mut queue: VecDeque<Action> = VecDeque::new();
    queue.extend(turn.dispatch(first).await);
    while let Some(action) = queue.pop_front() {
        let next = match action {
            Action::CallModel { messages, tools } => turn.call_model(&messages, tools).await,
            Action::CallTool(call) => turn.call_tool(call).await,
            // `dispatch` already sent every emit
            Action::Emit(_) => unreachable!(),
        };
        queue.extend(next);
    }
}

impl Turn {
    /// Hands an input to the agent and sends its outputs to the UI right
    /// away, so streamed text shows up while the stream is still running.
    async fn feed(&mut self, input: Input) -> Vec<Action> {
        let actions = self.agent.handle(input);
        self.dispatch(actions).await
    }

    /// Sends the emits and returns the actions that are real work.
    async fn dispatch(&self, actions: Vec<Action>) -> Vec<Action> {
        let mut work = Vec::new();
        for action in actions {
            match action {
                Action::Emit(output) => self.emit(&output).await,
                other => work.push(other),
            }
        }
        work
    }

    async fn emit(&self, output: &Output) {
        let event = Event {
            id: self.id,
            output,
        };
        let Ok(arg) = rmpv::ext::to_value(&event) else {
            return;
        };
        // Neovim gone or Lua failing: nothing useful left to tell anyone
        let _ = self
            .nvim
            .exec_lua("require('aporia.backend')._event(...)", vec![arg])
            .await;
    }

    async fn call_model(&mut self, messages: &[Message], tools: bool) -> Vec<Action> {
        let body = ChatRequest {
            model: &self.provider.model,
            messages,
            tools: if tools { &self.tools } else { &[] },
            stream: true,
        };
        let body = match serde_json::to_vec(&body) {
            Ok(b) => b,
            Err(e) => return self.feed(Input::ModelFailed(e.to_string())).await,
        };
        let url = format!(
            "{}/chat/completions",
            self.provider.base_url.trim_end_matches('/')
        );
        let mut request = self
            .http
            .post(url)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .body(body);
        if let Some(key) = &self.provider.api_key {
            request = request.bearer_auth(key);
        }

        let response = match request.send().await {
            Ok(r) => r,
            Err(e) => return self.feed(Input::ModelFailed(e.to_string())).await,
        };
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            let message = format!("{status}: {}", error_from_body(&text));
            return self.feed(Input::ModelFailed(message)).await;
        }

        let mut work = Vec::new();
        let mut sse = SseParser::new();
        let mut stream = response.bytes_stream();
        while let Some(piece) = stream.next().await {
            let bytes = match piece {
                Ok(b) => b,
                Err(e) => {
                    work.extend(self.feed(Input::ModelFailed(e.to_string())).await);
                    return work;
                }
            };
            for event in sse.feed(&bytes) {
                work.extend(self.on_sse(event).await);
            }
        }
        for event in sse.finish() {
            work.extend(self.on_sse(event).await);
        }
        work.extend(self.feed(Input::ModelEnd).await);
        work
    }

    async fn on_sse(&mut self, event: SseEvent) -> Vec<Action> {
        match event {
            // a chunk we cannot parse carries nothing we understand
            SseEvent::Data(data) => match serde_json::from_str::<Chunk>(&data) {
                Ok(chunk) => self.feed(Input::Chunk(chunk)).await,
                Err(_) => Vec::new(),
            },
            // the end is when the body ends; [DONE] adds nothing
            SseEvent::Done => Vec::new(),
        }
    }

    /// Tools run in Neovim (`lua/aporia/tools.lua`): it has the buffers,
    /// the project root and the UI that shows each step.
    async fn call_tool(&mut self, call: ToolCall) -> Vec<Action> {
        let args = vec![
            Value::from(self.id),
            Value::from(call.function.name.as_str()),
            Value::from(call.function.arguments.as_str()),
        ];
        let output = match self
            .nvim
            .exec_lua("return require('aporia.backend')._tool(...)", args)
            .await
        {
            Ok(Value::String(s)) => s.into_str().unwrap_or_default(),
            Ok(other) => other.to_string(),
            Err(e) => format!("error: the tool could not run: {e}"),
        };
        self.feed(Input::ToolResult {
            call_id: call.id,
            output,
        })
        .await
    }
}
