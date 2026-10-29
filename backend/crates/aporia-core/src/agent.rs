//! The agent loop as a sans-IO state machine.
//!
//! The agent never waits on anything. The shell feeds it an [`Input`]
//! (a streamed chunk, the end of a response, a tool result) and gets back
//! the [`Action`]s to perform: call the model, run a tool, or tell the UI
//! something. Because nothing here is async, the whole loop is tested with
//! plain functions; see the tests at the bottom.
//!
//! ```text
//!            start
//!              |
//!              v       Chunk (text, reasoning, tool call pieces)
//!         Streaming <-----------------------------------+
//!              |                                         |
//!          ModelEnd                                      |
//!        /          \                                    |
//!  no tool calls   tool calls -> RunningTools --(last ToolResult)
//!        |
//!        v
//!     Finished  <-- also from any state on ModelFailed
//! ```

use serde::Serialize;

use crate::openai::{Chunk, FunctionCall, Message, ToolCall};

/// What the shell tells the agent.
#[derive(Debug)]
pub enum Input {
    Chunk(Chunk),
    /// The model's response stream ended normally.
    ModelEnd,
    /// The request failed (network, HTTP status, an error in the stream).
    ModelFailed(String),
    ToolResult {
        call_id: String,
        output: String,
    },
}

/// What the agent asks the shell to do.
#[derive(Debug, PartialEq)]
pub enum Action {
    /// `tools: false` means "answer now": the last round withholds tools.
    CallModel {
        messages: Vec<Message>,
        tools: bool,
    },
    CallTool(ToolCall),
    Emit(Output),
}

/// What the UI hears about. Serialized with a `type` field, so Lua sees
/// `{ type = "delta", text = ..., kind = "content" }` and so on.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Output {
    Delta {
        text: String,
        kind: DeltaKind,
    },
    /// `content` is the whole reply: every round's text, joined.
    Done {
        content: String,
    },
    /// `content` is what arrived before the failure, kept for display.
    Error {
        message: String,
        content: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DeltaKind {
    Content,
    Reasoning,
}

/// Each state owns exactly the data that is meaningful in it: there is no
/// half-built round while tools run, and no pending tools while streaming.
#[derive(Debug)]
enum State {
    Streaming(Round),
    RunningTools { pending: Vec<String> },
    Finished,
}

/// One model response being streamed in.
#[derive(Debug, Default)]
struct Round {
    content: String,
    calls: Vec<PartialCall>,
    tools_offered: bool,
}

#[derive(Debug, Default)]
struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

#[derive(Debug)]
pub struct Agent {
    state: State,
    /// The conversation sent to the model, growing with each tool round.
    messages: Vec<Message>,
    /// The text shown to the user, across all rounds.
    reply: String,
    rounds: usize,
    max_rounds: usize,
}

impl Agent {
    /// Starts a conversation. `max_rounds` caps the model calls; the last
    /// one is made without tools so the model has to answer.
    pub fn start(messages: Vec<Message>, max_rounds: usize) -> (Agent, Vec<Action>) {
        let max_rounds = max_rounds.max(1);
        let tools = max_rounds > 1;
        let agent = Agent {
            state: State::Streaming(Round {
                tools_offered: tools,
                ..Round::default()
            }),
            messages,
            reply: String::new(),
            rounds: 1,
            max_rounds,
        };
        let action = Action::CallModel {
            messages: agent.messages.clone(),
            tools,
        };
        (agent, vec![action])
    }

    pub fn is_finished(&self) -> bool {
        matches!(self.state, State::Finished)
    }

    pub fn handle(&mut self, input: Input) -> Vec<Action> {
        // A failure ends the turn from any live state.
        if let Input::ModelFailed(message) = input {
            return self.fail(message);
        }
        // Matching on the pair (state, input) lists every legal transition;
        // anything else is an input arriving out of order, and is ignored.
        match (&mut self.state, input) {
            (State::Streaming(round), Input::Chunk(chunk)) => {
                if let Some(error) = chunk.error {
                    return self.fail(crate::openai::error_message(&error));
                }
                let mut actions = Vec::new();
                for choice in chunk.choices {
                    let delta = choice.delta;
                    if let Some(text) = delta.reasoning_content.or(delta.reasoning)
                        && !text.is_empty()
                    {
                        actions.push(Action::Emit(Output::Delta {
                            text,
                            kind: DeltaKind::Reasoning,
                        }));
                    }
                    if let Some(text) = delta.content
                        && !text.is_empty()
                    {
                        // a new round's text starts a new paragraph
                        if round.content.is_empty() && !self.reply.is_empty() {
                            self.reply.push_str("\n\n");
                            actions.push(Action::Emit(Output::Delta {
                                text: "\n\n".into(),
                                kind: DeltaKind::Content,
                            }));
                        }
                        round.content.push_str(&text);
                        self.reply.push_str(&text);
                        actions.push(Action::Emit(Output::Delta {
                            text,
                            kind: DeltaKind::Content,
                        }));
                    }
                    for piece in delta.tool_calls.unwrap_or_default() {
                        if round.calls.len() <= piece.index {
                            round
                                .calls
                                .resize_with(piece.index + 1, PartialCall::default);
                        }
                        let call = &mut round.calls[piece.index];
                        if let Some(id) = piece.id {
                            call.id = id;
                        }
                        if let Some(f) = piece.function {
                            call.name.push_str(&f.name.unwrap_or_default());
                            call.arguments.push_str(&f.arguments.unwrap_or_default());
                        }
                    }
                }
                actions
            }
            (State::Streaming(round), Input::ModelEnd) => {
                let round = std::mem::take(round);
                // tool calls on a round without tools are not acted on
                if round.calls.is_empty() || !round.tools_offered {
                    self.state = State::Finished;
                    return vec![Action::Emit(Output::Done {
                        content: self.reply.clone(),
                    })];
                }
                let calls: Vec<ToolCall> = round
                    .calls
                    .into_iter()
                    .enumerate()
                    .map(|(i, c)| ToolCall {
                        id: if c.id.is_empty() {
                            format!("call_{i}")
                        } else {
                            c.id
                        },
                        kind: "function".into(),
                        function: FunctionCall {
                            name: c.name,
                            arguments: c.arguments,
                        },
                    })
                    .collect();
                self.messages.push(Message::Assistant {
                    content: (!round.content.is_empty()).then_some(round.content),
                    tool_calls: calls.clone(),
                });
                self.state = State::RunningTools {
                    pending: calls.iter().map(|c| c.id.clone()).collect(),
                };
                calls.into_iter().map(Action::CallTool).collect()
            }
            (State::RunningTools { pending }, Input::ToolResult { call_id, output }) => {
                let Some(at) = pending.iter().position(|id| *id == call_id) else {
                    return Vec::new();
                };
                pending.remove(at);
                self.messages.push(Message::Tool {
                    tool_call_id: call_id,
                    content: output,
                });
                if !pending.is_empty() {
                    return Vec::new();
                }
                self.rounds += 1;
                let tools = self.rounds < self.max_rounds;
                self.state = State::Streaming(Round {
                    tools_offered: tools,
                    ..Round::default()
                });
                vec![Action::CallModel {
                    messages: self.messages.clone(),
                    tools,
                }]
            }
            _ => Vec::new(),
        }
    }

    fn fail(&mut self, message: String) -> Vec<Action> {
        if self.is_finished() {
            return Vec::new();
        }
        self.state = State::Finished;
        vec![Action::Emit(Output::Error {
            message,
            content: self.reply.clone(),
        })]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn chunk(delta: serde_json::Value) -> Input {
        Input::Chunk(serde_json::from_value(json!({ "choices": [{ "delta": delta }] })).unwrap())
    }

    fn user(text: &str) -> Vec<Message> {
        vec![Message::User {
            content: text.into(),
        }]
    }

    fn emitted(actions: &[Action]) -> Vec<&Output> {
        actions
            .iter()
            .filter_map(|a| match a {
                Action::Emit(o) => Some(o),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn plain_reply() {
        let (mut agent, first) = Agent::start(user("hi"), 4);
        assert!(matches!(first[..], [Action::CallModel { tools: true, .. }]));

        let a = agent.handle(chunk(json!({ "reasoning_content": "hmm" })));
        assert_eq!(
            emitted(&a),
            [&Output::Delta {
                text: "hmm".into(),
                kind: DeltaKind::Reasoning
            }]
        );
        agent.handle(chunk(json!({ "content": "Hel" })));
        agent.handle(chunk(json!({ "content": "lo" })));
        let end = agent.handle(Input::ModelEnd);
        assert_eq!(
            emitted(&end),
            [&Output::Done {
                content: "Hello".into()
            }]
        );
        assert!(agent.is_finished());
    }

    #[test]
    fn tool_round_then_answer() {
        let (mut agent, _) = Agent::start(user("what is this project?"), 4);
        agent.handle(chunk(json!({ "content": "Let me look." })));
        // the call arrives in pieces: id and name first, arguments split
        agent.handle(chunk(json!({ "tool_calls": [
            { "index": 0, "id": "c1", "function": { "name": "read_file", "arguments": "{\"path\": " } }
        ]})));
        agent.handle(chunk(json!({ "tool_calls": [
            { "index": 0, "function": { "arguments": "\"README.md\"}" } }
        ]})));
        let calls = agent.handle(Input::ModelEnd);
        let [Action::CallTool(call)] = &calls[..] else {
            panic!("expected one tool call, got {calls:?}");
        };
        assert_eq!(call.function.name, "read_file");
        assert_eq!(call.function.arguments, r#"{"path": "README.md"}"#);

        let next = agent.handle(Input::ToolResult {
            call_id: "c1".into(),
            output: "# aporia".into(),
        });
        let [
            Action::CallModel {
                messages,
                tools: true,
            },
        ] = &next[..]
        else {
            panic!("expected a second model call, got {next:?}");
        };
        // user, assistant with the call, the tool's result
        assert_eq!(messages.len(), 3);
        assert!(matches!(&messages[2], Message::Tool { content, .. } if content == "# aporia"));

        // the second round's text is a new paragraph of the same reply
        let a = agent.handle(chunk(json!({ "content": "It is a plugin." })));
        assert_eq!(
            emitted(&a)[0],
            &Output::Delta {
                text: "\n\n".into(),
                kind: DeltaKind::Content
            }
        );
        let end = agent.handle(Input::ModelEnd);
        assert_eq!(
            emitted(&end),
            [&Output::Done {
                content: "Let me look.\n\nIt is a plugin.".into()
            }]
        );
    }

    #[test]
    fn waits_for_every_parallel_call() {
        let (mut agent, _) = Agent::start(user("q"), 4);
        agent.handle(chunk(json!({ "tool_calls": [
            { "index": 0, "id": "a", "function": { "name": "grep", "arguments": "{}" } },
            { "index": 1, "id": "b", "function": { "name": "list_files", "arguments": "{}" } }
        ]})));
        assert_eq!(agent.handle(Input::ModelEnd).len(), 2);
        let first = agent.handle(Input::ToolResult {
            call_id: "b".into(),
            output: "".into(),
        });
        assert!(first.is_empty());
        let second = agent.handle(Input::ToolResult {
            call_id: "a".into(),
            output: "".into(),
        });
        assert!(matches!(second[..], [Action::CallModel { .. }]));
    }

    #[test]
    fn last_round_withholds_tools() {
        let (mut agent, _) = Agent::start(user("q"), 2);
        let call = json!({ "tool_calls": [
            { "index": 0, "id": "c", "function": { "name": "grep", "arguments": "{}" } }
        ]});
        agent.handle(chunk(call.clone()));
        agent.handle(Input::ModelEnd);
        let next = agent.handle(Input::ToolResult {
            call_id: "c".into(),
            output: "".into(),
        });
        assert!(matches!(next[..], [Action::CallModel { tools: false, .. }]));
        // the model calls a tool anyway: the turn ends instead of looping
        agent.handle(chunk(call));
        let end = agent.handle(Input::ModelEnd);
        assert!(matches!(emitted(&end)[..], [Output::Done { .. }]));
    }

    #[test]
    fn failure_keeps_what_arrived() {
        let (mut agent, _) = Agent::start(user("q"), 4);
        agent.handle(chunk(json!({ "content": "half" })));
        let a = agent.handle(Input::ModelFailed("connection reset".into()));
        assert_eq!(
            emitted(&a),
            [&Output::Error {
                message: "connection reset".into(),
                content: "half".into()
            }]
        );
        // nothing happens after the end
        assert!(agent.handle(Input::ModelEnd).is_empty());
    }

    #[test]
    fn error_inside_the_stream() {
        let (mut agent, _) = Agent::start(user("q"), 4);
        let input =
            Input::Chunk(serde_json::from_str(r#"{"error":{"message":"overloaded"}}"#).unwrap());
        let a = agent.handle(input);
        assert!(
            matches!(emitted(&a)[..], [Output::Error { message, .. }] if message == "overloaded")
        );
    }

    #[test]
    fn stray_inputs_are_ignored() {
        let (mut agent, _) = Agent::start(user("q"), 4);
        let a = agent.handle(Input::ToolResult {
            call_id: "nope".into(),
            output: "".into(),
        });
        assert!(a.is_empty());
        assert!(!agent.is_finished());
    }
}
