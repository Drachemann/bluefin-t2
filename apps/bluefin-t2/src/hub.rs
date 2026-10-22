// SPDX-License-Identifier: GPL-3.0-or-later
//! The hub — read-only status pages over `bluefin-t2 report --json`.
//!
//! The hub reads the documented JSON contract (`docs/report-schema.md`) and nothing else:
//! no page executes a privileged command, parses `/sys` itself, or asserts a fact the
//! report did not already assert. That is deliberate — every claim exists once, in the
//! report, and the hub is a view of it. Pages whose subject is not in the contract say so
//! and name the component that owns it, rather than inventing a status.
//!
//! `--check-gui` builds the same page model with no display and no GTK initialisation, so
//! Tier 0 can prove the contract is honoured without a desktop session. The window itself
//! is verified on hardware (Tier 2/3).

use std::cell::{Cell, RefCell};
use std::process::{Command, ExitCode};
use std::rc::Rc;

use libadwaita::prelude::*;
use gtk4::Orientation;
use serde_json::Value;

const PAGES: usize = 9;
const PAGE_TITLES: [&str; PAGES] = [
    "Overview",
    "Kernel & Modules",
    "Firmware",
    "Performance",
    "Display",
    "Network",
    "Users",
    "Logs",
    "Advanced",
];

pub struct Row {
    pub label: String,
    pub value: String,
}

pub struct Page {
    pub title: &'static str,
    pub rows: Vec<Row>,
}

fn row(label: &str, value: String) -> Row {
    Row { label: label.to_string(), value }
}

fn text(doc: &Value, path: &[&str]) -> String {
    let mut cur = doc;
    for key in path {
        match cur.get(*key) {
            Some(v) => cur = v,
            None => return "—".to_string(),
        }
    }
    match cur {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "—".to_string(),
        Value::Array(a) => {
            let parts: Vec<String> = a
                .iter()
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .collect();
            if parts.is_empty() { "none".to_string() } else { parts.join(", ") }
        }
        other => other.to_string(),
    }
}

/// Run the report and return its document. Exit codes 0/1/2 all carry a valid document;
/// anything else is a contract failure, not a verdict.
fn load(root: &Option<String>) -> Result<Value, String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find own binary: {e}"))?;
    let mut cmd = Command::new(exe);
    cmd.arg("report").arg("--json");
    if let Some(dir) = root {
        cmd.arg("--root").arg(dir);
    }
    let out = cmd.output().map_err(|e| format!("cannot run report: {e}"))?;
    let code = out.status.code().unwrap_or(-1);
    if !matches!(code, 0 | 1 | 2) {
        return Err(format!("report exited {code}"));
    }
    let doc: Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("report printed invalid JSON: {e}"))?;
    if doc.get("schema").and_then(Value::as_i64) != Some(1) {
        return Err("report schema is not 1".to_string());
    }
    Ok(doc)
}

pub fn pages(doc: &Value) -> Vec<Page> {
    vec![
        Page {
            title: "Overview",
            rows: vec![
                row("Verdict", text(doc, &["verdict"])),
                row(
                    "Model",
                    format!("{} — {}", text(doc, &["product_name"]), text(doc, &["model", "class"])),
                ),
                row("Kernel", text(doc, &["system", "kernel"])),
                row("Image", text(doc, &["system", "image"])),
                row("Secure Boot", text(doc, &["secure_boot", "state"])),
                row("Problems", text(doc, &["problems"])),
                row("Warnings", text(doc, &["warnings"])),
            ],
        },
        Page {
            title: "Kernel & Modules",
            rows: vec![
                row("Kernel", text(doc, &["system", "kernel"])),
                row("Loaded", text(doc, &["modules", "present"])),
                row("Missing", text(doc, &["modules", "missing"])),
                row("Must not be loaded", text(doc, &["modules", "unexpected"])),
                row("Unbound (loaded is enough)", text(doc, &["modules", "unbound"])),
                row("Untested on this model", text(doc, &["modules", "unmeasured"])),
            ],
        },
        Page {
            title: "Firmware",
            rows: vec![
                row("State", text(doc, &["firmware", "state"])),
                row("Detail", text(doc, &["firmware", "detail"])),
                row(
                    "Channel",
                    "/var/lib/firmware, selected by firmware_class.path=. Apple firmware is per-machine and never part of the image.".to_string(),
                ),
            ],
        },
        Page {
            title: "Performance",
            rows: vec![
                row(
                    "Not in the report",
                    "The report is a hardware verdict, not a power reading. Fan curves are owned by T2 Fan Control; power limits by T2 Power Tune.".to_string(),
                ),
            ],
        },
        Page {
            title: "Display",
            rows: vec![
                row(
                    "Not in the report",
                    "The Touch Bar is owned by kait2en-touchbar.service (user) and its attach unit, which runs only while the user unit is enabled globally.".to_string(),
                ),
            ],
        },
        Page {
            title: "Network",
            rows: vec![
                row(
                    "Not in the report",
                    "Wi-Fi and Bluetooth depend on the imported firmware; the T2 AVE daemon is kait2en-t2-remote.service.".to_string(),
                ),
            ],
        },
        Page {
            title: "Users",
            rows: vec![
                row(
                    "Not in the report",
                    "Touch ID goes through fprintd and PAM; authselect reports whether with-fingerprint is enabled.".to_string(),
                ),
            ],
        },
        Page {
            title: "Logs",
            rows: vec![
                row("Failed units", text(doc, &["failed_units"])),
                row(
                    "Where to look",
                    "journalctl -b -p err for this boot; bluefin-t2 report --markdown produces the bug-report body.".to_string(),
                ),
            ],
        },
        Page {
            title: "Advanced",
            rows: vec![
                row("Schema", text(doc, &["schema"])),
                row("Tool", format!("{} {}", text(doc, &["tool"]), text(doc, &["version"]))),
                row("Model file", text(doc, &["model", "file"])),
                row(
                    "Contract",
                    "This window renders report --json only. docs/report-schema.md defines every field; MODELS.md defines the model statuses.".to_string(),
                ),
            ],
        },
    ]
}

fn clear_children(content: &gtk4::Box) {
    while let Some(child) = content.first_child() {
        content.remove(&child);
    }
}

fn show(content: &gtk4::Box, doc: Option<&Value>, index: usize) {
    clear_children(content);
    let Some(doc) = doc else {
        let label = gtk4::Label::new(Some("the report could not be read"));
        label.set_xalign(0.0);
        content.append(&label);
        return;
    };
    let pages = pages(doc);
    let Some(page) = pages.get(index) else {
        return;
    };
    let title = gtk4::Label::new(Some(page.title));
    title.set_xalign(0.0);
    title.add_css_class("title-2");
    content.append(&title);

    let grid = gtk4::Grid::new();
    grid.set_row_spacing(10);
    grid.set_column_spacing(28);
    for (i, r) in page.rows.iter().enumerate() {
        let label = gtk4::Label::new(Some(&r.label));
        label.set_xalign(0.0);
        label.set_valign(gtk4::Align::Start);
        label.add_css_class("dim-label");
        let value = gtk4::Label::new(Some(&r.value));
        value.set_xalign(0.0);
        value.set_hexpand(true);
        value.set_wrap(true);
        value.set_selectable(true);
        value.set_valign(gtk4::Align::Start);
        grid.attach(&label, 0, i as i32, 1, 1);
        grid.attach(&value, 1, i as i32, 1, 1);
    }
    content.append(&grid);
}

fn build_ui(app: &libadwaita::Application, root: Option<String>) {
    let window = libadwaita::ApplicationWindow::builder()
        .application(app)
        .title("bluefin-t2")
        .default_width(980)
        .default_height(640)
        .build();

    let header = gtk4::HeaderBar::new();
    let refresh = gtk4::Button::with_label("Refresh");
    header.pack_end(&refresh);

    let sidebar = gtk4::ListBox::new();
    sidebar.set_width_request(230);
    sidebar.add_css_class("navigation-sidebar");
    sidebar.set_selection_mode(gtk4::SelectionMode::Single);

    let content = gtk4::Box::new(Orientation::Vertical, 12);
    content.set_margin_top(18);
    content.set_margin_bottom(18);
    content.set_margin_start(22);
    content.set_margin_end(22);
    let scroll = gtk4::ScrolledWindow::builder()
        .child(&content)
        .vexpand(true)
        .hexpand(true)
        .build();

    let body = gtk4::Box::new(Orientation::Horizontal, 0);
    body.append(&sidebar);
    body.append(&gtk4::Separator::new(Orientation::Vertical));
    body.append(&scroll);

    let root_box = gtk4::Box::new(Orientation::Vertical, 0);
    root_box.append(&header);
    root_box.append(&body);
    window.set_content(Some(&root_box));

    let doc: Rc<RefCell<Option<Value>>> = Rc::new(RefCell::new(load(&root).ok()));
    let current: Rc<Cell<usize>> = Rc::new(Cell::new(0));

    for title in PAGE_TITLES {
        let label = gtk4::Label::new(Some(title));
        label.set_xalign(0.0);
        label.set_margin_top(8);
        label.set_margin_bottom(8);
        label.set_margin_start(12);
        label.set_margin_end(12);
        sidebar.append(&label);
    }

    {
        let content = content.clone();
        let doc = doc.clone();
        let current = current.clone();
        sidebar.connect_row_selected(move |_, selected| {
            if let Some(selected) = selected {
                let index = selected.index() as usize;
                current.set(index);
                show(&content, doc.borrow().as_ref(), index);
            }
        });
    }
    {
        let content = content.clone();
        let doc = doc.clone();
        let current = current.clone();
        let refresh_root = root.clone();
        refresh.connect_clicked(move |_| {
            if let Ok(fresh) = load(&refresh_root) {
                *doc.borrow_mut() = Some(fresh);
            }
            show(&content, doc.borrow().as_ref(), current.get());
        });
    }

    if let Some(first) = sidebar.row_at_index(0) {
        sidebar.select_row(Some(&first));
    }
    window.present();
}

pub fn run(root: Option<String>) -> ExitCode {
    let app = libadwaita::Application::builder()
        .application_id("org.bluefin_t2.Hub")
        .build();
    app.connect_activate(move |app| build_ui(app, root.clone()));
    app.run();
    ExitCode::SUCCESS
}

/// Headless: build the page model from the report contract and refuse to accept a
/// document that does not produce nine non-empty pages.
pub fn check(args: &[String]) -> ExitCode {
    let mut root: Option<String> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--root" => match iter.next() {
                Some(dir) => root = Some(dir.clone()),
                None => {
                    eprintln!("--check-gui: --root needs a directory");
                    return ExitCode::from(2);
                }
            },
            other => {
                eprintln!("--check-gui: unknown argument '{other}'");
                return ExitCode::from(2);
            }
        }
    }
    match load(&root) {
        Ok(doc) => {
            let pages = pages(&doc);
            if pages.len() != PAGES {
                eprintln!("hub: expected {PAGES} pages, got {}", pages.len());
                return ExitCode::from(2);
            }
            if let Some((page, title)) = pages.iter().zip(PAGE_TITLES).find(|(p, t)| p.title != *t) {
                eprintln!("hub: page title '{}' does not match the sidebar title '{title}'", page.title);
                return ExitCode::from(2);
            }
            if let Some(empty) = pages.iter().find(|p| p.rows.is_empty()) {
                eprintln!("hub: page {} has no rows", empty.title);
                return ExitCode::from(2);
            }
            let rows: usize = pages.iter().map(|p| p.rows.len()).sum();
            println!(
                "hub: {} pages, {} rows, verdict {}",
                pages.len(),
                rows,
                text(&doc, &["verdict"])
            );
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("hub: {err}");
            ExitCode::from(2)
        }
    }
}
