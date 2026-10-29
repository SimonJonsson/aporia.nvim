//! The OpenAI-compatible chat completions format, as far as aporia uses it.
//!
//! Types mirror the wire format one to one; serde attributes do the
//! renaming. `Message` is an enum tagged by `role`, so a tool result without
//! a `tool_call_id`, or a user message with tool calls, cannot be built.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "role", rename_all = "lowercase")]
pub enum Message {
    System {
        content: String,
    },
    User {
        content: String,
    },
    Assistant {
        /// `None` when the model only called tools.
        #[serde(default)]
        content: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        tool_calls: Vec<ToolCall>,
    },
    Tool {
        tool_call_id: String,
        content: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    /// Always `"function"`. `type` is a keyword in Rust, hence the rename.
    #[serde(rename = "type")]
    pub kind: String,
    pub function: FunctionCall,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FunctionCall {
    pub name: String,
    /// JSON, as a string: the model writes it, nobody has parsed it yet.
    pub arguments: String,
}

/// The request body. It borrows everything, so building one copies nothing.
#[derive(Debug, Serialize)]
pub struct ChatRequest<'a> {
    pub model: &'a str,
    pub messages: &'a [Message],
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub tools: &'a [Value],
    pub stream: bool,
}

/// One `data:` payload of a streamed reply.
#[derive(Debug, Default, Deserialize)]
pub struct Chunk {
    #[serde(default)]
    pub choices: Vec<ChunkChoice>,
    /// Some providers report a failure mid-stream instead of in the status.
    #[serde(default)]
    pub error: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
pub struct ChunkChoice {
    #[serde(default)]
    pub delta: Delta,
}

/// Every field is optional: each chunk carries only what is new. `null` and
/// a missing field both become `None`.
#[derive(Debug, Default, Deserialize)]
pub struct Delta {
    pub content: Option<String>,
    /// Thinking models stream their reasoning here before the answer;
    /// the field name depends on the server.
    pub reasoning_content: Option<String>,
    pub reasoning: Option<String>,
    pub tool_calls: Option<Vec<ToolCallDelta>>,
}

/// A piece of a tool call. The first piece for an `index` has the id and
/// name; the arguments then arrive in fragments to be concatenated.
#[derive(Debug, Default, Deserialize)]
pub struct ToolCallDelta {
    pub index: usize,
    pub id: Option<String>,
    pub function: Option<FunctionDelta>,
}

#[derive(Debug, Default, Deserialize)]
pub struct FunctionDelta {
    pub name: Option<String>,
    pub arguments: Option<String>,
}

/// The human-readable part of an `error` value: `{ "message": ... }` from
/// OpenAI-style servers, or a bare string from others.
pub fn error_message(error: &Value) -> String {
    match error {
        Value::String(s) => s.clone(),
        Value::Object(o) => match o.get("message").and_then(Value::as_str) {
            Some(m) => m.to_owned(),
            None => error.to_string(),
        },
        other => other.to_string(),
    }
}

/// The message in a failed response's body, or the start of the body.
pub fn error_from_body(body: &str) -> String {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("error").map(error_message))
        .unwrap_or_else(|| body.chars().take(200).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn messages_are_tagged_by_role() {
        let m: Message = serde_json::from_value(json!({"role": "user", "content": "hi"})).unwrap();
        assert_eq!(
            m,
            Message::User {
                content: "hi".into()
            }
        );

        let tool = Message::Tool {
            tool_call_id: "c1".into(),
            content: "ok".into(),
        };
        assert_eq!(
            serde_json::to_value(&tool).unwrap(),
            json!({"role": "tool", "tool_call_id": "c1", "content": "ok"})
        );
    }

    #[test]
    fn assistant_tool_calls_round_trip() {
        let wire = json!({
            "role": "assistant",
            "content": null,
            "tool_calls": [{"id": "c1", "type": "function",
                            "function": {"name": "read_file", "arguments": "{}"}}]
        });
        let m: Message = serde_json::from_value(wire.clone()).unwrap();
        assert_eq!(serde_json::to_value(&m).unwrap(), wire);
    }

    #[test]
    fn chunk_with_nulls_and_missing_fields() {
        let c: Chunk = serde_json::from_str(
            r#"{"choices":[{"delta":{"content":null,"tool_calls":null},"finish_reason":"stop"}]}"#,
        )
        .unwrap();
        assert!(c.choices[0].delta.content.is_none());
        let empty: Chunk = serde_json::from_str("{}").unwrap();
        assert!(empty.choices.is_empty());
    }

    #[test]
    fn errors_in_both_shapes() {
        assert_eq!(
            error_from_body(r#"{"error":{"message":"bad key"}}"#),
            "bad key"
        );
        assert_eq!(
            error_from_body(r#"{"error":"Authentication required."}"#),
            "Authentication required."
        );
        assert_eq!(error_from_body("Bad Gateway"), "Bad Gateway");
    }
}
