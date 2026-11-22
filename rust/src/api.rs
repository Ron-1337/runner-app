//! runner-server's HTTP API and relay route, from a phone's side.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{self, client::IntoClientRequest, http::HeaderValue},
};

pub type Socket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

const ENROLL: &str = "/api/runner_server.v1.HostEnrollmentService";
const CLIENT: &str = "/api/runner_server.v1.HostClientService";
const CLIENT_SUBPROTOCOL: &str = "runner-client.v1";
const NOTIFY: &str = "/api/runner_server.v1.NotifyService";

/// The NotifyService methods the app may call.
const NOTIFY_METHODS: [&str; 7] = [
    "GetSettings",
    "SetSettings",
    "Test",
    "ListWatchers",
    "PairWatcher",
    "UnpairWatcher",
    "ClaimSession",
];

/// What the phone tells the server about itself when it signs in.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Device {
    pub name: String,
    pub platform: String,
    pub os_version: String,
    pub app_version: String,
}

pub fn origin(value: &str) -> Result<String, String> {
    let origin = value.trim().trim_end_matches('/').to_owned();
    match origin.split_once("://") {
        // The app warns before plain HTTP; the relay traffic stays end-to-end
        // encrypted either way.
        Some(("https" | "http", rest)) if !rest.is_empty() && !rest.starts_with('/') => Ok(origin),
        _ => Err("只支持 HTTPS 或 HTTP 地址".into()),
    }
}

fn http() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .expect("HTTP client builds")
}

async fn rpc(
    origin: &str,
    path: &str,
    credential: Option<&str>,
    body: Value,
) -> Result<Value, String> {
    reply(send(origin, path, credential, body).await?).await
}

async fn send(
    origin: &str,
    path: &str,
    credential: Option<&str>,
    body: Value,
) -> Result<reqwest::Response, String> {
    // As the official app sends every call.
    let mut request = http()
        .post(format!("{origin}{path}"))
        .header("Connect-Protocol-Version", "1")
        .json(&body);
    if let Some(credential) = credential {
        request = request.bearer_auth(credential);
    }
    request
        .send()
        .await
        .map_err(|e| format!("无法连接服务器：{}", without_url(&e)))
}

/// A response's JSON body, or the error it carries.
async fn reply(response: reqwest::Response) -> Result<Value, String> {
    let status = response.status();
    let value: Value = response
        .json()
        .await
        .map_err(|_| format!("服务器返回了无法识别的内容（HTTP {status}）"))?;
    if status.is_success() {
        return Ok(value);
    }
    Err(match value["code"].as_str() {
        Some("unauthenticated") => "登录已失效，请重新登录".into(),
        _ => value["message"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("服务器错误（HTTP {status}）")),
    })
}

/// The error with its causes (reqwest's own message rarely says what failed),
/// without the URL, which the person already knows.
fn without_url(error: &reqwest::Error) -> String {
    let mut message = error.to_string();
    if let Some(url) = error.url() {
        message = message.replace(&format!(" for url ({url})"), "");
    }
    let mut source = std::error::Error::source(error);
    while let Some(cause) = source {
        message.push_str(&format!("：{cause}"));
        source = cause.source();
    }
    message
}

/// The StartEnrollment body for a phone, exactly as the official Runner app
/// sends it: a client, with no host key. runner-server takes the same.
fn enrollment_request(device: &Device) -> Value {
    json!({
        "kind": "ENROLLMENT_KIND_CLIENT",
        "client": {
            "platform": device.platform,
            "runnerVersion": device.app_version,
            "osVersion": device.os_version,
            "name": device.name,
        },
    })
}

/// Starts a device-flow sign-in as a phone.
pub async fn start_enrollment(origin: &str, device: &Device) -> Result<Value, String> {
    rpc(
        origin,
        &format!("{ENROLL}/StartEnrollment"),
        None,
        enrollment_request(device),
    )
    .await
}

pub async fn poll_enrollment(origin: &str, device_code: &str) -> Result<Value, String> {
    rpc(
        origin,
        &format!("{ENROLL}/PollEnrollment"),
        None,
        json!({ "deviceCode": device_code }),
    )
    .await
}

pub async fn list_computers(origin: &str, credential: &str) -> Result<Value, String> {
    rpc(
        origin,
        &format!("{CLIENT}/ListAccountHosts"),
        Some(credential),
        json!({}),
    )
    .await
}

/// Signs the phone out with `SignOutClient`.
pub async fn sign_out(origin: &str, credential: &str) -> Result<Value, String> {
    rpc(
        origin,
        &format!("{ENROLL}/SignOutClient"),
        Some(credential),
        json!({}),
    )
    .await
}

/// Calls one NotifyService [method] (push-notification settings, the server's
/// watchers, session claims) with the phone's credential. A server without
/// the service answers 404 without an error body.
pub async fn notify(
    origin: &str,
    credential: &str,
    method: &str,
    body: Value,
) -> Result<Value, String> {
    if !NOTIFY_METHODS.contains(&method) {
        return Err(format!("未知的通知操作：{method}"));
    }
    let body = if body.is_null() { json!({}) } else { body };
    let response = send(
        origin,
        &format!("{NOTIFY}/{method}"),
        Some(credential),
        body,
    )
    .await?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        let text = response.text().await.unwrap_or_default();
        return Err(serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v["message"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "服务器不支持推送通知，请升级 runner-server".into()));
    }
    reply(response).await
}

/// Opens `/relay/client` to one computer: the relay's end of a channel.
pub async fn open_route(origin: &str, credential: &str, computer: &str) -> Result<Socket, String> {
    let base = origin.replacen("http", "ws", 1);
    let mut request = format!("{base}/relay/client?host={computer}")
        .into_client_request()
        .map_err(|_| "服务器地址无效".to_owned())?;
    let headers = request.headers_mut();
    headers.insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {credential}"))
            .map_err(|_| "凭据无效".to_owned())?,
    );
    headers.insert(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_static(CLIENT_SUBPROTOCOL),
    );
    match tokio::time::timeout(Duration::from_secs(20), connect_async(request)).await {
        Err(_) => Err("连接中继超时".into()),
        Ok(Ok((socket, _))) => Ok(socket),
        Ok(Err(tungstenite::Error::Http(response))) => Err(match response.status().as_u16() {
            401 => "登录已失效，请重新登录".into(),
            404 => "找不到这台电脑".into(),
            429 => "这台电脑的连接太多，请稍后再试".into(),
            503 => "这台电脑不在线".into(),
            status => format!("中继拒绝了连接（HTTP {status}）"),
        }),
        Ok(Err(e)) => Err(format!("无法连接中继：{e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::{Device, enrollment_request, notify, origin};
    use serde_json::json;

    #[tokio::test]
    async fn notify_takes_only_the_service_methods() {
        let error = notify("http://127.0.0.1:1", "c", "DeleteEverything", json!({}))
            .await
            .unwrap_err();
        assert!(error.contains("DeleteEverything"), "{error}");
    }

    #[test]
    fn phones_enroll_as_the_official_app_does() {
        let device = Device {
            name: "iPhone".into(),
            platform: "ios".into(),
            os_version: "27.0".into(),
            app_version: "0.1.0".into(),
        };
        // The body the official app sent, from its captured traffic.
        assert_eq!(
            enrollment_request(&device),
            json!({"kind":"ENROLLMENT_KIND_CLIENT","client":{"platform":"ios","runnerVersion":"0.1.0","osVersion":"27.0","name":"iPhone"}})
        );
    }

    #[test]
    fn origins_are_https_or_http() {
        assert_eq!(
            origin(" https://runner.example.com/ ").unwrap(),
            "https://runner.example.com"
        );
        assert_eq!(
            origin("http://localhost:8080").unwrap(),
            "http://localhost:8080"
        );
        assert_eq!(origin("http://127.0.0.1:1/").unwrap(), "http://127.0.0.1:1");
        assert_eq!(
            origin("http://192.168.1.5:8080").unwrap(),
            "http://192.168.1.5:8080"
        );
        assert!(origin("ftp://runner.example.com").is_err());
        assert!(origin("http:///path").is_err());
        assert!(origin("runner.example.com").is_err());
        assert!(origin("https://").is_err());
    }
}
