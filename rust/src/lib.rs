//! Client side of Runner remote control for the mobile app.
//!
//! The app talks to this crate with JSON. Each command carries an `id` and an `op`,
//! and is answered by one `reply` event with the same `id`. Open routes also send
//! `route` events (companion pushes: overview, snapshot, output, ...) and one
//! `routeClosed` event when they end. Secrets stay with the app, which stores them in
//! the platform's secure storage and passes them back in each command.

pub mod api;
mod ffi;
pub mod route;

use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::sync::{mpsc, oneshot};

/// Receives every event as JSON.
pub type Events = Arc<dyn Fn(Value) + Send + Sync>;

pub struct Core {
    runtime: std::mem::ManuallyDrop<tokio::runtime::Runtime>,
    shared: Arc<Shared>,
}

impl Drop for Core {
    fn drop(&mut self) {
        // SAFETY: the runtime is taken exactly once, here.
        let runtime = unsafe { std::mem::ManuallyDrop::take(&mut self.runtime) };
        // Dropping it normally blocks, which panics inside another runtime's task.
        runtime.shutdown_background();
    }
}

struct Shared {
    events: Mutex<Events>,
    routes: Mutex<HashMap<u64, mpsc::UnboundedSender<route::Command>>>,
    next_route: AtomicU64,
}

impl Shared {
    fn emit(&self, event: Value) {
        let events = self
            .events
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        events(event);
    }
}

impl route::Sink for Shared {
    fn message(&self, route: u64, message: Value) {
        self.emit(json!({"type": "route", "route": route, "message": message}));
    }
    fn closed(&self, route: u64, error: Option<String>) {
        self.routes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&route);
        self.emit(json!({"type": "routeClosed", "route": route, "error": error}));
    }
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Op {
    #[serde(rename_all = "camelCase")]
    StartEnrollment { origin: String, device: api::Device },
    #[serde(rename_all = "camelCase")]
    PollEnrollment { origin: String, device_code: String },
    #[serde(rename_all = "camelCase")]
    ListComputers { origin: String, credential: String },
    #[serde(rename_all = "camelCase")]
    SignOut { origin: String, credential: String },
    /// Pairs with a computer by PIN and keeps the channel open as a route.
    #[serde(rename_all = "camelCase")]
    Pair {
        origin: String,
        credential: String,
        computer: String,
        fingerprint: String,
        pin: String,
        name: String,
    },
    /// Opens a route to a paired computer.
    #[serde(rename_all = "camelCase")]
    Connect {
        origin: String,
        credential: String,
        computer: String,
        client_key: String,
        host_key: String,
    },
    /// Sends a companion request (`overview`, `attach`, `input`, ...) on a route;
    /// the reply carries its result. The core assigns the request id.
    #[serde(rename_all = "camelCase")]
    Request { route: u64, message: Value },
    #[serde(rename_all = "camelCase")]
    Close { route: u64 },
}

#[derive(Deserialize)]
struct Envelope {
    id: u64,
    #[serde(flatten)]
    op: Value,
}

impl Core {
    pub fn new(events: Events) -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("runner-mobile-core")
            .enable_all()
            .build()
            .expect("tokio runtime builds");
        Self {
            runtime: std::mem::ManuallyDrop::new(runtime),
            shared: Arc::new(Shared {
                events: Mutex::new(events),
                routes: Mutex::new(HashMap::new()),
                next_route: AtomicU64::new(1),
            }),
        }
    }

    /// Replaces where events go, e.g. after the app's Dart isolate restarts.
    pub fn set_events(&self, events: Events) {
        *self.shared.events.lock().unwrap_or_else(|e| e.into_inner()) = events;
    }

    /// Starts one command. Fails only if the JSON is not a command envelope.
    pub fn send(&self, command: &str) -> Result<(), String> {
        let Envelope { id, op } =
            serde_json::from_str(command).map_err(|e| format!("invalid command: {e}"))?;
        let shared = self.shared.clone();
        let runtime = self.runtime.handle().clone();
        self.runtime.spawn(async move {
            let result = match serde_json::from_value::<Op>(op) {
                Ok(op) => execute(&shared, &runtime, op).await,
                Err(e) => Err(format!("invalid command: {e}")),
            };
            shared.emit(match result {
                Ok(value) => json!({"type": "reply", "id": id, "ok": true, "value": value}),
                Err(error) => json!({"type": "reply", "id": id, "ok": false, "error": error}),
            });
        });
        Ok(())
    }
}

fn open(
    shared: &Arc<Shared>,
    runtime: &tokio::runtime::Handle,
    channel: route::Channel,
) -> (u64, Value) {
    let id = shared.next_route.fetch_add(1, Ordering::Relaxed);
    let welcome = channel.welcome.clone();
    let sink: Arc<dyn route::Sink> = shared.clone();
    let tx = route::spawn(runtime, id, channel, sink);
    shared
        .routes
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, tx);
    (id, welcome)
}

async fn execute(
    shared: &Arc<Shared>,
    runtime: &tokio::runtime::Handle,
    op: Op,
) -> Result<Value, String> {
    match op {
        Op::StartEnrollment { origin, device } => {
            api::start_enrollment(&api::origin(&origin)?, &device).await
        }
        Op::PollEnrollment {
            origin,
            device_code,
        } => api::poll_enrollment(&api::origin(&origin)?, &device_code).await,
        Op::ListComputers { origin, credential } => {
            api::list_computers(&api::origin(&origin)?, &credential).await
        }
        Op::SignOut { origin, credential } => {
            api::sign_out(&api::origin(&origin)?, &credential).await
        }
        Op::Pair {
            origin,
            credential,
            computer,
            fingerprint,
            pin,
            name,
        } => {
            let socket = api::open_route(&api::origin(&origin)?, &credential, &computer).await?;
            let (channel, pairing) = route::pair(socket, &pin, &name, &fingerprint).await?;
            let (route, welcome) = open(shared, runtime, channel);
            Ok(json!({
                "route": route,
                "welcome": welcome,
                "clientKey": pairing.client_private,
                "hostKey": pairing.host_public,
            }))
        }
        Op::Connect {
            origin,
            credential,
            computer,
            client_key,
            host_key,
        } => {
            let socket = api::open_route(&api::origin(&origin)?, &credential, &computer).await?;
            let pairing = route::Pairing {
                client_private: client_key,
                host_public: host_key,
            };
            let channel = route::connect(socket, &pairing).await?;
            let (route, welcome) = open(shared, runtime, channel);
            Ok(json!({"route": route, "welcome": welcome}))
        }
        Op::Request { route, message } => {
            let (reply, result) = oneshot::channel();
            let sent = shared
                .routes
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&route)
                .is_some_and(|tx| tx.send(route::Command::Request(message, reply)).is_ok());
            if !sent {
                return Err("连接已关闭".into());
            }
            result.await.unwrap_or_else(|_| Err("连接已关闭".into()))
        }
        Op::Close { route } => {
            if let Some(tx) = shared
                .routes
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&route)
            {
                let _ = tx.send(route::Command::Close);
            }
            Ok(Value::Null)
        }
    }
}
