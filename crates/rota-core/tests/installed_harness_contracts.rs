mod common;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::time::Duration;

use common::{TempDir, configured_or_installed_executable};
use rota_core::model::{Harness, QuestionRequest};
use rota_core::runners::{
    AntigravityCatalog, CodexItemOutput, ExecutableDiscovery, ModelCatalog, ModelOption, ProcessLauncher,
};
use rota_core::storage::atomic_write_bytes;
use rota_core::transcript::{ToolOutput, ToolOutputKind, TranscriptItemKind};
use serde_json::{Map, Value, json};

fn check_flags(harness: Harness, arguments: &[&str], required: &[&str]) {
    let Some(path) = configured_or_installed_executable(harness) else {
        return;
    };
    let args: Vec<String> = arguments.iter().map(|s| (*s).to_string()).collect();
    let dir = TempDir::new("rota-flags");
    let (status, output) = ProcessLauncher::capture(
        &path,
        &args,
        dir.path(),
        Some(Duration::from_secs(15)),
        true,
        true,
        &HashMap::new(),
    );
    assert_eq!(status, 0, "{output}");
    for flag in required {
        assert!(
            output.contains(flag),
            "Missing {} contract flag {flag} in:\n{output}",
            harness.title()
        );
    }
}

#[test]
fn claude_flags() {
    check_flags(
        Harness::Claude,
        &["--help"],
        &[
            "--input-format",
            "--output-format",
            "--include-partial-messages",
            "--resume",
            "--permission-mode",
            "--settings",
            "--effort",
        ],
    );
}

#[test]
fn codex_daemon_flags() {
    check_flags(
        Harness::Codex,
        &["app-server", "--help"],
        &["daemon", "proxy", "generate-json-schema"],
    );
}

#[test]
fn grok_acp_flags() {
    check_flags(
        Harness::Grok,
        &["agent", "--help"],
        &["--leader", "--no-leader", "--reasoning-effort", "stdio"],
    );
}

#[test]
fn antigravity_flags() {
    check_flags(
        Harness::Antigravity,
        &["--help"],
        &["--input-format", "--output-format", "--conversation", "--effort"],
    );
}

#[test]
fn installed_codex_interaction_schema_matches_adapters() {
    let Some(codex) = configured_or_installed_executable(Harness::Codex) else {
        return;
    };
    let dir = TempDir::new("rota-codex-schema");
    let schema = dir.path().join("schema");
    let args = vec![
        "app-server".into(),
        "generate-json-schema".into(),
        "--experimental".into(),
        "--out".into(),
        schema.to_string_lossy().into_owned(),
    ];
    let (status, output) = ProcessLauncher::capture(
        &codex,
        &args,
        dir.path(),
        Some(Duration::from_secs(30)),
        true,
        true,
        &HashMap::new(),
    );
    assert_eq!(status, 0, "{output}");

    let server_req: Value = serde_json::from_slice(
        &fs::read(schema.join("ServerRequest.json")).expect("read ServerRequest.json"),
    )
    .expect("parse ServerRequest.json");
    let variants = server_req["oneOf"].as_array().expect("ServerRequest.oneOf");
    let mut checked = Vec::new();
    for variant in variants {
        let Some(method) = variant
            .pointer("/properties/method/enum/0")
            .and_then(Value::as_str)
        else {
            continue;
        };
        if method.contains("Approval")
            || method.contains("requestUserInput")
            || method.contains("elicitation")
        {
            assert!(
                QuestionRequest::codex(method, &json!({})).is_some(),
                "Unhandled Codex interaction request method: {method}"
            );
            checked.push(method.to_string());
        }
    }
    assert!(
        !checked.is_empty(),
        "The schema walk must reach interaction requests"
    );
    check_dynamic_output_blocks_remain_visible(&schema);
    check_model_verification_schema_remains_visible(&schema);
}

fn check_dynamic_output_blocks_remain_visible(schema: &Path) {
    let root: Value = serde_json::from_slice(
        &fs::read(schema.join("v2/ThreadItemsListResponse.json"))
            .expect("read v2/ThreadItemsListResponse.json"),
    )
    .expect("parse ThreadItemsListResponse.json");
    let variants = root
        .pointer("/definitions/DynamicToolCallOutputContentItem/oneOf")
        .and_then(Value::as_array)
        .expect("DynamicToolCallOutputContentItem.oneOf");
    assert!(!variants.is_empty());
    for variant in variants {
        let props = variant["properties"].as_object().expect("variant properties");
        let kind = props["type"]["enum"][0].as_str().expect("variant type enum");
        let mut block = Map::new();
        block.insert("type".into(), json!(kind));
        for (key, prop) in props {
            if key != "type" && prop.get("type").and_then(Value::as_str) == Some("string") {
                let sample = if key == "imageUrl" {
                    "file:///tmp/synthetic-output.png"
                } else {
                    "Synthetic output"
                };
                block.insert(key.clone(), json!(sample));
            }
        }
        let entries = CodexItemOutput::entries(&json!({
            "type": "dynamicToolCall",
            "contentItems": [Value::Object(block)],
        }));
        assert_eq!(entries.len(), 1, "Installed output block disappeared: {kind}");
        assert!(!entries[0].text.is_empty(), "{kind}");
        if kind == "inputText" {
            assert_eq!(entries[0].text, "Synthetic output");
        }
        if kind == "inputImage" {
            let decoded = ToolOutput::decode(&entries[0].text).expect("decode image tool output");
            assert_eq!(decoded.parts.first().map(|p| p.kind), Some(ToolOutputKind::Image));
        }
    }
}

fn check_model_verification_schema_remains_visible(schema: &Path) {
    let root: Value = serde_json::from_slice(
        &fs::read(schema.join("v2/ModelVerificationNotification.json"))
            .expect("read v2/ModelVerificationNotification.json"),
    )
    .expect("parse ModelVerificationNotification.json");
    let required: HashSet<&str> = root["required"]
        .as_array()
        .expect("required")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    for field in ["threadId", "turnId", "verifications"] {
        assert!(required.contains(field), "missing required field {field}");
    }
    let variants = root
        .pointer("/definitions/ModelVerification/enum")
        .and_then(Value::as_array)
        .expect("ModelVerification.enum");
    assert!(!variants.is_empty());
    for variant in variants {
        let name = variant.as_str().expect("variant string");
        let arr = json!([name]);
        let entries = CodexItemOutput::verifications(Some(&arr));
        assert_eq!(
            entries.len(),
            1,
            "Installed verification variant disappeared: {name}"
        );
        assert_eq!(entries[0].kind, TranscriptItemKind::Status);
        assert!(!entries[0].text.is_empty(), "{name}");
        if name == "trustedAccessForCyber" {
            assert_eq!(
                entries[0].text,
                "Codex requires Trusted Access for Cyber verification for this turn."
            );
        }
    }
    let unknown_arr = json!(["futureVerification"]);
    let unknown = CodexItemOutput::verifications(Some(&unknown_arr));
    assert_eq!(
        unknown.iter().map(|e| e.text.as_str()).collect::<Vec<_>>(),
        vec!["Codex reported an unsupported model verification requirement (futureVerification)."]
    );
}

#[test]
fn installed_model_metadata_without_generation() {
    if std::env::var("ROTA_PROTOCOL_CHECK").ok().as_deref() != Some("1") {
        return;
    }
    let export_path = std::env::var("ROTA_HARNESS_REVIEW_OUTPUT").ok();
    let mut catalogs = Map::new();
    for harness in Harness::AGENTS {
        let Some(path) = configured_or_installed_executable(harness) else {
            continue;
        };
        let models: Vec<ModelOption> = if harness == Harness::Antigravity {
            let (models, complete) = AntigravityCatalog::read_result(&path);
            assert!(complete, "Some Antigravity model families could not be verified");
            models
        } else {
            ModelCatalog::models(harness, &path)
        };
        assert!(!models.is_empty(), "{} metadata unavailable", harness.title());
        let ids: HashSet<&str> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids.len(), models.len(), "{} duplicate model IDs", harness.title());
        assert!(
            models.iter().any(|m| m.is_default),
            "{} did not resolve its default model",
            harness.title()
        );
        if export_path.is_some() {
            let mut sorted = models;
            sorted.sort_by(|a, b| a.id.cmp(&b.id));
            let ver = ExecutableDiscovery::version(&path, Duration::from_secs(5))
                .unwrap_or_else(|| "unreported".into());
            catalogs.insert(
                harness.as_str().into(),
                json!({ "models": sorted, "version": ver }),
            );
        }
    }
    if let Some(output) = export_path {
        let bytes = serde_json::to_vec_pretty(&Value::Object(catalogs)).expect("serialize catalog export");
        atomic_write_bytes(Path::new(&output), &bytes).expect("write ROTA_HARNESS_REVIEW_OUTPUT");
    }
}
