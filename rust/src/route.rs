//! One encrypted channel to one computer, through the relay.
//!
//! Mirrors Runner's own client route (`runner-daemon/src/remote/client/route.rs`):
//! pair with CPace + Noise `XXpsk3`, or reconnect with Noise `IK` against the pinned
//! host key, then exchange `hello`/`welcome` and companion messages over records.

use crate::api::Socket;
use base64::{Engine, engine::general_purpose::STANDARD};
use futures_util::{SinkExt, StreamExt};
use runner_core::{
    companion::channel::{self, BrowserConnect, BrowserPair, Kind, NoiseKeys, Records, Reject},
    remote::{HostKey, fingerprint},
};
use serde_json::{Value, json};
use std::{collections::HashMap, collections::VecDeque, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
/// A route that hears nothing for this long is dead; the host answers pings every 5 s.
const RECEIVE_TIMEOUT: Duration = Duration::from_secs(15);
const PING_INTERVAL: Duration = Duration::from_secs(5);

pub type Reply = oneshot::Sender<Result<Value, String>>;

pub enum Command {
    Request(Value, Reply),
    Close,
}

/// Where a route reports pushes and its end.
pub trait Sink: Send + Sync + 'static {
    fn message(&self, route: u64, message: Value);
    fn closed(&self, route: u64, error: Option<String>);
}

/// A connected channel before its loop starts.
pub struct Channel {
    socket: Socket,
    records: Records,
    pub welcome: Value,
}

fn keys(key: &HostKey) -> NoiseKeys<'_> {
    NoiseKeys {
        private: &key.private,
        fixed_ephemeral: None,
    }
}

fn reject_message(reason: &str) -> String {
    match reason {
        "noPin" => "这台电脑还没有设置 PIN，请先在电脑上运行 runner remote pin".into(),
        "pinLocked" => "PIN 输错次数过多已锁定，请在电脑上重新设置 PIN".into(),
        "wrongPin" => "PIN 不正确".into(),
        "unknownDevice" => {
            "这台电脑不认识本机（配对可能已被撤销或电脑重置了身份），请核对指纹后重新配对".into()
        }
        "busy" => "电脑正忙，请稍后再试".into(),
        _ => "握手失败".into(),
    }
}

fn bad_handshake(reject: Reject) -> String {
    reject_message(reject.reason())
}

fn rejection(bytes: &[u8]) -> Option<String> {
    let reason = channel::body(bytes, Kind::Reject).ok()?;
    Some(reject_message(std::str::from_utf8(reason).unwrap_or("")))
}

fn close_message(code: u16) -> String {
    match code {
        1000 => "电脑关闭了连接".into(),
        1012 => "服务器正在重启".into(),
        1013 => "这台电脑不在线".into(),
        4003 => "这台电脑已被移除".into(),
        4413 => "连接拥塞，已断开".into(),
        code => format!("连接已关闭（{code}）"),
    }
}

async fn send(socket: &mut Socket, bytes: Vec<u8>) -> Result<(), String> {
    tokio::time::timeout(WRITE_TIMEOUT, socket.send(Message::Binary(bytes.into())))
        .await
        .map_err(|_| "发送超时".to_owned())?
        .map_err(|_| "连接已断开".to_owned())
}

async fn read(socket: &mut Socket) -> Result<Vec<u8>, String> {
    loop {
        match socket.next().await {
            Some(Ok(Message::Binary(bytes))) => {
                if let Some(message) = rejection(&bytes) {
                    return Err(message);
                }
                return Ok(bytes.to_vec());
            }
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
            Some(Ok(Message::Close(frame))) => {
                return Err(close_message(frame.map_or(1006, |f| f.code.into())));
            }
            _ => return Err("连接已断开".into()),
        }
    }
}

async fn flush(socket: &mut Socket, records: &mut Records) -> Result<(), String> {
    while let Some(frame) = records.next_frame().map_err(bad_handshake)? {
        send(socket, frame).await?;
    }
    Ok(())
}

fn hello_client() -> &'static str {
    // Runner records a paired device's kind from this; "ios" reads as a phone.
    if cfg!(target_os = "ios") {
        "ios"
    } else {
        "android"
    }
}

async fn welcome(socket: &mut Socket, records: &mut Records) -> Result<Value, String> {
    let hello = json!({
        "type": "hello",
        "versions": [1],
        "client": hello_client(),
        "build": env!("CARGO_PKG_VERSION"),
    });
    records
        .queue(serde_json::to_vec(&hello).expect("hello encodes"))
        .map_err(bad_handshake)?;
    loop {
        flush(socket, records).await?;
        if let Some(bytes) = records
            .receive(&read(socket).await?)
            .map_err(bad_handshake)?
        {
            let message: Value = serde_json::from_slice(&bytes)
                .map_err(|_| "电脑返回了无法识别的欢迎消息".to_owned())?;
            records.handled();
            flush(socket, records).await?;
            return match message["type"].as_str() {
                Some("welcome") if message["version"] == 1 => Ok(message),
                Some("error") => Err("电脑上的 Runner 不支持这个协议版本".into()),
                _ => Err("电脑返回了无法识别的欢迎消息".into()),
            };
        }
    }
}

/// The client's keys for one computer: its own private key and the host's pinned public key.
pub struct Pairing {
    pub client_private: String,
    pub host_public: String,
}

/// Pairs with a computer by its PIN. The host's key is trusted only once its first
/// data frame decrypts, which `welcome` proves, and only if its fingerprint is the one
/// the server listed for this computer.
pub async fn pair(
    mut socket: Socket,
    pin: &str,
    name: &str,
    expected_fingerprint: &str,
) -> Result<(Channel, Pairing), String> {
    if runner_core::remote::validate_pin_format(pin).is_err() {
        return Err("PIN 必须是 6 位数字".into());
    }
    let key = HostKey::generate().map_err(|_| "无法生成密钥".to_owned())?;
    tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        let (pair, first) = BrowserPair::start(keys(&key), pin, rand::random(), rand::random())
            .map_err(bad_handshake)?;
        send(&mut socket, first).await?;
        let (transport, finish, host_public) = pair
            .finish(&read(&mut socket).await?, name)
            .map_err(bad_handshake)?;
        send(&mut socket, finish).await?;
        let mut records = Records::new(transport);
        let welcome = welcome(&mut socket, &mut records).await?;
        if fingerprint(&host_public) != expected_fingerprint {
            return Err("电脑的指纹与服务器登记的不一致，已中止配对".into());
        }
        Ok((
            Channel {
                socket,
                records,
                welcome,
            },
            Pairing {
                client_private: STANDARD.encode(&*key.private),
                host_public: STANDARD.encode(&host_public),
            },
        ))
    })
    .await
    .map_err(|_| "配对超时，请重试".to_owned())?
}

/// Reconnects to a paired computer with the saved keys.
pub async fn connect(mut socket: Socket, pairing: &Pairing) -> Result<Channel, String> {
    let key = HostKey::from_private(&pairing.client_private)
        .map_err(|_| "保存的密钥已损坏，请重新配对".to_owned())?;
    let host = STANDARD
        .decode(&pairing.host_public)
        .map_err(|_| "保存的电脑密钥已损坏，请重新配对".to_owned())?;
    tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        let (connect, first) = BrowserConnect::start(keys(&key), &host).map_err(bad_handshake)?;
        send(&mut socket, first).await?;
        let mut records = Records::new(
            connect
                .accept(&read(&mut socket).await?)
                .map_err(bad_handshake)?,
        );
        let welcome = welcome(&mut socket, &mut records).await?;
        Ok(Channel {
            socket,
            records,
            welcome,
        })
    })
    .await
    .map_err(|_| "连接超时".to_owned())?
}

/// Runs a connected channel until it closes, then reports why.
pub fn spawn(
    runtime: &tokio::runtime::Handle,
    id: u64,
    channel: Channel,
    sink: std::sync::Arc<dyn Sink>,
) -> mpsc::UnboundedSender<Command> {
    let (tx, rx) = mpsc::unbounded_channel();
    runtime.spawn(async move {
        let error = run(id, channel, sink.as_ref(), rx).await.err();
        sink.closed(id, error);
    });
    tx
}

async fn run(
    id: u64,
    channel: Channel,
    sink: &dyn Sink,
    mut commands: mpsc::UnboundedReceiver<Command>,
) -> Result<(), String> {
    let Channel {
        mut socket,
        mut records,
        welcome,
    } = channel;
    let companion_ping = welcome["features"]
        .as_array()
        .is_some_and(|f| f.iter().any(|f| f == "ping"));
    let mut next_id: u64 = 1;
    let mut pending: HashMap<u64, Reply> = HashMap::new();
    let mut outgoing: VecDeque<Vec<u8>> = VecDeque::new();
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;

    let result = loop {
        // Send queued messages until they run out or the host's credit does.
        let pumped = loop {
            if !records.sending()
                && let Some(message) = outgoing.pop_front()
                && let Err(e) = records.queue(message)
            {
                break Err(bad_handshake(e));
            }
            if let Err(e) = flush(&mut socket, &mut records).await {
                break Err(e);
            }
            if records.sending() || outgoing.is_empty() {
                break Ok(());
            }
        };
        if let Err(e) = pumped {
            break Err(e);
        }
        tokio::select! {
            command = commands.recv() => match command {
                None | Some(Command::Close) => break Ok(()),
                Some(Command::Request(mut message, reply)) => {
                    if !message.is_object() || !message["type"].is_string() {
                        let _ = reply.send(Err("请求格式不正确".into()));
                        continue;
                    }
                    let request = next_id;
                    next_id += 1;
                    message["id"] = request.into();
                    let bytes = serde_json::to_vec(&message).expect("request encodes");
                    if bytes.len() > runner_core::companion::MAX_MESSAGE_SIZE {
                        let _ = reply.send(Err("请求太大".into()));
                        continue;
                    }
                    pending.insert(request, reply);
                    outgoing.push_back(bytes);
                }
            },
            frame = tokio::time::timeout(RECEIVE_TIMEOUT, socket.next()) => match frame {
                Err(_) => break Err("连接超时，电脑没有响应".into()),
                Ok(Some(Ok(Message::Binary(bytes)))) => {
                    if let Some(message) = rejection(&bytes) {
                        break Err(message);
                    }
                    let bytes = match records.receive(&bytes) {
                        Err(e) => break Err(bad_handshake(e)),
                        Ok(None) => continue,
                        Ok(Some(bytes)) => bytes,
                    };
                    let message: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
                    records.handled();
                    deliver(id, message, &mut pending, sink);
                }
                Ok(Some(Ok(Message::Close(frame)))) => {
                    break Err(close_message(frame.map_or(1006, |f| f.code.into())));
                }
                Ok(Some(Ok(_))) => {}
                Ok(Some(Err(_)) | None) => break Err("连接已断开".into()),
            },
            _ = ping.tick() => {
                if companion_ping {
                    let request = next_id;
                    next_id += 1;
                    outgoing.push_back(serde_json::to_vec(&json!({"type": "ping", "id": request})).expect("ping encodes"));
                } else {
                    // An older host without companion pings: keep the relay leg alive.
                    let sent = tokio::time::timeout(WRITE_TIMEOUT, socket.send(Message::Ping(Default::default()))).await;
                    if !matches!(sent, Ok(Ok(()))) {
                        break Err("连接已断开".into());
                    }
                }
            }
        }
    };
    let reason = result
        .as_ref()
        .err()
        .cloned()
        .unwrap_or_else(|| "连接已关闭".into());
    for (_, reply) in pending.drain() {
        let _ = reply.send(Err(reason.clone()));
    }
    let _ = socket.close(None).await;
    result
}

/// Answers a pending request with its result or error, and passes pushes on.
fn deliver(route: u64, message: Value, pending: &mut HashMap<u64, Reply>, sink: &dyn Sink) {
    let kind = message["type"].as_str().unwrap_or_default();
    let reply_to = message["id"]
        .as_u64()
        .filter(|_| matches!(kind, "result" | "error" | "pong"));
    if let Some(reply) = reply_to.and_then(|id| pending.remove(&id)) {
        let _ = reply.send(match kind {
            "error" => Err(message["message"]
                .as_str()
                .unwrap_or("电脑拒绝了请求")
                .to_owned()),
            "pong" => Ok(Value::Null),
            _ => Ok(message["result"].clone()),
        });
        return;
    }
    if !matches!(kind, "result" | "error" | "pong" | "") {
        sink.message(route, message);
    }
}
