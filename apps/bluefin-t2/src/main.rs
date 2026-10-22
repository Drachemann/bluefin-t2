// SPDX-License-Identifier: GPL-3.0-or-later
//! bluefin-t2 — `report`, the machine's own answer to "what works here".
//!
//! The report asserts against the model's expectation set
//! (`/usr/share/bluefin-t2/models.d/<ProductName>.toml`), never against prose. Its `--json`
//! output is the contract consumed by the hub and the Tier 2 smoke test; the schema is
//! `docs/report-schema.md`.
//!
//! Exit codes are part of the contract:
//!   0  supported model, every required check passes
//!   1  supported model, something required is missing or failed
//!   2  the model is not in the supported set — a soft verdict, never a refusal
//!
//! `--root DIR` reads facts under DIR instead of `/`, which is how Tier 0 feeds fixtures.
//! In that mode no runtime command (mokutil, systemctl, uname) is executed: those checks
//! report `unknown` instead of pretending.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

mod hub;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const MODELS_REL: &str = "usr/share/bluefin-t2/models.d";
const FIRMWARE_STATE_REL: &str = "var/lib/bluefin-t2/firmware.state";
const OUR_CERT: &str = "/etc/pki/akmods/certs/bluefin-t2.der";

const USAGE: &str = "\
bluefin-t2 — T2 hardware report and hub

USAGE:
    bluefin-t2                              open the hub (nine read-only pages)
    bluefin-t2 report [--json | --markdown] [--root DIR]
    bluefin-t2 --check-gui [--root DIR]     build the hub's page model, no display needed
    bluefin-t2 --version
    bluefin-t2 --help

OPTIONS:
    --json        machine-readable output; the schema is docs/report-schema.md
    --markdown    the bug-report body (design §7)
    --root DIR    read facts under DIR instead of / (Tier 0 fixtures)
";

#[derive(Default)]
struct Model {
    status: String,
    loaded: Vec<String>,
    unbound: Vec<String>,
    absent: Vec<String>,
    unmeasured: Vec<String>,
}

#[derive(Default)]
struct Modules {
    present: Vec<String>,
    missing: Vec<String>,
    unexpected: Vec<String>,
    unbound_ok: Vec<String>,
    absent_ok: Vec<String>,
    unmeasured: Vec<String>,
}

enum SecureBoot {
    OnEnrolled,
    OnNotEnrolled,
    OnUnknown,
    Off,
    Unknown,
}

#[derive(Default)]
struct Firmware {
    state: String,
    detail: String,
}

struct Report {
    product: Option<String>,
    model: Option<Model>,
    model_path: Option<PathBuf>,
    kernel: Option<String>,
    image: Option<String>,
    modules: Modules,
    firmware: Firmware,
    secure_boot: SecureBoot,
    failed_units: Option<Vec<String>>,
    problems: Vec<String>,
    warnings: Vec<String>,
    exit_code: i32,
    verdict: &'static str,
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("report") => run_report(&args[1..]),
        Some("--check-gui") => hub::check(&args[1..]),
        Some("hub") | None => hub::run(None),
        Some("--version") | Some("-V") => {
            println!("bluefin-t2 {VERSION}");
            ExitCode::SUCCESS
        }
        Some("--help") | Some("-h") => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!("bluefin-t2: unknown subcommand '{other}'");
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn run_report(args: &[String]) -> ExitCode {
    let mut json = false;
    let mut markdown = false;
    let mut root = PathBuf::from("/");

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => json = true,
            "--markdown" => markdown = true,
            "--root" => {
                i += 1;
                match args.get(i) {
                    Some(dir) => root = PathBuf::from(dir),
                    None => {
                        eprintln!("bluefin-t2 report: --root needs a directory");
                        return ExitCode::from(2);
                    }
                }
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("bluefin-t2 report: unknown argument '{other}'");
                eprint!("{USAGE}");
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let report = collect(&root);

    if json {
        print!("{}", render_json(&report));
    } else if markdown {
        print!("{}", render_markdown(&report));
    } else {
        print!("{}", render_human(&report));
    }

    match report.exit_code {
        0 => ExitCode::SUCCESS,
        1 => ExitCode::from(1),
        _ => ExitCode::from(2),
    }
}

fn collect(root: &Path) -> Report {
    let product = read_trim(&root.join("sys/devices/virtual/dmi/id/product_name"));

    let mut report = Report {
        product: product.clone(),
        model: None,
        model_path: None,
        kernel: None,
        image: None,
        modules: Modules::default(),
        firmware: Firmware {
            state: "unknown".to_string(),
            detail: String::new(),
        },
        secure_boot: SecureBoot::Unknown,
        failed_units: None,
        problems: Vec::new(),
        warnings: Vec::new(),
        exit_code: 2,
        verdict: "unsupported",
    };

    // The model's expectation set decides everything below it.
    if let Some(name) = &product {
        let path = root.join(MODELS_REL).join(format!("{name}.toml"));
        if let Some(model) = parse_model(&path) {
            report.model_path = Some(path);
            report.model = Some(model);
        }
    }

    report.kernel = read_trim(&root.join("proc/sys/kernel/osrelease")).or_else(|| {
        if root == Path::new("/") {
            Command::new("uname")
                .arg("-r")
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        } else {
            None
        }
    });
    report.image = read_os_release(&root.join("etc/os-release"));

    if report.model.is_some() {
        report.modules = check_modules(root, report.model.as_ref().unwrap());
        report.firmware = check_firmware(root);
        report.secure_boot = check_secure_boot(root);
        report.failed_units = check_failed_units(root);

        let m = report.model.as_ref().unwrap();
        if m.status == "validation-set" {
            report.warnings.push(format!(
                "{} is in the validation set: no recorded Tier 2 run yet, so nothing here is a published hardware claim",
                product.clone().unwrap_or_default()
            ));
        } else if m.status == "argument" {
            report.warnings.push(format!(
                "{} is supported by the written argument, not by a recorded Tier 2 run",
                product.clone().unwrap_or_default()
            ));
        }
        if !report.modules.unmeasured.is_empty() {
            report.warnings.push(format!(
                "untested on this model: {}",
                report.modules.unmeasured.join(", ")
            ));
        }
        if !report.modules.missing.is_empty() {
            report.problems.push(format!(
                "module(s) not loaded: {}",
                report.modules.missing.join(", ")
            ));
        }
        if !report.modules.unexpected.is_empty() {
            report.problems.push(format!(
                "module(s) loaded that this model expects absent: {}",
                report.modules.unexpected.join(", ")
            ));
        }
        if report.firmware.state != "imported" {
            report.problems.push(format!(
                "firmware payload not imported — {}",
                if report.firmware.detail.is_empty() {
                    "the per-machine Apple files are absent from /var/lib/firmware".to_string()
                } else {
                    report.firmware.detail.clone()
                }
            ));
        }
        match report.secure_boot {
            SecureBoot::OnNotEnrolled => report.problems.push(
                "Secure Boot is on and the bluefin-t2 key is not enrolled — the signed modules will not load; enroll the DER from /etc/pki/akmods/certs/".to_string(),
            ),
            SecureBoot::OnUnknown | SecureBoot::Unknown => report
                .warnings
                .push("Secure Boot state could not be read".to_string()),
            SecureBoot::Off => report
                .warnings
                .push("Secure Boot is off; the signed modules load without a MOK check".to_string()),
            SecureBoot::OnEnrolled => {}
        }
        if let Some(failed) = &report.failed_units {
            if !failed.is_empty() {
                report
                    .problems
                    .push(format!("failed unit(s): {}", failed.join(", ")));
            }
        }

        report.exit_code = if report.problems.is_empty() { 0 } else { 1 };
        report.verdict = if report.problems.is_empty() { "ok" } else { "not-ok" };
    } else {
        report.exit_code = 2;
        report.verdict = "unsupported";
        match &product {
            Some(name) => report.warnings.push(format!(
                "{name} is not in the supported set; the report is for an issue, not a verdict on the project"
            )),
            None => report
                .warnings
                .push("this machine reports no DMI product name".to_string()),
        }
    }

    report
}

// ---------------------------------------------------------------- input parsing

fn read_trim(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn read_os_release(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    let mut version_id = None;
    let mut version = None;
    let mut pretty = None;
    for line in text.lines() {
        let (k, v) = match line.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        let v = v.trim().trim_matches('"').to_string();
        match k.trim() {
            "VERSION" => version = Some(v),
            "VERSION_ID" => version_id = Some(v),
            "PRETTY_NAME" => pretty = Some(v),
            _ => {}
        }
    }
    version.or(version_id).or(pretty)
}

fn parse_model(path: &Path) -> Option<Model> {
    let raw = fs::read_to_string(path).ok()?;
    let cleaned: String = raw
        .lines()
        .map(|l| l.split('#').next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n");
    let status = scalar(&cleaned, "status").unwrap_or_else(|| "unknown".to_string());
    let model = Model {
        status,
        loaded: array(&cleaned, "expected_loaded"),
        unbound: array(&cleaned, "expected_unbound"),
        absent: array(&cleaned, "expected_absent"),
        unmeasured: array(&cleaned, "unmeasured"),
    };
    if model.loaded.is_empty() && model.unbound.is_empty() && model.absent.is_empty() {
        return None;
    }
    Some(model)
}

/// Values inside `key = [ ... ]`, including arrays that span lines. The models.d files are
/// written by hand, so this is deliberately tolerant: comments are already stripped, quote
/// pairs are the only structure that matters.
fn array(cleaned: &str, key: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut collecting = false;
    for line in cleaned.lines() {
        let t = line.trim();
        if !collecting {
            if !(t.starts_with(key) && t.contains('=')) {
                continue;
            }
            collecting = true;
        }
        for (idx, part) in t.split('"').enumerate() {
            if idx % 2 == 1 && !part.is_empty() {
                out.push(part.to_string());
            }
        }
        if t.contains(']') {
            break;
        }
    }
    out
}

fn scalar(cleaned: &str, key: &str) -> Option<String> {
    for line in cleaned.lines() {
        let t = line.trim();
        let rest = match t.strip_prefix(key) {
            Some(r) => r.trim_start(),
            None => continue,
        };
        let rest = match rest.strip_prefix('=') {
            Some(r) => r.trim(),
            None => continue,
        };
        return Some(rest.trim_matches('"').to_string());
    }
    None
}

// ---------------------------------------------------------------- checks

fn loaded(root: &Path, module: &str) -> bool {
    root.join("sys/module").join(module).is_dir()
}

fn check_modules(root: &Path, model: &Model) -> Modules {
    let mut m = Modules::default();
    for name in &model.loaded {
        if loaded(root, name) {
            m.present.push(name.clone());
        } else {
            m.missing.push(name.clone());
        }
    }
    for name in &model.unbound {
        if loaded(root, name) {
            m.unbound_ok.push(name.clone());
        } else {
            m.missing.push(name.clone());
        }
    }
    for name in &model.absent {
        if loaded(root, name) {
            m.unexpected.push(name.clone());
        } else {
            m.absent_ok.push(name.clone());
        }
    }
    m.unmeasured = model.unmeasured.clone();
    m
}

fn check_firmware(root: &Path) -> Firmware {
    let state = root.join(FIRMWARE_STATE_REL);
    match fs::read_to_string(&state) {
        Ok(text) => {
            let detail = text
                .lines()
                .find(|l| l.starts_with("payload_sha256="))
                .map(|l| l.trim_start_matches("payload_sha256=").to_string())
                .unwrap_or_default();
            Firmware {
                state: "imported".to_string(),
                detail,
            }
        }
        Err(_) => Firmware {
            state: "absent".to_string(),
            detail: String::new(),
        },
    }
}

fn run_ok(cmd: &str, args: &[&str]) -> Option<std::process::Output> {
    Command::new(cmd).args(args).output().ok()
}

fn check_secure_boot(root: &Path) -> SecureBoot {
    if root != Path::new("/") {
        return SecureBoot::Unknown;
    }
    let out = match run_ok("mokutil", &["--sb-state"]) {
        Some(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_lowercase(),
        _ => return SecureBoot::Unknown,
    };
    if out.contains("disabled") {
        return SecureBoot::Off;
    }
    if !out.contains("enabled") {
        return SecureBoot::Unknown;
    }
    // Secure Boot is on: the modules only load if our key is enrolled.
    if !Path::new(OUR_CERT).exists() {
        return SecureBoot::OnUnknown;
    }
    match run_ok("mokutil", &["--test-key", OUR_CERT]) {
        Some(o) if o.status.success() => SecureBoot::OnEnrolled,
        Some(_) => SecureBoot::OnNotEnrolled,
        None => SecureBoot::OnUnknown,
    }
}

fn check_failed_units(root: &Path) -> Option<Vec<String>> {
    if root != Path::new("/") {
        return None;
    }
    let out = run_ok("systemctl", &["--failed", "--no-legend", "--plain"])?;
    if !out.status.success() {
        return None;
    }
    let units = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .filter(|s| !s.is_empty())
        .collect();
    Some(units)
}

// ---------------------------------------------------------------- output

fn sb_json(sb: &SecureBoot) -> &'static str {
    match sb {
        SecureBoot::OnEnrolled => "on-enrolled",
        SecureBoot::OnNotEnrolled => "on-not-enrolled",
        SecureBoot::OnUnknown => "on-unknown",
        SecureBoot::Off => "off",
        SecureBoot::Unknown => "unknown",
    }
}

fn sb_human(sb: &SecureBoot) -> &'static str {
    match sb {
        SecureBoot::OnEnrolled => "on, bluefin-t2 key enrolled",
        SecureBoot::OnNotEnrolled => "on, bluefin-t2 key NOT enrolled",
        SecureBoot::OnUnknown => "on, key state unknown",
        SecureBoot::Off => "off",
        SecureBoot::Unknown => "unknown",
    }
}

fn json_string(v: &str) -> String {
    let mut out = String::with_capacity(v.len() + 2);
    out.push('"');
    for c in v.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_array(v: &[String]) -> String {
    let items: Vec<String> = v.iter().map(|s| json_string(s)).collect();
    format!("[{}]", items.join(", "))
}

fn render_json(r: &Report) -> String {
    let model = r.model.as_ref();
    let class = model.map(|m| m.status.as_str()).unwrap_or("unknown");
    let model_file = r
        .model_path
        .as_ref()
        .map(|p| json_string(&p.to_string_lossy()))
        .unwrap_or_else(|| "null".to_string());
    let failed = match &r.failed_units {
        Some(v) => json_array(v),
        None => "null".to_string(),
    };
    let kernel = r
        .kernel
        .as_ref()
        .map(|s| json_string(s))
        .unwrap_or_else(|| "null".to_string());
    let image = r
        .image
        .as_ref()
        .map(|s| json_string(s))
        .unwrap_or_else(|| "null".to_string());
    let product = r
        .product
        .as_ref()
        .map(|s| json_string(s))
        .unwrap_or_else(|| "null".to_string());

    format!(
        concat!(
            "{{\n",
            "  \"schema\": 1,\n",
            "  \"tool\": \"bluefin-t2\",\n",
            "  \"version\": {version},\n",
            "  \"verdict\": {verdict},\n",
            "  \"exit_code\": {exit},\n",
            "  \"product_name\": {product},\n",
            "  \"model\": {{\"class\": {class}, \"file\": {model_file}}},\n",
            "  \"system\": {{\"kernel\": {kernel}, \"image\": {image}}},\n",
            "  \"secure_boot\": {{\"state\": {sb}}},\n",
            "  \"modules\": {{\n",
            "    \"present\": {present},\n",
            "    \"missing\": {missing},\n",
            "    \"unexpected\": {unexpected},\n",
            "    \"unbound\": {unbound},\n",
            "    \"unmeasured\": {unmeasured}\n",
            "  }},\n",
            "  \"firmware\": {{\"state\": {fw_state}, \"detail\": {fw_detail}}},\n",
            "  \"failed_units\": {failed},\n",
            "  \"problems\": {problems},\n",
            "  \"warnings\": {warnings}\n",
            "}}\n"
        ),
        version = json_string(VERSION),
        verdict = json_string(r.verdict),
        exit = r.exit_code,
        product = product,
        class = json_string(class),
        model_file = model_file,
        kernel = kernel,
        image = image,
        sb = json_string(sb_json(&r.secure_boot)),
        present = json_array(&r.modules.present),
        missing = json_array(&r.modules.missing),
        unexpected = json_array(&r.modules.unexpected),
        unbound = json_array(&r.modules.unbound_ok),
        unmeasured = json_array(&r.modules.unmeasured),
        fw_state = json_string(&r.firmware.state),
        fw_detail = json_string(&r.firmware.detail),
        failed = failed,
        problems = json_array(&r.problems),
        warnings = json_array(&r.warnings),
    )
}

fn render_human(r: &Report) -> String {
    let mut s = String::new();
    let model = r
        .product
        .clone()
        .unwrap_or_else(|| "unknown machine".to_string());
    let class = r.model.as_ref().map(|m| m.status.as_str()).unwrap_or("unknown");
    s.push_str(&format!("bluefin-t2 report — {model} ({class})\n"));
    if let Some(k) = &r.kernel {
        s.push_str(&format!("  kernel: {k}\n"));
    }
    if let Some(i) = &r.image {
        s.push_str(&format!("  image:  {i}\n"));
    }
    s.push_str(&format!("  secure boot: {}\n", sb_human(&r.secure_boot)));
    if r.model.is_some() {
        s.push_str(&format!(
            "  modules: {} loaded, {} unbound as expected, {} absent as expected, {} missing, {} unexpected\n",
            r.modules.present.len(),
            r.modules.unbound_ok.len(),
            r.modules.absent_ok.len(),
            r.modules.missing.len(),
            r.modules.unexpected.len()
        ));
        s.push_str(&format!(
            "  firmware: {}{}\n",
            r.firmware.state,
            if r.firmware.detail.is_empty() {
                String::new()
            } else {
                format!(" ({})", r.firmware.detail)
            }
        ));
        match &r.failed_units {
            Some(v) if v.is_empty() => s.push_str("  failed units: none\n"),
            Some(v) => s.push_str(&format!("  failed units: {}\n", v.join(", "))),
            None => s.push_str("  failed units: unknown\n"),
        }
        if !r.modules.unmeasured.is_empty() {
            s.push_str(&format!(
                "  untested on this model: {}\n",
                r.modules.unmeasured.join(", ")
            ));
        }
    }
    for w in &r.warnings {
        s.push_str(&format!("  warning: {w}\n"));
    }
    for p in &r.problems {
        s.push_str(&format!("  NOT OK:  {p}\n"));
    }
    s.push_str(&format!(
        "verdict: {} (exit {})\n",
        r.verdict, r.exit_code
    ));
    s
}

fn render_markdown(r: &Report) -> String {
    let mut s = String::new();
    let model = r
        .product
        .clone()
        .unwrap_or_else(|| "unknown machine".to_string());
    let class = r.model.as_ref().map(|m| m.status.as_str()).unwrap_or("unknown");
    s.push_str("# bluefin-t2 report\n\n");
    s.push_str(&format!("- **Machine:** {model} ({class})\n"));
    if let Some(k) = &r.kernel {
        s.push_str(&format!("- **Kernel:** `{k}`\n"));
    }
    if let Some(i) = &r.image {
        s.push_str(&format!("- **Image:** {i}\n"));
    }
    s.push_str(&format!(
        "- **Secure Boot:** {}\n",
        sb_human(&r.secure_boot)
    ));
    s.push_str(&format!(
        "- **Firmware payload:** {}\n",
        r.firmware.state
    ));
    s.push_str(&format!(
        "- **Verdict:** {} (exit {})\n\n",
        r.verdict, r.exit_code
    ));

    if r.model.is_some() {
        s.push_str("## Modules\n\n");
        s.push_str(&format!(
            "- loaded as expected: {}\n",
            r.modules.present.len()
        ));
        s.push_str(&format!(
            "- loaded, unbound as expected: {}\n",
            r.modules.unbound_ok.join(", ")
        ));
        s.push_str(&format!(
            "- not loaded, as expected: {}\n",
            r.modules.absent_ok.join(", ")
        ));
        if !r.modules.unmeasured.is_empty() {
            s.push_str(&format!(
                "- untested on this model: {}\n",
                r.modules.unmeasured.join(", ")
            ));
        }
        if !r.modules.missing.is_empty() {
            s.push_str(&format!("- **missing:** {}\n", r.modules.missing.join(", ")));
        }
        if !r.modules.unexpected.is_empty() {
            s.push_str(&format!(
                "- **unexpectedly loaded:** {}\n",
                r.modules.unexpected.join(", ")
            ));
        }
        s.push('\n');
    }

    if !r.warnings.is_empty() {
        s.push_str("## Warnings\n\n");
        for w in &r.warnings {
            s.push_str(&format!("- {w}\n"));
        }
        s.push('\n');
    }
    if !r.problems.is_empty() {
        s.push_str("## Not OK\n\n");
        for p in &r.problems {
            s.push_str(&format!("- {p}\n"));
        }
        s.push('\n');
    }
    s
}
