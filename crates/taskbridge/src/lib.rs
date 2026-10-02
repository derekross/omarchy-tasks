//! The logic behind `taskbridge`: turning Taskwarrior's JSON export into the
//! snapshot the Omarchy shell plugin reads, and checking the arguments the
//! plugin sends back for mutations.
//!
//! Everything here is pure so it can be tested with a fixed clock. Running
//! `task` itself lives in `main.rs`.

use chrono::{DateTime, Datelike, Days, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One task as Taskwarrior exports it. Only the fields the plugin shows.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawTask {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub due: Option<String>,
    #[serde(default)]
    pub scheduled: Option<String>,
    #[serde(default)]
    pub wait: Option<String>,
    #[serde(default)]
    pub until: Option<String>,
    #[serde(default)]
    pub entry: Option<String>,
    #[serde(default)]
    pub modified: Option<String>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub recur: Option<String>,
    #[serde(default)]
    pub urgency: f64,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub annotations: Vec<Value>,
    #[serde(default)]
    pub depends: Vec<String>,
    /// Derek's GitLab UDA (uda.gitlab_url in .taskrc); harmless when unset.
    #[serde(default)]
    pub gitlab_url: Option<String>,
}

/// Where a task falls relative to today, by calendar day in the local zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Bucket {
    Overdue,
    Today,
    Tomorrow,
    Week,
    Later,
    None,
}

/// One task as the plugin sees it. Times are epoch milliseconds so QML's
/// `new Date(ms)` takes them directly; `null` when the field is unset.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskOut {
    pub uuid: String,
    pub id: u64,
    pub description: String,
    pub project: String,
    pub priority: String,
    pub tags: Vec<String>,
    pub due_ms: Option<i64>,
    pub scheduled_ms: Option<i64>,
    pub wait_ms: Option<i64>,
    pub entry_ms: Option<i64>,
    pub urgency: f64,
    pub status: String,
    pub annotations: usize,
    /// Annotation texts, oldest first, for the expanded row.
    pub notes: Vec<String>,
    /// Every http(s) URL found in the description, annotations and the
    /// GitLab field, first one first, without duplicates.
    pub links: Vec<String>,
    pub recurring: bool,
    pub active: bool,
    pub blocked: bool,
    pub bucket: Bucket,
    /// Indexes into `Snapshot.filters` of every filter this task matches.
    pub filters: Vec<usize>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    pub pending: usize,
    pub waiting: usize,
    pub overdue: usize,
    pub today: usize,
    pub tomorrow: usize,
    pub week: usize,
    /// Overdue plus due today: what the bar shows by default.
    pub due: usize,
    /// Everything due up to the end of this calendar month, overdue included.
    pub month: usize,
    /// The same through the end of this calendar quarter.
    pub quarter: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCount {
    pub name: String,
    pub pending: usize,
    pub overdue: usize,
}

/// A named filter the panel shows a chip for and the bar can count.
/// Input fields are clamped on the way in and echoed back normalised, so
/// the plugin renders exactly what was applied rather than what it sent.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FilterOut {
    pub name: String,
    /// due | today | week | month | quarter | all
    pub time: String,
    pub projects: Vec<String>,
    pub tags: Vec<String>,
    /// "", "H", "M" or "L".
    pub priority: String,
    /// How `tags` combine: "any" (default) or "all". A task has one
    /// project, so `projects` is always any-of.
    #[serde(rename = "match")]
    pub match_mode: String,
    /// How `priority` matches: "exact" (default) or "atleast".
    pub priority_mode: String,
    /// Tasks in the snapshot this filter matches.
    pub count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub ok: bool,
    pub available: bool,
    pub task_version: String,
    pub generated_ms: i64,
    pub counts: Counts,
    pub projects: Vec<ProjectCount>,
    pub filters: Vec<FilterOut>,
    pub tasks: Vec<TaskOut>,
}

/// Taskwarrior writes timestamps as `20260331T040000Z`.
pub fn parse_ts(value: &str) -> Option<DateTime<Utc>> {
    NaiveDateTime::parse_from_str(value, "%Y%m%dT%H%M%SZ")
        .ok()
        .map(|naive| Utc.from_utc_datetime(&naive))
}

fn ms(value: &Option<String>) -> Option<i64> {
    value.as_deref().and_then(parse_ts).map(|t| t.timestamp_millis())
}

/// Bucket a due date by calendar day, seen from `today` in the local zone.
/// A task due today is "today" all day, not overdue at one minute past
/// midnight the way Taskwarrior's own `+OVERDUE` treats it.
pub fn bucket_for<Tz: TimeZone>(due: Option<DateTime<Utc>>, now: &DateTime<Tz>) -> Bucket {
    let Some(due) = due else { return Bucket::None };
    let today: NaiveDate = now.date_naive();
    let due_day: NaiveDate = due.with_timezone(&now.timezone()).date_naive();
    if due_day < today {
        Bucket::Overdue
    } else if due_day == today {
        Bucket::Today
    } else if Some(due_day) == today.checked_add_days(Days::new(1)) {
        Bucket::Tomorrow
    } else if due_day <= today.checked_add_days(Days::new(7)).unwrap_or(today) {
        Bucket::Week
    } else {
        Bucket::Later
    }
}

/// The time window a filter asks for. Every window keeps what is already
/// late, so "Month" reads as "everything left to do by the end of this
/// month", which is what a person means by it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Window {
    Due,
    Today,
    Week,
    Month,
    Quarter,
    All,
}

impl Window {
    /// Unknown names fall back to `All` and are echoed back as such, so a
    /// typo in a hand-edited settings file shows up in the panel rather
    /// than silently narrowing the list.
    pub fn parse(value: &str) -> Window {
        match value.trim().to_ascii_lowercase().as_str() {
            "due" => Window::Due,
            "today" => Window::Today,
            "week" => Window::Week,
            "month" => Window::Month,
            "quarter" => Window::Quarter,
            _ => Window::All,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Window::Due => "due",
            Window::Today => "today",
            Window::Week => "week",
            Window::Month => "month",
            Window::Quarter => "quarter",
            Window::All => "all",
        }
    }
}

/// The last day of the calendar month `day` falls in.
pub fn end_of_month(day: NaiveDate) -> Option<NaiveDate> {
    let first_of_next = if day.month() == 12 {
        NaiveDate::from_ymd_opt(day.year() + 1, 1, 1)?
    } else {
        NaiveDate::from_ymd_opt(day.year(), day.month() + 1, 1)?
    };
    first_of_next.checked_sub_days(Days::new(1))
}

/// The last day of the calendar quarter `day` falls in.
pub fn end_of_quarter(day: NaiveDate) -> Option<NaiveDate> {
    let end_month = ((day.month() - 1) / 3) * 3 + 3;
    end_of_month(NaiveDate::from_ymd_opt(day.year(), end_month, 1)?)
}

/// Does a due date fall in `window`, seen from `today` in the local zone?
/// A task with no due date matches only `All`.
pub fn in_window<Tz: TimeZone>(due_ms: Option<i64>, now: &DateTime<Tz>, window: Window) -> bool {
    if window == Window::All {
        return true;
    }
    let Some(ms) = due_ms else { return false };
    let Some(due) = Utc.timestamp_millis_opt(ms).single() else { return false };
    let today: NaiveDate = now.date_naive();
    let due_day: NaiveDate = due.with_timezone(&now.timezone()).date_naive();
    if due_day < today {
        return true;
    }
    match window {
        Window::Due => due_day == today,
        Window::Today => due_day <= today.checked_add_days(Days::new(1)).unwrap_or(today),
        Window::Week => due_day <= today.checked_add_days(Days::new(7)).unwrap_or(today),
        Window::Month => end_of_month(today).is_some_and(|end| due_day <= end),
        Window::Quarter => end_of_quarter(today).is_some_and(|end| due_day <= end),
        Window::All => true,
    }
}

fn priority_rank(priority: &str) -> u8 {
    match priority {
        "H" => 3,
        "M" => 2,
        "L" => 1,
        _ => 0,
    }
}

/// Time, projects, tags and priority combine with AND. A task has one
/// project, so `projects` is always any-of; `tags` is any-of unless the
/// filter asks for all of them.
pub fn filter_matches<Tz: TimeZone>(filter: &FilterOut, task: &TaskOut, now: &DateTime<Tz>) -> bool {
    if !in_window(task.due_ms, now, Window::parse(&filter.time)) {
        return false;
    }
    if !filter.projects.is_empty() && !filter.projects.contains(&task.project) {
        return false;
    }
    if !filter.tags.is_empty() {
        let hit = if filter.match_mode == "all" {
            filter.tags.iter().all(|want| task.tags.contains(want))
        } else {
            filter.tags.iter().any(|want| task.tags.contains(want))
        };
        if !hit {
            return false;
        }
    }
    if !filter.priority.is_empty() {
        let wanted = priority_rank(&filter.priority);
        let have = priority_rank(&task.priority);
        let hit = if filter.priority_mode == "atleast" {
            // Unprioritised tasks are not "at least low".
            have > 0 && have >= wanted
        } else {
            task.priority == filter.priority
        };
        if !hit {
            return false;
        }
    }
    true
}

/// The most filters a settings file may define, one per digit key plus a
/// few for the h/l cycle.
pub const MAX_FILTERS: usize = 12;
const MAX_VALUES: usize = 32;
const MAX_VALUE_LEN: usize = 80;
const MAX_NAME_LEN: usize = 40;

/// One filter as the plugin sends it. Every field is optional: a missing or
/// mistyped one is clamped, never refused, because a filter never reaches
/// `task` - it only decides what the panel lists.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FilterIn {
    #[serde(default)]
    name: String,
    #[serde(default)]
    time: String,
    #[serde(default)]
    projects: Vec<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    priority: String,
    #[serde(default, rename = "match")]
    match_mode: String,
    #[serde(default)]
    priority_mode: String,
}

fn clamp_values(values: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for value in values {
        let v = value.trim();
        if v.is_empty() || v.chars().count() > MAX_VALUE_LEN {
            continue;
        }
        if !out.iter().any(|have| have == v) {
            out.push(v.to_string());
        }
        if out.len() >= MAX_VALUES {
            break;
        }
    }
    out
}

fn clamp_name(name: &str, index: usize) -> String {
    let trimmed: String = name.trim().chars().take(MAX_NAME_LEN).collect();
    if trimmed.is_empty() {
        format!("Filter {}", index + 1)
    } else {
        trimmed
    }
}

fn normalise_filter(input: &FilterIn, index: usize) -> FilterOut {
    let priority = match input.priority.trim().to_ascii_uppercase().as_str() {
        "H" => "H",
        "M" => "M",
        "L" => "L",
        _ => "",
    };
    FilterOut {
        name: clamp_name(&input.name, index),
        time: Window::parse(&input.time).as_str().to_string(),
        projects: clamp_values(&input.projects),
        tags: clamp_values(&input.tags),
        priority: priority.to_string(),
        match_mode: if input.match_mode.trim().eq_ignore_ascii_case("all") { "all" } else { "any" }.to_string(),
        priority_mode: if input.priority_mode.trim().eq_ignore_ascii_case("atleast") {
            "atleast"
        } else {
            "exact"
        }
        .to_string(),
        count: 0,
    }
}

/// Filters as the plugin sent them (`--filters <json>`), normalised. An
/// unparseable document yields no filters rather than an error.
pub fn parse_filters(json: &str) -> Vec<FilterOut> {
    let raw: Vec<FilterIn> = serde_json::from_str(json).unwrap_or_default();
    raw.iter().take(MAX_FILTERS).enumerate().map(|(i, f)| normalise_filter(f, i)).collect()
}

/// What the plugin shows when it has no `filters` setting: the chips it has
/// always offered, plus Month and Quarter.
pub fn default_filters() -> Vec<FilterOut> {
    ["Due", "Today", "Week", "Month", "Quarter", "All"]
        .iter()
        .enumerate()
        .map(|(index, name)| FilterOut {
            name: (*name).to_string(),
            time: Window::parse(name).as_str().to_string(),
            match_mode: "any".to_string(),
            priority_mode: "exact".to_string(),
            ..normalise_filter(&FilterIn::default(), index)
        })
        .collect()
}

pub fn to_out<Tz: TimeZone>(raw: &RawTask, now: &DateTime<Tz>) -> TaskOut {
    let due = raw.due.as_deref().and_then(parse_ts);
    let notes: Vec<String> = raw
        .annotations
        .iter()
        .filter_map(|a| a.get("description").and_then(Value::as_str).map(str::to_string))
        .collect();
    TaskOut {
        uuid: raw.uuid.clone(),
        id: raw.id,
        description: raw.description.clone(),
        project: raw.project.clone().unwrap_or_default(),
        priority: raw.priority.clone().unwrap_or_default(),
        tags: raw.tags.clone(),
        due_ms: due.map(|t| t.timestamp_millis()),
        scheduled_ms: ms(&raw.scheduled),
        wait_ms: ms(&raw.wait),
        entry_ms: ms(&raw.entry),
        urgency: raw.urgency,
        status: raw.status.clone(),
        annotations: raw.annotations.len(),
        notes: notes.clone(),
        links: extract_links(&raw.description, &notes, raw.gitlab_url.as_deref()),
        recurring: raw.recur.is_some(),
        active: raw.start.is_some(),
        blocked: !raw.depends.is_empty(),
        bucket: bucket_for(due, now),
        filters: Vec::new(),
    }
}

/// Build the snapshot from an export, with the built-in chips.
pub fn build_snapshot<Tz: TimeZone>(
    raw: &[RawTask],
    now: &DateTime<Tz>,
    include_waiting: bool,
    task_version: &str,
) -> Snapshot {
    build_snapshot_filtered(raw, now, include_waiting, task_version, &default_filters())
}

/// Build the snapshot from an export. Pending tasks are listed; waiting ones
/// only when `include_waiting` is set (they are always counted). Each
/// filter's count and each task's `filters` cover exactly the listed tasks,
/// so a filter's count is the number of rows the panel shows.
pub fn build_snapshot_filtered<Tz: TimeZone>(
    raw: &[RawTask],
    now: &DateTime<Tz>,
    include_waiting: bool,
    task_version: &str,
    filters: &[FilterOut],
) -> Snapshot {
    let mut counts = Counts::default();
    let mut tasks: Vec<TaskOut> = Vec::new();
    let mut projects: std::collections::BTreeMap<String, ProjectCount> = Default::default();

    for raw in raw {
        match raw.status.as_str() {
            "pending" => counts.pending += 1,
            "waiting" => {
                counts.waiting += 1;
                if !include_waiting {
                    continue;
                }
            }
            _ => continue,
        }
        let out = to_out(raw, now);
        match out.bucket {
            Bucket::Overdue => counts.overdue += 1,
            Bucket::Today => counts.today += 1,
            Bucket::Tomorrow => counts.tomorrow += 1,
            Bucket::Week => counts.week += 1,
            _ => {}
        }
        if raw.status == "pending" {
            let entry = projects.entry(out.project.clone()).or_insert_with(|| ProjectCount {
                name: out.project.clone(),
                pending: 0,
                overdue: 0,
            });
            entry.pending += 1;
            if out.bucket == Bucket::Overdue {
                entry.overdue += 1;
            }
        }
        tasks.push(out);
    }
    counts.due = counts.overdue + counts.today;
    for task in &tasks {
        if in_window(task.due_ms, now, Window::Month) {
            counts.month += 1;
        }
        if in_window(task.due_ms, now, Window::Quarter) {
            counts.quarter += 1;
        }
    }

    // Most urgent first; ties by due date, then description, so the order
    // is stable between refreshes.
    tasks.sort_by(|a, b| {
        b.urgency
            .partial_cmp(&a.urgency)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.due_ms.unwrap_or(i64::MAX).cmp(&b.due_ms.unwrap_or(i64::MAX)))
            .then_with(|| a.description.cmp(&b.description))
    });

    // Filters run last, over the finished list: a count is then the number
    // of rows the panel shows, and each task carries the chips it is in.
    let mut filters: Vec<FilterOut> = filters.to_vec();
    for (index, filter) in filters.iter_mut().enumerate() {
        let mut matched = 0;
        for task in tasks.iter_mut() {
            if filter_matches(filter, task, now) {
                task.filters.push(index);
                matched += 1;
            }
        }
        filter.count = matched;
    }

    Snapshot {
        ok: true,
        available: true,
        task_version: task_version.to_string(),
        generated_ms: now.timestamp_millis(),
        counts,
        projects: projects.into_values().collect(),
        filters,
        tasks,
    }
}

/// The longest link the plugin will offer to open.
pub const MAX_LINK_LEN: usize = 2048;

/// A link the panel may show and open: http(s), no whitespace, no control
/// characters, and none of the Unicode bidi or joiner characters that let
/// one URL be displayed as another.
pub fn is_safe_link(url: &str) -> bool {
    if url.len() > MAX_LINK_LEN || !(url.starts_with("http://") || url.starts_with("https://")) {
        return false;
    }
    let scheme_end = url.find("://").map(|i| i + 3).unwrap_or(0);
    if url.len() <= scheme_end {
        return false;
    }
    !url.chars().any(|c| {
        c.is_whitespace()
            || c.is_control()
            || matches!(c,
                '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    })
}

/// URLs worth a button: http(s) links in the text, plus the GitLab field.
/// Trailing punctuation that usually ends a sentence is dropped, and only
/// links that pass `is_safe_link` are kept.
pub fn extract_links(description: &str, notes: &[String], gitlab_url: Option<&str>) -> Vec<String> {
    let mut links: Vec<String> = Vec::new();
    let mut push = |url: &str| {
        let url = url.trim_end_matches(|c| matches!(c, '.' | ',' | ';' | ':' | ')' | ']' | '>' | '"' | '\''));
        if is_safe_link(url) && !links.iter().any(|l| l == url) {
            links.push(url.to_string());
        }
    };
    if let Some(g) = gitlab_url {
        push(g.trim());
    }
    for text in std::iter::once(description).chain(notes.iter().map(String::as_str)) {
        for word in text.split_whitespace() {
            // The earliest scheme in the word wins, so "https://a/?r=http://b"
            // yields the https link, not the one inside its query.
            let start = [word.find("http://"), word.find("https://")]
                .into_iter()
                .flatten()
                .min();
            if let Some(i) = start {
                push(&word[i..]);
            }
        }
    }
    links
}

/// A full Taskwarrior UUID. Short forms are refused: the plugin always has
/// the full one, and a short prefix could match a different task later.
pub fn is_uuid(value: &str) -> bool {
    let b = value.as_bytes();
    if b.len() != 36 {
        return false;
    }
    b.iter().enumerate().all(|(i, c)| match i {
        8 | 13 | 18 | 23 => *c == b'-',
        _ => c.is_ascii_hexdigit() && !c.is_ascii_uppercase(),
    })
}

/// What `modify` may change. Anything else (a filter, `rc.` overrides,
/// a bare word that would rewrite the description) is refused.
pub fn is_allowed_modification(arg: &str) -> bool {
    const ATTRS: [&str; 7] = ["due:", "wait:", "scheduled:", "until:", "priority:", "project:", "description:"];
    if arg.starts_with('+') || arg.starts_with('-') {
        let body = &arg[1..];
        // "--" would turn the rest of the command line into description text.
        return !body.is_empty()
            && !body.starts_with('+')
            && !body.starts_with('-')
            && !body.chars().any(|c| c.is_whitespace() || c.is_control() || matches!(c, ':' | '='));
    }
    ATTRS.iter().any(|a| arg.starts_with(a))
}

/// Words for `task add`. Taskwarrior parses `project:` and `due:` itself;
/// the bridge only refuses configuration overrides.
pub fn is_allowed_add_word(arg: &str) -> bool {
    !(arg.starts_with("rc.") || arg.starts_with("rc:") || arg.is_empty())
}

pub fn unavailable(error: &str) -> Value {
    serde_json::json!({ "ok": false, "available": false, "error": error })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    fn now() -> DateTime<FixedOffset> {
        // 2026-09-28 14:00 in New York (UTC-4).
        FixedOffset::west_opt(4 * 3600)
            .unwrap()
            .with_ymd_and_hms(2026, 9, 28, 14, 0, 0)
            .unwrap()
    }

    fn task(uuid: &str, due: Option<&str>, status: &str, project: Option<&str>, urgency: f64) -> RawTask {
        RawTask {
            id: 1,
            uuid: uuid.into(),
            description: format!("task {uuid}"),
            due: due.map(String::from),
            status: status.into(),
            project: project.map(String::from),
            urgency,
            ..Default::default()
        }
    }

    #[test]
    fn parses_taskwarrior_timestamps() {
        let t = parse_ts("20260331T040000Z").unwrap();
        assert_eq!(t.to_rfc3339(), "2026-03-31T04:00:00+00:00");
        assert!(parse_ts("2026-03-31").is_none());
    }

    #[test]
    fn buckets_by_local_calendar_day() {
        let n = now();
        // Due "today" in Taskwarrior terms is local midnight: 04:00Z.
        assert_eq!(bucket_for(parse_ts("20260928T040000Z"), &n), Bucket::Today);
        // 23:59 local today is still today, not tomorrow (03:59Z next day).
        assert_eq!(bucket_for(parse_ts("20260929T035900Z"), &n), Bucket::Today);
        assert_eq!(bucket_for(parse_ts("20260929T040000Z"), &n), Bucket::Tomorrow);
        assert_eq!(bucket_for(parse_ts("20260927T040000Z"), &n), Bucket::Overdue);
        assert_eq!(bucket_for(parse_ts("20261005T040000Z"), &n), Bucket::Week);
        assert_eq!(bucket_for(parse_ts("20261006T040000Z"), &n), Bucket::Later);
        assert_eq!(bucket_for(None, &n), Bucket::None);
    }

    #[test]
    fn snapshot_counts_and_sorts() {
        let raw = vec![
            task("a", Some("20260927T040000Z"), "pending", Some("nostr4"), 12.0),
            task("b", Some("20260928T040000Z"), "pending", Some("nostr4"), 15.0),
            task("c", None, "pending", None, 1.0),
            task("d", Some("20261101T040000Z"), "waiting", Some("soapbox"), 3.0),
            task("e", None, "completed", None, 0.0),
        ];
        let snap = build_snapshot(&raw, &now(), false, "3.5.0");
        assert_eq!(snap.counts.pending, 3);
        assert_eq!(snap.counts.waiting, 1);
        assert_eq!(snap.counts.overdue, 1);
        assert_eq!(snap.counts.today, 1);
        assert_eq!(snap.counts.due, 2);
        assert_eq!(snap.tasks.len(), 3, "waiting tasks are left out unless asked for");
        assert_eq!(snap.tasks[0].uuid, "b", "highest urgency first");
        assert_eq!(snap.projects.len(), 2);
        assert_eq!(snap.projects[0].name, "", "no-project group sorts first");
        assert_eq!(snap.projects[1].name, "nostr4");
        assert_eq!(snap.projects[1].pending, 2);
        assert_eq!(snap.projects[1].overdue, 1);

        let with_waiting = build_snapshot(&raw, &now(), true, "3.5.0");
        assert_eq!(with_waiting.tasks.len(), 4);
        assert!(!with_waiting.projects.iter().any(|p| p.name == "soapbox"), "waiting tasks don't make project chips");
    }

    #[test]
    fn finds_links() {
        let notes = vec!["see https://gitlab.com/x/y/-/issues/1.".to_string()];
        let links = extract_links(
            "Review (https://example.com/a) and https://example.com/a",
            &notes,
            Some("https://gitlab.com/x/y/-/issues/1"),
        );
        assert_eq!(links, vec!["https://gitlab.com/x/y/-/issues/1", "https://example.com/a"]);
        assert!(extract_links("no links here", &[], None).is_empty());
        assert!(extract_links("x", &[], Some("not a url")).is_empty());
        // The outer scheme wins over one inside the query.
        assert_eq!(extract_links("https://evil.example/?r=http://good.example", &[], None), vec!["https://evil.example/?r=http://good.example"]);
        // Control, bidi and whitespace characters are refused, in text and in the UDA.
        assert!(extract_links("x", &[], Some("https://a.example/\u{202e}moc.elgoog")).is_empty());
        assert!(extract_links("x", &[], Some("https://a.example/one two")).is_empty());
        assert!(extract_links("https://a.example/\u{7}bell", &[], None).is_empty());
        let long = format!("https://a.example/{}", "x".repeat(MAX_LINK_LEN));
        assert!(extract_links(&long, &[], None).is_empty());
        assert!(!is_safe_link("https://"));
    }

    #[test]
    fn validates_uuids() {
        assert!(is_uuid("0063ee03-d4a0-4c90-bb39-4c8f0898754e"));
        assert!(!is_uuid("0063ee03"));
        assert!(!is_uuid("0063EE03-D4A0-4C90-BB39-4C8F0898754E"));
        assert!(!is_uuid("0063ee03-d4a0-4c90-bb39-4c8f0898754e; rm -rf /"));
    }

    #[test]
    fn restricts_modifications() {
        assert!(is_allowed_modification("due:tomorrow"));
        assert!(is_allowed_modification("wait:1w"));
        assert!(is_allowed_modification("+next"));
        assert!(is_allowed_modification("-next"));
        assert!(!is_allowed_modification("rc.data.location=/tmp"));
        assert!(!is_allowed_modification("status:pending"));
        assert!(!is_allowed_modification("new description"));
        assert!(!is_allowed_modification("+"));
        assert!(!is_allowed_modification("--"));
        assert!(!is_allowed_modification("-"));
        assert!(!is_allowed_modification("+due:tomorrow"));
        assert!(!is_allowed_modification("+a=b"));
        assert!(!is_allowed_modification("++x"));
        assert!(is_allowed_add_word("project:nostr4"));
        assert!(!is_allowed_add_word("rc.confirmation=on"));
    }

    // 14:00 in New York (UTC-4) on the given day, so local midnight is 04:00Z.
    fn at(y: i32, m: u32, d: u32) -> DateTime<FixedOffset> {
        FixedOffset::west_opt(4 * 3600)
            .unwrap()
            .with_ymd_and_hms(y, m, d, 14, 0, 0)
            .unwrap()
    }

    fn ms(stamp: &str) -> i64 {
        parse_ts(stamp).unwrap().timestamp_millis()
    }

    /// A task as the plugin sees it, through the real conversion.
    fn task_out(uuid: &str, due: Option<&str>, project: &str, tags: &[&str], priority: &str) -> TaskOut {
        let raw = RawTask {
            id: 1,
            uuid: uuid.into(),
            description: format!("task {uuid}"),
            due: due.map(String::from),
            project: if project.is_empty() { None } else { Some(project.into()) },
            priority: if priority.is_empty() { None } else { Some(priority.into()) },
            tags: tags.iter().map(|t| t.to_string()).collect(),
            ..Default::default()
        };
        to_out(&raw, &now())
    }

    fn filter(name: &str, time: &str, projects: &[&str], tags: &[&str], priority: &str) -> FilterOut {
        FilterOut {
            name: name.into(),
            time: time.into(),
            projects: projects.iter().map(|p| p.to_string()).collect(),
            tags: tags.iter().map(|t| t.to_string()).collect(),
            priority: priority.into(),
            match_mode: "any".into(),
            priority_mode: "exact".into(),
            count: 0,
        }
    }

    #[test]
    fn months_and_quarters_end_where_they_should() {
        let d = |y, m, day| NaiveDate::from_ymd_opt(y, m, day).unwrap();
        assert_eq!(end_of_month(d(2026, 2, 10)), Some(d(2026, 2, 28)));
        assert_eq!(end_of_month(d(2028, 2, 10)), Some(d(2028, 2, 29)), "leap year");
        assert_eq!(end_of_month(d(2026, 12, 5)), Some(d(2026, 12, 31)));
        assert_eq!(end_of_quarter(d(2026, 8, 10)), Some(d(2026, 9, 30)));
        assert_eq!(end_of_quarter(d(2026, 1, 2)), Some(d(2026, 3, 31)));
        assert_eq!(end_of_quarter(d(2026, 11, 30)), Some(d(2026, 12, 31)));
    }

    #[test]
    fn windows_cover_the_month_and_quarter_not_just_the_week() {
        let august = at(2026, 8, 10);
        // Already late: in every window, including the shortest.
        assert!(in_window(Some(ms("20260701T040000Z")), &august, Window::Week));
        assert!(in_window(Some(ms("20260701T040000Z")), &august, Window::Quarter));
        // A week out: week, month and quarter.
        assert!(in_window(Some(ms("20260817T040000Z")), &august, Window::Week));
        assert!(in_window(Some(ms("20260817T040000Z")), &august, Window::Month));
        // September: past the week and past the month, inside the quarter.
        assert!(!in_window(Some(ms("20260905T040000Z")), &august, Window::Week));
        assert!(!in_window(Some(ms("20260905T040000Z")), &august, Window::Month));
        assert!(in_window(Some(ms("20260905T040000Z")), &august, Window::Quarter));
        // The last day of the month is in it; the first of October is not.
        assert!(in_window(Some(ms("20260831T040000Z")), &august, Window::Month));
        assert!(!in_window(Some(ms("20261001T040000Z")), &august, Window::Quarter));
        assert!(in_window(Some(ms("20261001T040000Z")), &august, Window::All));
        // No due date: only the unconstrained window.
        assert!(!in_window(None, &august, Window::Month));
        assert!(in_window(None, &august, Window::All));
        // Due is overdue plus today; Today reaches tomorrow.
        assert!(in_window(Some(ms("20260810T040000Z")), &august, Window::Due));
        assert!(!in_window(Some(ms("20260811T040000Z")), &august, Window::Due));
        assert!(in_window(Some(ms("20260811T040000Z")), &august, Window::Today));
    }

    #[test]
    fn filters_combine_time_projects_tags_and_priority() {
        // now() is 2026-09-28: the seven-day window reaches into October while
        // the month and the quarter both end on the 30th.
        let n = now();
        let october = task_out("october", Some("20261002T040000Z"), "btcmap", &["next"], "H");
        let month_end = task_out("month_end", Some("20260930T040000Z"), "bitfest", &["month"], "M");
        let late = task_out("late", Some("20260901T040000Z"), "btcmap", &["quarter"], "");
        let far = task_out("far", Some("20261201T040000Z"), "btcmap", &["next"], "L");
        let two_tags = task_out("two_tags", Some("20260929T040000Z"), "btcmap", &["next", "month"], "");
        let mixed = task_out("mixed", Some("20260929T040000Z"), "btcmap", &["next"], "M");

        let this_month = filter("Month", "month", &[], &[], "");
        assert!(filter_matches(&this_month, &month_end, &n));
        assert!(filter_matches(&this_month, &late, &n), "late tasks are in every window");
        assert!(filter_matches(&this_month, &two_tags, &n));
        assert!(!filter_matches(&this_month, &october, &n), "past the end of the month");
        assert!(!filter_matches(&this_month, &far, &n));

        // A month is not a week: the seven-day window reaches past the month's
        // end, and the month does not reach into the next one.
        let this_week = filter("Week", "week", &[], &[], "");
        assert!(filter_matches(&this_week, &october, &n));
        assert!(!filter_matches(&this_month, &october, &n));

        // Time AND project.
        let btcmap_month = filter("BTC Map", "month", &["btcmap"], &[], "");
        assert!(filter_matches(&btcmap_month, &late, &n));
        assert!(filter_matches(&btcmap_month, &mixed, &n));
        assert!(!filter_matches(&btcmap_month, &month_end, &n), "another project");
        assert!(!filter_matches(&btcmap_month, &october, &n), "outside the month");

        // Tags: any-of by default, all-of when the filter asks.
        let any_tag = filter("any", "all", &[], &["next", "month"], "");
        let all_tags = FilterOut { match_mode: "all".into(), ..filter("all", "all", &[], &["next", "month"], "") };
        assert!(filter_matches(&any_tag, &october, &n));
        assert!(filter_matches(&any_tag, &month_end, &n));
        assert!(!filter_matches(&all_tags, &october, &n), "next only");
        assert!(!filter_matches(&all_tags, &month_end, &n), "month only");
        assert!(filter_matches(&all_tags, &two_tags, &n));

        // Priority: exact, or everything at least that high.
        let high = filter("High", "all", &[], &[], "H");
        assert!(filter_matches(&high, &october, &n));
        assert!(!filter_matches(&high, &month_end, &n));
        let medium_up = FilterOut { priority_mode: "atleast".into(), ..filter("Medium+", "all", &[], &[], "M") };
        assert!(filter_matches(&medium_up, &october, &n), "H is at least M");
        assert!(filter_matches(&medium_up, &month_end, &n));
        assert!(!filter_matches(&medium_up, &far, &n), "L is not");
        assert!(!filter_matches(&medium_up, &late, &n), "and unprioritised is not 'at least low'");

        // Everything at once, so each field has to hold.
        let combined = FilterOut {
            priority_mode: "atleast".into(),
            ..filter("Combined", "month", &["btcmap"], &["next"], "M")
        };
        assert!(filter_matches(&combined, &mixed, &n));
        assert!(!filter_matches(&combined, &two_tags, &n), "no priority");
        assert!(!filter_matches(&combined, &october, &n), "outside the month");
        assert!(!filter_matches(&combined, &late, &n), "not tagged next");
    }

    #[test]
    fn filters_are_clamped_not_refused() {
        let parsed = parse_filters(
            r#"[{"name":"  ","time":"MOTH","projects":[" a ","a",""],"tags":["x"],
                 "priority":"h","match":"ALL","priorityMode":"AtLeast"},
                {"name":"Named","time":"quarter"}]"#,
        );
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].name, "Filter 1", "an empty name gets a number");
        assert_eq!(parsed[0].time, "all", "an unknown window widens, and says so");
        assert_eq!(parsed[0].projects, vec!["a"], "trimmed, de-duplicated, empties dropped");
        assert_eq!(parsed[0].priority, "H");
        assert_eq!(parsed[0].match_mode, "all");
        assert_eq!(parsed[0].priority_mode, "atleast");
        assert_eq!(parsed[1].name, "Named");
        assert_eq!(parsed[1].time, "quarter");
        assert_eq!(parsed[1].priority, "");
        assert_eq!(parsed[1].match_mode, "any");
        assert_eq!(parsed[1].priority_mode, "exact");

        assert!(parse_filters("not json").is_empty());
        assert!(parse_filters("{}").is_empty());
        assert!(parse_filters("[]").is_empty());
        let many = format!("[{}]", vec![r#"{"name":"x"}"#; MAX_FILTERS + 5].join(","));
        assert_eq!(parse_filters(&many).len(), MAX_FILTERS, "capped, one per digit key plus the cycle");
    }

    #[test]
    fn snapshot_counts_each_filter_over_the_listed_tasks() {
        let raw = vec![
            task("a", Some("20260927T040000Z"), "pending", Some("btcmap"), 12.0),
            task("b", Some("20260928T040000Z"), "pending", Some("btcmap"), 15.0),
            task("c", None, "pending", None, 1.0),
            task("d", Some("20261101T040000Z"), "waiting", Some("btcmap"), 3.0),
        ];
        let filters = vec![filter("Due", "due", &[], &[], ""), filter("Month", "month", &[], &[], "")];
        let snap = build_snapshot_filtered(&raw, &now(), false, "3.5.0", &filters);

        // The waiting task is not listed, so no filter counts it.
        assert_eq!(snap.counts.month, 2, "overdue plus due today, both this month");
        assert_eq!(snap.counts.quarter, 2);
        assert_eq!(snap.filters[0].name, "Due");
        assert_eq!(snap.filters[0].count, 2);
        assert_eq!(snap.filters[1].count, 2);
        // Sorted by urgency: b (15), a (12), c (1).
        assert_eq!(snap.tasks[0].uuid, "b");
        assert_eq!(snap.tasks[0].filters, vec![0, 1]);
        assert_eq!(snap.tasks[1].uuid, "a");
        assert_eq!(snap.tasks[2].uuid, "c");
        assert!(snap.tasks[2].filters.is_empty(), "no due date is in no window");

        // Nothing configured: the chips the plugin has always had, plus the two.
        let defaults = build_snapshot(&raw, &now(), false, "3.5.0");
        let names: Vec<&str> = defaults.filters.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, vec!["Due", "Today", "Week", "Month", "Quarter", "All"]);
        assert_eq!(defaults.filters[3].time, "month");
        assert_eq!(defaults.filters[5].count, 3, "All counts everything listed");
    }
}
