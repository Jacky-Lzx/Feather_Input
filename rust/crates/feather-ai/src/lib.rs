use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fmt;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::thread;
use std::time::Duration;

const DEFAULT_MLX_PORT: u16 = 1235;
const MAX_REQUEST_BYTES: usize = 4096;
const MAX_RESPONSE_BYTES: u64 = 64 * 1024;
const BUSY_RETRY_DELAYS_MS: [u64; 6] = [40, 60, 100, 160, 240, 300];

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum InputScheme {
    #[serde(rename = "luna_pinyin_simp")]
    FullPinyin,
    #[serde(rename = "double_pinyin_flypy")]
    Flypy,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GenerationRequest {
    pub request_id: u64,
    pub revision: u64,
    pub context: String,
    pub input: String,
    pub scheme: InputScheme,
    pub count: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeneratedCandidate {
    pub text: String,
    pub score: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GenerationBatch {
    pub request_id: u64,
    pub revision: u64,
    pub candidates: Vec<GeneratedCandidate>,
    pub elapsed_ms: u64,
    pub truncated: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AiError {
    InvalidRequest,
    Unavailable,
    Busy,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
}

impl fmt::Display for AiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest => formatter.write_str("invalid AI request"),
            Self::Unavailable => formatter.write_str("AI provider unavailable"),
            Self::Busy => formatter.write_str("AI provider busy"),
            Self::HttpStatus(status) => write!(formatter, "AI provider returned HTTP {status}"),
            Self::ResponseTooLarge => formatter.write_str("AI provider response too large"),
            Self::InvalidResponse => formatter.write_str("invalid AI provider response"),
        }
    }
}

impl std::error::Error for AiError {}

/// 提供者调用是阻塞操作，调用方必须把它放到按键主链路之外执行。
pub trait AiProvider: Send + Sync {
    /// # Errors
    ///
    /// 请求无效、提供者不可用、服务繁忙或响应未通过校验时返回错误。
    fn generate(&self, request: &GenerationRequest) -> Result<GenerationBatch, AiError>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransportResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

pub trait MlxTransport: Send + Sync {
    /// # Errors
    ///
    /// 请求不符合本地传输限制、连接失败或响应无效时返回错误。
    fn post_json(&self, path: &str, body: &[u8]) -> Result<TransportResponse, AiError>;
}

#[derive(Clone, Debug)]
pub struct LoopbackHttpTransport {
    port: u16,
    connect_timeout: Duration,
    io_timeout: Duration,
}

impl Default for LoopbackHttpTransport {
    fn default() -> Self {
        Self {
            port: DEFAULT_MLX_PORT,
            connect_timeout: Duration::from_millis(300),
            io_timeout: Duration::from_secs(3),
        }
    }
}

impl LoopbackHttpTransport {
    #[must_use]
    pub fn with_port(port: u16) -> Self {
        Self {
            port,
            ..Self::default()
        }
    }

    fn parse_response(bytes: &[u8]) -> Result<TransportResponse, AiError> {
        let header_end = bytes
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .ok_or(AiError::InvalidResponse)?;
        let header =
            std::str::from_utf8(&bytes[..header_end]).map_err(|_| AiError::InvalidResponse)?;
        let status = header
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|value| value.parse::<u16>().ok())
            .ok_or(AiError::InvalidResponse)?;
        let body = bytes[(header_end + 4)..].to_vec();
        Ok(TransportResponse { status, body })
    }
}

impl MlxTransport for LoopbackHttpTransport {
    fn post_json(&self, path: &str, body: &[u8]) -> Result<TransportResponse, AiError> {
        if !path.starts_with('/') || body.is_empty() || body.len() > MAX_REQUEST_BYTES {
            return Err(AiError::InvalidRequest);
        }
        let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, self.port).into();
        let mut stream = TcpStream::connect_timeout(&address, self.connect_timeout)
            .map_err(|_| AiError::Unavailable)?;
        stream
            .set_read_timeout(Some(self.io_timeout))
            .map_err(|_| AiError::Unavailable)?;
        stream
            .set_write_timeout(Some(self.io_timeout))
            .map_err(|_| AiError::Unavailable)?;
        write!(
            stream,
            "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            self.port,
            body.len()
        )
        .and_then(|()| stream.write_all(body))
        .map_err(|_| AiError::Unavailable)?;
        stream.flush().map_err(|_| AiError::Unavailable)?;

        let mut bytes = Vec::new();
        stream
            .take(MAX_RESPONSE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| AiError::Unavailable)?;
        if bytes.len() as u64 > MAX_RESPONSE_BYTES {
            return Err(AiError::ResponseTooLarge);
        }
        Self::parse_response(&bytes)
    }
}

#[derive(Debug)]
pub struct MlxProvider<T = LoopbackHttpTransport> {
    transport: T,
    busy_retry_limit: usize,
}

impl Default for MlxProvider<LoopbackHttpTransport> {
    fn default() -> Self {
        Self {
            transport: LoopbackHttpTransport::default(),
            busy_retry_limit: BUSY_RETRY_DELAYS_MS.len(),
        }
    }
}

impl<T> MlxProvider<T> {
    #[must_use]
    pub fn new(transport: T) -> Self {
        Self {
            transport,
            busy_retry_limit: BUSY_RETRY_DELAYS_MS.len(),
        }
    }

    #[must_use]
    pub fn with_busy_retry_limit(mut self, limit: usize) -> Self {
        self.busy_retry_limit = limit.min(BUSY_RETRY_DELAYS_MS.len());
        self
    }
}

#[derive(Serialize)]
struct MlxGenerationRequest<'a> {
    context: String,
    input: &'a str,
    scheme: InputScheme,
    count: u8,
}

#[derive(Deserialize)]
struct MlxGenerationResponse {
    candidates: Vec<MlxGeneratedCandidate>,
    syllables: Vec<Vec<String>>,
    elapsed_ms: u64,
    truncated: bool,
}

#[derive(Deserialize)]
struct MlxGeneratedCandidate {
    text: String,
    score: f64,
}

#[derive(Deserialize)]
struct MlxErrorResponse {
    error: String,
}

impl<T: MlxTransport> AiProvider for MlxProvider<T> {
    fn generate(&self, request: &GenerationRequest) -> Result<GenerationBatch, AiError> {
        validate_request(request)?;
        let payload = MlxGenerationRequest {
            context: suffix_chars(&request.context, 80),
            input: &request.input,
            scheme: request.scheme,
            count: request.count,
        };
        let body = serde_json::to_vec(&payload).map_err(|_| AiError::InvalidRequest)?;

        let mut busy_retries = 0;
        let response = loop {
            let response = self.transport.post_json("/generate", &body)?;
            if response.status != 503 || !is_busy_response(&response.body) {
                break response;
            }
            if busy_retries >= self.busy_retry_limit {
                return Err(AiError::Busy);
            }
            thread::sleep(Duration::from_millis(BUSY_RETRY_DELAYS_MS[busy_retries]));
            busy_retries += 1;
        };

        if !(200..300).contains(&response.status) {
            return Err(AiError::HttpStatus(response.status));
        }
        let parsed: MlxGenerationResponse =
            serde_json::from_slice(&response.body).map_err(|_| AiError::InvalidResponse)?;
        validate_response(&parsed, usize::from(request.count))?;
        Ok(GenerationBatch {
            request_id: request.request_id,
            revision: request.revision,
            candidates: parsed
                .candidates
                .into_iter()
                .map(|candidate| GeneratedCandidate {
                    text: candidate.text,
                    score: candidate.score,
                })
                .collect(),
            elapsed_ms: parsed.elapsed_ms,
            truncated: parsed.truncated,
        })
    }
}

fn validate_request(request: &GenerationRequest) -> Result<(), AiError> {
    let input_length = request.input.chars().count();
    if request.context.trim().is_empty()
        || request.input.is_empty()
        || input_length > 36
        || !(1..=3).contains(&request.count)
        || !request
            .input
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte == b'\'' || byte == b' ')
    {
        return Err(AiError::InvalidRequest);
    }
    Ok(())
}

fn validate_response(response: &MlxGenerationResponse, count: usize) -> Result<(), AiError> {
    if response.candidates.len() > count
        || response.candidates.len() > 3
        || response.syllables.len() > 4
        || response.elapsed_ms > 10_000
        || !response.syllables.iter().all(|path| {
            (2..=6).contains(&path.len())
                && path.iter().all(|syllable| {
                    !syllable.is_empty() && syllable.bytes().all(|byte| byte.is_ascii_lowercase())
                })
        })
    {
        return Err(AiError::InvalidResponse);
    }
    let mut texts = HashSet::new();
    for candidate in &response.candidates {
        let length = candidate.text.chars().count();
        if !candidate.score.is_finite()
            || candidate.score > 0.0
            || !(2..=6).contains(&length)
            || !candidate.text.chars().all(is_han)
            || !texts.insert(candidate.text.as_str())
            || !response.syllables.iter().any(|path| path.len() == length)
        {
            return Err(AiError::InvalidResponse);
        }
    }
    Ok(())
}

fn suffix_chars(value: &str, maximum: usize) -> String {
    let start = value
        .char_indices()
        .rev()
        .nth(maximum.saturating_sub(1))
        .map_or(0, |(index, _)| index);
    value[start..].to_owned()
}

fn is_han(character: char) -> bool {
    matches!(u32::from(character), 0x3400..=0x9fff | 0x20000..=0x323af)
}

fn is_busy_response(body: &[u8]) -> bool {
    serde_json::from_slice::<MlxErrorResponse>(body).is_ok_and(|response| response.error == "busy")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;
    use std::sync::Mutex;

    #[derive(Debug)]
    struct FakeTransport {
        responses: Mutex<VecDeque<TransportResponse>>,
    }

    impl FakeTransport {
        fn new(responses: impl IntoIterator<Item = TransportResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
            }
        }
    }

    impl MlxTransport for FakeTransport {
        fn post_json(&self, path: &str, body: &[u8]) -> Result<TransportResponse, AiError> {
            assert_eq!(path, "/generate");
            let payload: serde_json::Value = serde_json::from_slice(body).unwrap();
            assert_eq!(payload["scheme"], "luna_pinyin_simp");
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or(AiError::Unavailable)
        }
    }

    fn request() -> GenerationRequest {
        GenerationRequest {
            request_id: 9,
            revision: 42,
            context: "落霞与".into(),
            input: "guwu".into(),
            scheme: InputScheme::FullPinyin,
            count: 3,
        }
    }

    fn response(status: u16, body: &str) -> TransportResponse {
        TransportResponse {
            status,
            body: body.as_bytes().to_vec(),
        }
    }

    #[test]
    fn valid_generation_preserves_request_identity() {
        let provider = MlxProvider::new(FakeTransport::new([response(
            200,
            r#"{"candidates":[{"text":"孤鹜","score":-0.47,"token_ids":[1,2]}],"syllables":[["gu","wu"]],"elapsed_ms":359,"truncated":false}"#,
        )]));
        let result = provider.generate(&request()).unwrap();
        assert_eq!(result.request_id, 9);
        assert_eq!(result.revision, 42);
        assert_eq!(result.candidates[0].text, "孤鹜");
        assert_eq!(result.elapsed_ms, 359);
        assert!(!result.truncated);
    }

    #[test]
    fn rejects_invalid_generated_candidates() {
        for body in [
            r#"{"candidates":[{"text":"孤鹜","score":1}],"syllables":[["gu","wu"]],"elapsed_ms":1,"truncated":false}"#,
            r#"{"candidates":[{"text":"world","score":-1}],"syllables":[["gu","wu"]],"elapsed_ms":1,"truncated":false}"#,
            r#"{"candidates":[{"text":"孤鹜","score":-1},{"text":"孤鹜","score":-2}],"syllables":[["gu","wu"]],"elapsed_ms":1,"truncated":false}"#,
        ] {
            let provider = MlxProvider::new(FakeTransport::new([response(200, body)]));
            assert_eq!(provider.generate(&request()), Err(AiError::InvalidResponse));
        }
    }

    #[test]
    fn rejects_invalid_request_before_transport() {
        let provider = MlxProvider::new(FakeTransport::new([]));
        let mut invalid = request();
        invalid.context.clear();
        assert_eq!(provider.generate(&invalid), Err(AiError::InvalidRequest));
        invalid = request();
        invalid.input = "GUWU".into();
        assert_eq!(provider.generate(&invalid), Err(AiError::InvalidRequest));
    }

    #[test]
    fn retries_bounded_busy_response() {
        let provider = MlxProvider::new(FakeTransport::new([
            response(503, r#"{"error":"busy"}"#),
            response(
                200,
                r#"{"candidates":[],"syllables":[["gu","wu"]],"elapsed_ms":4,"truncated":true}"#,
            ),
        ]))
        .with_busy_retry_limit(1);
        assert!(provider.generate(&request()).unwrap().truncated);
    }

    #[test]
    fn stops_after_busy_retry_limit_and_does_not_retry_other_errors() {
        let busy = MlxProvider::new(FakeTransport::new([response(503, r#"{"error":"busy"}"#)]))
            .with_busy_retry_limit(0);
        assert_eq!(busy.generate(&request()), Err(AiError::Busy));

        let other = MlxProvider::new(FakeTransport::new([response(
            503,
            r#"{"error":"inference failed"}"#,
        )]));
        assert_eq!(other.generate(&request()), Err(AiError::HttpStatus(503)));
    }

    #[test]
    fn context_suffix_uses_unicode_characters() {
        let context = format!("前缀{}", "界".repeat(80));
        assert_eq!(suffix_chars(&context, 80), "界".repeat(80));
    }

    #[test]
    fn loopback_transport_sends_expected_http_request() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut request_line = String::new();
            reader.read_line(&mut request_line).unwrap();
            assert_eq!(request_line, "POST /generate HTTP/1.1\r\n");
            let mut content_length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                assert!(!line.to_ascii_lowercase().starts_with("origin:"));
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    content_length = value.trim().parse::<usize>().unwrap();
                }
            }
            let mut body = vec![0; content_length];
            reader.read_exact(&mut body).unwrap();
            let payload: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(payload["input"], "guwu");
            let response_body = r#"{"candidates":[{"text":"孤鹜","score":-0.47}],"syllables":[["gu","wu"]],"elapsed_ms":5,"truncated":false}"#;
            write!(
                reader.get_mut(),
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            )
            .unwrap();
        });
        let provider = MlxProvider::new(LoopbackHttpTransport::with_port(port));
        assert_eq!(
            provider.generate(&request()).unwrap().candidates[0].text,
            "孤鹜"
        );
        server.join().unwrap();
    }
}
