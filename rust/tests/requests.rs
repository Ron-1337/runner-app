//! Every companion request the app sends (`lib/`), checked with the decoder `runnerd`
//! uses. A field the host does not expect, or one it requires and the app leaves out,
//! fails here instead of as a `badRequest` on the computer. Keep in step with `lib/`.

use runner_core::companion::{ActionRequest, ClientMessage};
use serde_json::{Value, json};

fn decode(mut request: Value) -> ClientMessage {
    request["id"] = 7.into();
    match ClientMessage::decode(&serde_json::to_vec(&request).unwrap()) {
        Ok(ClientMessage::Unknown(unknown)) => {
            panic!("{} is not a request Runner knows", unknown.request_type)
        }
        Ok(message) => message,
        Err(error) => panic!("{request}: {}", error.message),
    }
}

fn action(request: Value) -> ActionRequest {
    match decode(request) {
        ClientMessage::Action(action) => *action,
        _ => panic!("not an action"),
    }
}

const SIZE: (u16, u16) = (80, 24);

#[test]
fn terminal_requests() {
    let (cols, rows) = SIZE;
    for request in [
        json!({"type": "overview"}),
        json!({"type": "attach", "session": "s1", "cols": cols, "rows": rows, "control": "take", "history": 1000}),
        json!({"type": "input", "session": "s1", "data": "Aw=="}),
        json!({"type": "viewport", "session": "s1", "cols": cols, "rows": rows}),
        json!({"type": "takeControl", "session": "s1", "cols": cols, "rows": rows}),
        json!({"type": "detach", "session": "s1"}),
    ] {
        decode(request);
    }
}

#[test]
fn starting_chats_terminals_and_missions() {
    let (cols, rows) = SIZE;
    let place = |mut v: Value| {
        v["project"] = Value::Null;
        v["cwd"] = json!("/home/alice/code");
        v["cols"] = cols.into();
        v["rows"] = rows.into();
        v
    };
    match action(place(
        json!({"type": "startChat", "role": null, "runtime": "claude", "model": "opus", "effort": null, "speed": null}),
    )) {
        ActionRequest::StartChat {
            role,
            runtime,
            model,
            cwd,
            ..
        } => {
            assert_eq!(
                (role, runtime.as_deref(), model.as_deref()),
                (None, Some("claude"), Some("opus"))
            );
            assert_eq!(cwd.as_deref(), Some("/home/alice/code"));
        }
        _ => panic!("startChat"),
    }
    match action(place(
        json!({"type": "startChat", "role": "r1", "runtime": null, "model": null, "effort": null, "speed": null}),
    )) {
        ActionRequest::StartChat { role, runtime, .. } => {
            assert_eq!((role.as_deref(), runtime), (Some("r1"), None))
        }
        _ => panic!("startChat by role"),
    }
    assert!(matches!(
        action(place(json!({"type": "startShell"}))),
        ActionRequest::StartShell { .. }
    ));
    match action(place(
        json!({"type": "startMission", "crew": "c1", "title": "Release", "goal": null}),
    )) {
        ActionRequest::StartMission {
            crew, title, goal, ..
        } => {
            assert_eq!(
                (crew.as_str(), title.as_str(), goal),
                ("c1", "Release", None)
            );
        }
        _ => panic!("startMission"),
    }
}

#[test]
fn session_mission_and_workspace_actions() {
    let (cols, rows) = SIZE;
    for request in [
        json!({"type": "catalog"}),
        json!({"type": "folders", "path": null}),
        json!({"type": "folders", "path": "/home/alice"}),
        json!({"type": "resume", "session": "s1", "cols": cols, "rows": rows}),
        json!({"type": "restart", "session": "s1", "cols": cols, "rows": rows}),
        json!({"type": "stop", "session": "s1"}),
        json!({"type": "markViewed", "session": "s1"}),
        json!({"type": "stopMission", "mission": "m1"}),
        json!({"type": "resumeMission", "mission": "m1", "cols": cols, "rows": rows}),
        json!({"type": "createProject", "name": "code", "path": "/home/alice/code"}),
        json!({"type": "deleteProject", "project": "p1", "force": false}),
    ] {
        action(request);
    }
    for kind in ["session", "tab", "mission", "project"] {
        action(json!({"type": "rename", "target": {"kind": kind, "id": "x"}, "name": "New name"}));
        action(json!({"type": "archive", "target": {"kind": kind, "id": "x"}}));
    }
}
