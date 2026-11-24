mod format;
mod mcp;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use jiff::tz::TimeZone;
use rota_core::{
    CliArguments, ControlCli, ControlClient, ControlError, ControlInterface, ControlServer, QuestionHook,
};
use rota_platform::{bundle_short_version, launch_rota_background};
use serde_json::{Value, json};

use crate::format::{USAGE, format_human, format_sorted_pretty_json};
use crate::mcp::McpServer;

fn request_control(method: &str, params: Value) -> Result<Value, ControlError> {
    let socket = ControlServer::standard_socket();
    let timeout = Duration::from_secs(30);
    match ControlClient::call(method, params.clone(), &socket, timeout) {
        Ok(res) => Ok(res),
        Err(err) if err.is_not_running() => {
            let data_dir = std::env::var("ROTA_DATA_DIR").ok();
            launch_rota_background(data_dir.as_deref()).map_err(ControlError::new)?;
            let deadline = Instant::now() + Duration::from_secs(20);
            while Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(500));
                if let Ok(res) = ControlClient::call(method, params.clone(), &socket, timeout) {
                    return Ok(res);
                }
            }
            ControlClient::call(method, params, &socket, timeout)
        }
        Err(err) => Err(err),
    }
}

fn run_cli(raw: &[String]) -> Result<(), String> {
    let arguments = CliArguments::parse(raw).map_err(|e| e.message)?;
    if arguments.flags.contains("version") {
        println!("{}", bundle_short_version());
        return Ok(());
    }
    let Some(command) = arguments.positional.first().map(String::as_str) else {
        println!("{USAGE}");
        return Ok(());
    };
    if command == "version" {
        println!("{}", bundle_short_version());
        return Ok(());
    }
    if command == "help" || arguments.flags.contains("help") {
        println!("{USAGE}");
        return Ok(());
    }
    if command == "question-hook" {
        return QuestionHook::run();
    }
    let env: HashMap<String, String> = std::env::vars().collect();
    if command == "mcp" {
        let stdin = std::io::stdin();
        let stdout = std::io::stdout();
        let server = McpServer::new(request_control, env);
        server.serve(stdin.lock(), stdout.lock());
        return Ok(());
    }
    if command == "tools" {
        let tools: Vec<Value> = ControlInterface::tools()
            .into_iter()
            .map(|tool| {
                let mut schema = tool.mcp_schema();
                if let Some(obj) = schema.as_object_mut() {
                    obj.insert("command".into(), json!(tool.command));
                    obj.insert("method".into(), json!(tool.method.as_str()));
                }
                schema
            })
            .collect();
        println!("{}", format_sorted_pretty_json(&Value::Array(tools)));
        return Ok(());
    }

    let canonical = ControlCli::canonical_command(command);
    let (method, params) = ControlCli::request(command, &arguments, &env).map_err(|e| e.message)?;
    let result = request_control(&method, params).map_err(|e| e.message)?;
    if arguments.flags.contains("json") {
        println!("{}", format_sorted_pretty_json(&result));
    } else {
        println!("{}", format_human(&result, canonical, &TimeZone::system()));
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(err) = run_cli(&args) {
        eprintln!("rota: {err}");
        std::process::exit(1);
    }
}
