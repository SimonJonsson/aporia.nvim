//! Server-sent events: the framing an OpenAI-compatible endpoint streams in.
//!
//! The network hands over bytes in arbitrary pieces, so a line (or even a
//! multi-byte UTF-8 character) can be split across two reads. The parser
//! buffers bytes, not `String`s, and only decodes a line once it is whole.

#[derive(Debug, PartialEq, Eq)]
pub enum SseEvent {
    /// The payload of a `data:` line, usually one JSON chunk.
    Data(String),
    /// `data: [DONE]`, the end of the stream.
    Done,
}

#[derive(Debug, Default)]
pub struct SseParser {
    buf: Vec<u8>,
}

impl SseParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes the next piece of the body and returns every event it completes.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<SseEvent> {
        self.buf.extend_from_slice(bytes);
        let mut events = Vec::new();
        while let Some(nl) = self.buf.iter().position(|&b| b == b'\n') {
            // `drain` removes the line from the buffer and hands it to us
            let line: Vec<u8> = self.buf.drain(..=nl).collect();
            events.extend(parse_line(&String::from_utf8_lossy(&line)));
        }
        events
    }

    /// The stream ended: whatever is left is a final line without a newline.
    pub fn finish(&mut self) -> Vec<SseEvent> {
        let rest = std::mem::take(&mut self.buf);
        parse_line(&String::from_utf8_lossy(&rest))
            .into_iter()
            .collect()
    }
}

/// Comments (`: keep-alive`), other fields (`event:`, `id:`) and blank
/// separator lines carry nothing we use, so they become `None`.
fn parse_line(line: &str) -> Option<SseEvent> {
    let line = line.trim_end_matches(['\n', '\r']);
    let data = line.strip_prefix("data:")?;
    let data = data.strip_prefix(' ').unwrap_or(data);
    if data == "[DONE]" {
        Some(SseEvent::Done)
    } else {
        Some(SseEvent::Data(data.to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_events() {
        let mut p = SseParser::new();
        let events = p.feed(b"data: {\"a\":1}\n\ndata: [DONE]\n\n");
        assert_eq!(
            events,
            vec![SseEvent::Data("{\"a\":1}".into()), SseEvent::Done]
        );
    }

    #[test]
    fn lines_split_across_reads_and_crlf() {
        let body = "data: one\r\n\r\ndata: two\r\n\r\n".as_bytes();
        let mut p = SseParser::new();
        let mut events = Vec::new();
        for piece in body.chunks(3) {
            events.extend(p.feed(piece));
        }
        assert_eq!(
            events,
            vec![SseEvent::Data("one".into()), SseEvent::Data("two".into())]
        );
    }

    #[test]
    fn a_character_split_across_reads() {
        let body = "data: café\n".as_bytes();
        // split inside the two bytes of "é"
        let cut = body.len() - 2;
        let mut p = SseParser::new();
        assert!(p.feed(&body[..cut]).is_empty());
        assert_eq!(p.feed(&body[cut..]), vec![SseEvent::Data("café".into())]);
    }

    #[test]
    fn ignores_comments_and_other_fields() {
        let mut p = SseParser::new();
        let events = p.feed(b": keep-alive\nevent: message\nid: 3\ndata:x\n");
        assert_eq!(events, vec![SseEvent::Data("x".into())]);
    }

    #[test]
    fn last_line_without_newline() {
        let mut p = SseParser::new();
        assert!(p.feed(b"data: [DONE]").is_empty());
        assert_eq!(p.finish(), vec![SseEvent::Done]);
    }
}
