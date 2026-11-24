//! The crew requests the app sends (`lib/pages/crews.dart`), answered by Runner's
//! own host core booted on a scratch folder: decoded with the parser `runnerd`
//! uses, then run by the handler that stores crews in Runner's database. What
//! the app reads back (catalog crews and roles, crew records) is checked too.

use runner_core::companion::ClientMessage;
use runner_daemon::companion::core::{Core, DaemonCore};
use serde_json::{Value, json};
use std::sync::Arc;

struct Host {
    _core: Arc<runner_daemon::AppCore>,
    daemon: DaemonCore,
    _dir: tempfile::TempDir,
}

fn host() -> Host {
    let dir = tempfile::tempdir().unwrap();
    let mut paths = runner_daemon::daemon::boot::NativePaths::new(
        dir.path().join("data"),
        dir.path().join("logs"),
    );
    paths.home_dir = Some(dir.path().join("home"));
    std::fs::create_dir_all(dir.path().join("home")).unwrap();
    let core = Arc::new(runner_daemon::daemon::boot::boot(&paths, Vec::new(), false).unwrap());
    let daemon = DaemonCore(Arc::downgrade(&core));
    Host {
        _core: core,
        daemon,
        _dir: dir,
    }
}

impl Host {
    /// Sends [request] as the app does; the host's result, or its error.
    fn send(&self, mut request: Value) -> Result<Value, String> {
        request["id"] = 7.into();
        let message = ClientMessage::decode(&serde_json::to_vec(&request).unwrap())
            .map_err(|e| format!("{request}: {}", e.message))?;
        let ClientMessage::Action(action) = message else {
            panic!("{request} is not an action");
        };
        self.daemon
            .action(*action)
            .map_err(|failure| failure.1.to_owned())
    }

    fn ok(&self, request: Value) -> Value {
        self.send(request.clone())
            .unwrap_or_else(|e| panic!("{request}: {e}"))
    }

    fn crew(&self, id: &str) -> Value {
        self.ok(json!({"type": "crew", "crew": id}))
    }

    fn handles(&self, crew: &str) -> Vec<String> {
        self.crew(crew)["slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["handle"].as_str().unwrap().to_owned())
            .collect()
    }
}

#[test]
fn the_app_manages_crews_on_runner() {
    let host = host();
    let role = |handle: &str, name: &str| {
        host.ok(json!({
            "type": "createRole", "handle": handle, "name": name, "runtime": "codex",
            "command": null, "args": [], "workingDir": null, "systemPrompt": null,
            "model": null, "effort": null, "speed": null, "permissionMode": null,
        }))["role"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let coder = role("coder", "Coder");
    let reviewer = role("reviewer", "Reviewer");

    // What the crews page and member form read from the catalog.
    let catalog = host.ok(json!({"type": "catalog"}));
    let roles = catalog["roles"].as_array().unwrap();
    let listed = roles.iter().find(|r| r["id"] == coder.as_str()).unwrap();
    for key in ["name", "handle", "runtime"] {
        assert!(listed[key].is_string(), "role {key}: {listed}");
    }
    let codex = catalog["runtimes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == "codex")
        .expect("codex in the catalog");
    for key in ["label", "available", "models", "efforts", "speeds"] {
        assert!(!codex[key].is_null(), "runtime {key}: {codex}");
    }

    // createCrew, as the new-crew dialog sends it; the result opens the crew.
    let created = host.ok(json!({"type": "createCrew", "name": "Duo", "conventions": null}));
    let crew = created["crew"].as_str().expect("{created}").to_owned();
    let record = host.crew(&crew);
    assert_eq!(record["name"], "Duo");
    assert_eq!(record["conventions"], Value::Null);
    assert_eq!(record["slots"], json!([]));
    let catalog = host.ok(json!({"type": "catalog"}));
    let entry = catalog["crews"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == crew.as_str())
        .expect("listed");
    assert_eq!(entry["name"], "Duo");

    host.ok(json!({"type": "updateCrew", "crew": crew, "name": "Pair", "conventions": "Review before committing."}));
    let record = host.crew(&crew);
    assert_eq!(record["name"], "Pair");
    assert_eq!(record["conventions"], "Review before committing.");

    // addSlot, as the member form sends it; Runner refuses a handle in use,
    // which the app checks before sending.
    let add = |role: &str, handle: &str, runtime: Value| {
        host.send(json!({"type": "addSlot", "crew": crew, "role": role, "handle": handle, "runtime": runtime, "model": null}))
    };
    let first = add(&coder, "coder", Value::Null).unwrap()["slot"]
        .as_str()
        .unwrap()
        .to_owned();
    let second = add(&reviewer, "reviewer", json!("codex")).unwrap()["slot"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        add(&coder, "coder", Value::Null)
            .unwrap_err()
            .contains("already in use")
    );
    assert!(
        add(&coder, "Bad Name", Value::Null).is_err(),
        "the app's rule is Runner's"
    );
    assert_eq!(host.handles(&crew), ["coder", "reviewer"]);
    let entry = host.ok(json!({"type": "catalog"}))["crews"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == crew.as_str())
        .unwrap()
        .clone();
    assert_eq!(
        entry["slots"][1]["handle"], "reviewer",
        "the list shows members"
    );

    // updateSlot sends every field: what the form changed and what it kept.
    // The catalog's first option is '' for the runtime's default, which the
    // member form folds into "跟随角色" (null); a named model follows it.
    assert_eq!(codex["models"][0]["value"], "");
    assert_eq!(codex["efforts"][0]["value"], "");
    let model = codex["models"][1]["value"].clone();
    assert!(model.as_str().is_some_and(|m| !m.is_empty()));
    host.ok(json!({"type": "updateSlot", "slot": second, "handle": "checker", "runtime": "codex", "model": model, "effort": "high", "speed": "fast"}));
    let slot = host.crew(&crew)["slots"][1].clone();
    assert_eq!(slot["id"], second.as_str());
    assert_eq!(slot["handle"], "checker");
    assert_eq!(slot["role"], reviewer.as_str());
    assert_eq!(slot["runtime"], "codex");
    assert_eq!(slot["model"], model);
    assert_eq!(slot["effort"], "high");
    assert_eq!(slot["speed"], "fast");
    // Back to the role's settings: null clears the override.
    host.ok(json!({"type": "updateSlot", "slot": second, "handle": "checker", "runtime": null, "model": null, "effort": null, "speed": null}));
    let slot = host.crew(&crew)["slots"][1].clone();
    assert_eq!(
        (
            &slot["runtime"],
            &slot["model"],
            &slot["effort"],
            &slot["speed"]
        ),
        (&Value::Null, &Value::Null, &Value::Null, &Value::Null)
    );

    host.ok(json!({"type": "reorderSlots", "crew": crew, "order": [second, first]}));
    assert_eq!(host.handles(&crew), ["checker", "coder"]);
    host.ok(json!({"type": "removeSlot", "slot": first}));
    assert_eq!(host.handles(&crew), ["checker"]);

    host.ok(json!({"type": "deleteCrew", "crew": crew}));
    assert!(host.send(json!({"type": "crew", "crew": crew})).is_err());
    let catalog = host.ok(json!({"type": "catalog"}));
    assert!(
        catalog["crews"]
            .as_array()
            .unwrap()
            .iter()
            .all(|c| c["id"] != crew.as_str())
    );
}

impl Host {
    /// Sends a non-action request ([ClientMessage::Feed], `Post`, `Answer`) as
    /// the app does, to the handler `runnerd` routes it to.
    fn chat(&self, mut request: Value) -> Result<Value, String> {
        request["id"] = 7.into();
        let message = ClientMessage::decode(&serde_json::to_vec(&request).unwrap())
            .map_err(|e| format!("{request}: {}", e.message))?;
        let failed = |f: runner_daemon::companion::core::Failure| f.1.to_owned();
        match message {
            ClientMessage::Feed(feed) => self
                .daemon
                .feed(feed)
                .map(|page| serde_json::to_value(page).unwrap())
                .map_err(failed),
            ClientMessage::Post(post) => {
                self.daemon.post(post).map(|()| Value::Null).map_err(failed)
            }
            ClientMessage::Answer(answer) => self
                .daemon
                .answer(answer)
                .map(|()| Value::Null)
                .map_err(failed),
            other => panic!("{request} is not a chat request: {other:?}"),
        }
    }
}

/// A mission whose one member runs `cat` in place of an agent, so it starts
/// anywhere; then the chat the app shows: the feed, a post to everyone and
/// one to a member, as the app sends them.
#[test]
fn the_app_chats_in_a_mission_on_runner() {
    let host = host();
    // Pick a runtime without a minimum-version gate so Runner does not probe
    // `cat --version` and reject uutils coreutils' 0.0.x version on CI.
    let role = host.ok(json!({
        "type": "createRole", "handle": "coder", "name": "Coder", "runtime": "trae",
        "command": "cat", "args": [], "workingDir": null, "systemPrompt": null,
        "model": null, "effort": null, "speed": null, "permissionMode": null,
    }))["role"]
        .as_str()
        .unwrap()
        .to_owned();
    let crew = host.ok(json!({"type": "createCrew", "name": "Solo", "conventions": null}))["crew"]
        .as_str()
        .unwrap()
        .to_owned();
    host.ok(json!({"type": "addSlot", "crew": crew, "role": role, "handle": "coder", "runtime": null, "model": null}));
    let cwd = host._dir.path().join("home");
    let mission = host.ok(json!({
        "type": "startMission", "crew": crew, "project": null, "title": "Ship it",
        "goal": "Ship the release.", "cwd": cwd, "cols": 80, "rows": 24,
    }))["mission"]
        .as_str()
        .unwrap()
        .to_owned();

    let feed = || {
        host.chat(json!({"type": "feed", "mission": mission, "before": null, "limit": 50}))
            .unwrap()
    };
    let page = feed();
    let entries = page["entries"].as_array().unwrap();
    let goal = entries
        .iter()
        .find(|e| e["signal"] == "mission_goal")
        .expect("the goal is in the feed");
    assert_eq!(
        goal["payload"]["text"], "Ship the release.",
        "the app reads payload.text"
    );

    // As the composer sends them: to everyone, to a member chosen as a
    // recipient, and to a member named first in the text.
    for (to, text) in [
        (json!([]), "Status, everyone?"),
        (json!(["coder"]), "Only you."),
        (json!([]), "@coder Ship it."),
    ] {
        host.chat(json!({"type": "post", "mission": mission, "to": to, "text": text}))
            .unwrap();
    }
    // A leading @name that is no member is refused, with Runner's reason.
    let refused = host
        .chat(json!({"type": "post", "mission": mission, "to": [], "text": "@nobody hi"}))
        .unwrap_err();
    assert!(!refused.is_empty());
    let page = feed();
    // The app shows these as the person's own messages: kind message, from
    // human, to the members Runner settled on (newest first).
    let posts: Vec<(&str, Vec<String>)> = page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "message" && e["from"] == "human")
        .map(|e| (e["text"].as_str().unwrap(), recipients(&e["to"])))
        .collect();
    assert_eq!(
        posts,
        [
            ("@coder Ship it.", vec!["coder".to_owned()]),
            ("Only you.", vec!["coder".to_owned()]),
            ("Status, everyone?", vec![]),
        ],
        "{page}"
    );

    // A stopped mission still takes posts, so the app lets the person write.
    host.ok(json!({"type": "stopMission", "mission": mission}));
    host.chat(json!({"type": "post", "mission": mission, "to": [], "text": "For later."}))
        .unwrap();
    assert_eq!(feed()["entries"][0]["text"], "For later.");
}

/// What `recipients()` in `lib/pages/mission.dart` reads: one handle or several.
fn recipients(target: &Value) -> Vec<String> {
    match target {
        Value::String(one) => vec![one.clone()],
        Value::Array(several) => several
            .iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}
