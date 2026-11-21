//! The phone's whole path against a real runner-server: sign in as a phone, list
//! computers, pair by PIN, use the companion protocol, reconnect with the saved keys.
//! The computer is played with runner-core's host side, which is what `runnerd` runs.

use base64::{Engine, engine::general_purpose::STANDARD};
use futures_util::{SinkExt, StreamExt};
use runner_core::{
    companion::channel::{self, HostPair, Kind, NoiseKeys, Records, Reject},
    remote::{HostKey, encode_key, fingerprint},
};
use runner_mobile_core::Core;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{Message, client::IntoClientRequest, http::HeaderValue},
};

const PIN: &str = "482917";
const WAIT: Duration = Duration::from_secs(15);

struct Server {
    origin: String,
    db: runner_server::db::Db,
    user: i64,
    _dir: tempfile::TempDir,
}

async fn server() -> Server {
    let dir = tempfile::tempdir().unwrap();
    let db = runner_server::db::Db::open(&dir.path().join("test.db")).unwrap();
    let user = runner_server::db::insert_user(&db.lock(), "alice", "Alice", "unused", true, 0)
        .unwrap()
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let state = runner_server::AppState::new(
        runner_server::config::Config::new(&origin).unwrap(),
        db.clone(),
    );
    let router = runner_server::app(state);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Server {
        origin,
        db,
        user,
        _dir: dir,
    }
}

impl Server {
    /// What the person does in the browser: approve the code.
    fn approve(&self, user_code: &str) {
        assert!(
            runner_server::db::decide_enrollment(
                &self.db.lock(),
                user_code,
                true,
                self.user,
                now()
            )
            .unwrap()
        );
    }

    /// Enrolls a computer the way Runner does and connects it to the relay.
    async fn computer(&self, key: &HostKey) -> (String, Host) {
        let http = reqwest::Client::new();
        let rpc = format!("{}/api/runner_server.v1.HostEnrollmentService", self.origin);
        let start: Value = http
            .post(format!("{rpc}/StartEnrollment"))
            .json(&json!({"host": {"hostname": "studio"}, "hostKey": encode_key(&key.public)}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        self.approve(start["userCode"].as_str().unwrap());
        let issued: Value = http
            .post(format!("{rpc}/PollEnrollment"))
            .json(&json!({"deviceCode": start["deviceCode"]}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let mut request = format!("{}/relay/host", self.origin.replacen("http", "ws", 1))
            .into_client_request()
            .unwrap();
        let credential = issued["credential"].as_str().unwrap();
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {credential}")).unwrap(),
        );
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            HeaderValue::from_static("runner-relay.v1"),
        );
        let (mut socket, _) = connect_async(request).await.unwrap();
        socket
            .send(Message::Text(
                json!({"type": "hello", "host": {"hostname": "studio"}})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let welcome = socket.next().await.unwrap().unwrap();
        assert!(welcome.to_text().unwrap().contains("welcome"));
        (issued["hostId"].as_str().unwrap().to_owned(), socket)
    }
}

type Host =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[allow(clippy::large_enum_variant)] // A test fake with a handful of channels.
enum State {
    Pairing(HostPair),
    Open(Records),
}

/// A minimal `runnerd`: pairs by PIN, accepts paired clients, answers companion
/// requests, and echoes input as terminal output.
async fn run_host(mut socket: Host, key: HostKey) {
    let mut channels: HashMap<u32, State> = HashMap::new();
    let mut paired: Vec<Vec<u8>> = Vec::new();
    let keys = || NoiseKeys {
        private: &key.private,
        fixed_ephemeral: None,
    };
    while let Some(Ok(message)) = socket.next().await {
        let Message::Binary(bytes) = message else {
            continue;
        };
        let (ch, frame) = channel::unwrap(&bytes).unwrap();
        let mut out: Vec<Vec<u8>> = Vec::new();
        match (frame[0], channels.remove(&ch)) {
            (k, None) if k == Kind::Pair as u8 => {
                let (pair, reply) = HostPair::start(keys(), PIN, frame, rand::random()).unwrap();
                out.push(reply);
                channels.insert(ch, State::Pairing(pair));
            }
            (k, Some(State::Pairing(pair))) if k == Kind::PairFinish as u8 => {
                match pair.finish(frame) {
                    Ok((transport, identity)) => {
                        paired.push(identity.public_key);
                        channels.insert(ch, State::Open(Records::new(transport)));
                    }
                    Err(reject) => out.push(reject.frame()),
                }
            }
            (k, None) if k == Kind::Connect as u8 => {
                match channel::connect(keys(), frame, |device| paired.iter().any(|p| p == device)) {
                    Ok((transport, accept, _)) => {
                        out.push(accept);
                        channels.insert(ch, State::Open(Records::new(transport)));
                    }
                    Err(reject) => out.push(reject.frame()),
                }
            }
            (_, Some(State::Open(mut records))) => {
                if let Some(request) = records.receive(frame).unwrap() {
                    let request: Value = serde_json::from_slice(&request).unwrap();
                    records.handled();
                    for reply in answer(&request) {
                        records.queue(serde_json::to_vec(&reply).unwrap()).unwrap();
                        while let Some(f) = records.next_frame().unwrap() {
                            out.push(f);
                        }
                    }
                }
                while let Some(f) = records.next_frame().unwrap() {
                    out.push(f);
                }
                channels.insert(ch, State::Open(records));
            }
            _ => out.push(Reject::BadHandshake.frame()),
        }
        for frame in out {
            socket
                .send(Message::Binary(channel::wrap(ch, &frame).into()))
                .await
                .unwrap();
        }
    }
}

fn answer(request: &Value) -> Vec<Value> {
    let id = &request["id"];
    let result = |value: Value| json!({"type": "result", "id": id, "result": value});
    match request["type"].as_str().unwrap() {
        "hello" => {
            assert_eq!(request["versions"], json!([1]));
            vec![
                json!({"type": "welcome", "version": 1, "name": "studio", "runnerVersion": "0.20.2", "platform": "linux", "features": ["ping"]}),
            ]
        }
        "ping" => vec![json!({"type": "pong", "id": id})],
        "overview" => vec![result(
            json!({"projects": [], "tabs": [], "missions": [], "sessions": {
                "s1": {"kind": "chat", "title": "Fix the build", "runtime": "claude", "cwd": "/tmp", "status": "idle", "reason": null, "unread": false}
            }}),
        )],
        "attach" => vec![
            json!({"type": "snapshot", "session": request["session"], "seq": 0, "cols": request["cols"], "rows": request["rows"], "data": STANDARD.encode("$ "), "more": false}),
            result(Value::Null),
        ],
        "input" => vec![
            json!({"type": "output", "session": request["session"], "seq": 1, "data": request["data"]}),
            result(Value::Null),
        ],
        other => vec![
            json!({"type": "error", "id": id, "code": "unknownRequest", "message": format!("no {other}")}),
        ],
    }
}

/// The app's side: commands in, events out.
struct App {
    core: Core,
    events: mpsc::UnboundedReceiver<Value>,
    /// Events received while waiting for a different one, in arrival order.
    skipped: VecDeque<Value>,
    next: u64,
}

impl App {
    fn new() -> Self {
        let (tx, events) = mpsc::unbounded_channel();
        let core = Core::new(Arc::new(move |event| {
            let _ = tx.send(event);
        }));
        Self {
            core,
            events,
            skipped: VecDeque::new(),
            next: 1,
        }
    }

    async fn call(&mut self, mut command: Value) -> Result<Value, String> {
        let id = self.next;
        self.next += 1;
        command["id"] = id.into();
        self.core.send(&command.to_string()).unwrap();
        let event = self
            .next_matching(|e| e["type"] == "reply" && e["id"] == id)
            .await;
        if event["ok"] == true {
            Ok(event["value"].clone())
        } else {
            Err(event["error"].as_str().unwrap().to_owned())
        }
    }

    /// The first event, buffered or new, that `wanted` accepts; others stay buffered.
    async fn next_matching(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        if let Some(at) = self.skipped.iter().position(&wanted) {
            return self.skipped.remove(at).unwrap();
        }
        loop {
            let event = tokio::time::timeout(WAIT, self.events.recv())
                .await
                .expect("event in time")
                .unwrap();
            if wanted(&event) {
                return event;
            }
            self.skipped.push_back(event);
        }
    }

    /// The next push on a route.
    async fn push(&mut self, route: &Value) -> Value {
        self.next_matching(|e| e["type"] == "route" && &e["route"] == route)
            .await["message"]
            .clone()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_phone_signs_in_pairs_and_drives_a_terminal() {
    let s = server().await;
    let host_key = HostKey::generate().unwrap();
    let host_fingerprint = fingerprint(&host_key.public);
    let (computer, socket) = s.computer(&host_key).await;
    let host_key_copy = HostKey::from_private(&STANDARD.encode(&*host_key.private)).unwrap();
    tokio::spawn(run_host(socket, host_key_copy));

    let mut app = App::new();
    let origin = s.origin.clone();

    // Sign in as a phone with the device flow.
    let start = app
        .call(json!({"op": "startEnrollment", "origin": origin, "device": {"name": "Alice's phone", "platform": "android", "osVersion": "16", "appVersion": "0.1.0"}}))
        .await
        .unwrap();
    let device_code = start["deviceCode"].as_str().unwrap().to_owned();
    let pending = app
        .call(json!({"op": "pollEnrollment", "origin": origin, "deviceCode": device_code}))
        .await
        .unwrap();
    assert_eq!(pending["state"], "ENROLLMENT_STATE_PENDING");
    s.approve(start["userCode"].as_str().unwrap());
    let issued = app
        .call(json!({"op": "pollEnrollment", "origin": origin, "deviceCode": device_code}))
        .await
        .unwrap();
    assert_eq!(issued["state"], "ENROLLMENT_STATE_APPROVED");
    let credential = issued["credential"].as_str().unwrap().to_owned();

    // Only the computer is listed, not the phone itself.
    let listed = app
        .call(json!({"op": "listComputers", "origin": origin, "credential": credential}))
        .await
        .unwrap();
    let hosts = listed["hosts"].as_array().unwrap();
    assert_eq!(hosts.len(), 1);
    assert_eq!(hosts[0]["id"], computer.as_str());
    assert_eq!(hosts[0]["online"], true);
    assert_eq!(hosts[0]["fingerprint"], host_fingerprint.as_str());

    let pair = |pin: &str, fingerprint: &str| {
        json!({"op": "pair", "origin": origin, "credential": credential, "computer": computer,
               "fingerprint": fingerprint, "pin": pin, "name": "Alice's phone"})
    };
    assert_eq!(
        app.call(pair("000000", &host_fingerprint))
            .await
            .unwrap_err(),
        "PIN 不正确"
    );
    assert_eq!(
        app.call(pair("12345", &host_fingerprint))
            .await
            .unwrap_err(),
        "PIN 必须是 6 位数字"
    );
    assert!(
        app.call(pair(PIN, "0000 0000 0000 0000 0000"))
            .await
            .unwrap_err()
            .contains("指纹"),
        "a host whose key differs from the listed fingerprint is refused"
    );

    let paired = app.call(pair(PIN, &host_fingerprint)).await.unwrap();
    assert_eq!(paired["welcome"]["name"], "studio");
    let route = paired["route"].clone();

    let overview = app
        .call(json!({"op": "request", "route": route, "message": {"type": "overview"}}))
        .await
        .unwrap();
    assert_eq!(overview["sessions"]["s1"]["title"], "Fix the build");

    let attach = json!({"op": "request", "route": route, "message":
        {"type": "attach", "session": "s1", "cols": 80, "rows": 24, "control": "take", "history": 1000}});
    app.call(attach).await.unwrap();
    // The snapshot was pushed before the attach result.
    let snapshot = app.push(&route).await;
    assert_eq!(snapshot["type"], "snapshot");
    assert_eq!(
        STANDARD.decode(snapshot["data"].as_str().unwrap()).unwrap(),
        b"$ "
    );

    let input = json!({"op": "request", "route": route, "message":
        {"type": "input", "session": "s1", "data": STANDARD.encode("ls\r")}});
    app.call(input).await.unwrap();
    let output = app.push(&route).await;
    assert_eq!(output["type"], "output");
    assert_eq!(
        STANDARD.decode(output["data"].as_str().unwrap()).unwrap(),
        b"ls\r"
    );

    let unknown = json!({"op": "request", "route": route, "message": {"type": "frobnicate"}});
    assert_eq!(app.call(unknown).await.unwrap_err(), "no frobnicate");

    app.call(json!({"op": "close", "route": route}))
        .await
        .unwrap();
    let closed = app
        .next_matching(|e| e["type"] == "routeClosed" && e["route"] == route)
        .await;
    assert_eq!(
        closed["error"],
        Value::Null,
        "a route the app closed ends cleanly"
    );
    let closed = json!({"op": "request", "route": route, "message": {"type": "overview"}});
    assert_eq!(app.call(closed).await.unwrap_err(), "连接已关闭");

    // Reconnect with the saved keys: Noise IK, no PIN.
    let connect = |client_key: &Value| {
        json!({"op": "connect", "origin": origin, "credential": credential, "computer": computer,
               "clientKey": client_key, "hostKey": paired["hostKey"]})
    };
    let again = app.call(connect(&paired["clientKey"])).await.unwrap();
    let route = again["route"].clone();
    let overview = app
        .call(json!({"op": "request", "route": route, "message": {"type": "overview"}}))
        .await
        .unwrap();
    assert_eq!(overview["sessions"]["s1"]["kind"], "chat");

    // A key the host never paired with is not recognized.
    let stranger = HostKey::generate().unwrap();
    let refused = app
        .call(connect(&Value::String(STANDARD.encode(&*stranger.private))))
        .await
        .unwrap_err();
    assert!(refused.contains("不认识本机"), "{refused}");
}

#[tokio::test(flavor = "multi_thread")]
async fn bad_input_is_reported_as_an_error_reply() {
    let mut app = App::new();
    assert!(app.core.send("not json").is_err());
    let error = app.call(json!({"op": "frobnicate"})).await.unwrap_err();
    assert!(error.starts_with("invalid command"), "{error}");
    let error = app
        .call(json!({"op": "listComputers", "origin": "http://example.com", "credential": "x"}))
        .await
        .unwrap_err();
    assert_eq!(error, "只支持 HTTPS 地址");
    let error = app
        .call(json!({"op": "request", "route": 99, "message": {"type": "overview"}}))
        .await
        .unwrap_err();
    assert_eq!(error, "连接已关闭");
}

/// Against a real deployment over TLS: `RUNNER_ORIGIN=https://… cargo test -- --ignored`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a live runner-server"]
async fn a_live_server_answers_over_tls() {
    let origin = std::env::var("RUNNER_ORIGIN").expect("RUNNER_ORIGIN");
    let mut app = App::new();
    let error = app
        .call(json!({"op": "listComputers", "origin": origin, "credential": "rhc_invalid"}))
        .await
        .unwrap_err();
    assert_eq!(error, "登录已失效，请重新登录");
    let refused = app
        .call(json!({"op": "connect", "origin": origin, "credential": "rhc_invalid", "computer": "1",
                     "clientKey": STANDARD.encode([1u8; 32]), "hostKey": STANDARD.encode([2u8; 32])}))
        .await
        .unwrap_err();
    assert_eq!(
        refused, "登录已失效，请重新登录",
        "the relay route is reachable over wss"
    );
}
