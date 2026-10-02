# Omarchy Tasks

Your [Taskwarrior](https://taskwarrior.org) tasks in the [Omarchy](https://omarchy.org) bar.

- **On the bar:** a checklist glyph and the number of tasks that need you (overdue plus due today by default). It turns urgent when something is overdue. Left click opens the panel, right click opens it on the add line, middle click syncs.
- **In the panel:** a quick-add line that takes Taskwarrior's own syntax (`Call Alex project:nostr4 due:friday +call`), four views (Due, Today, Week, All), project chips with counts, and the list grouped by project.
- **Triage, not forms.** A row expands to its notes and the actions that matter: Done, Tomorrow, Next week, Snooze (hide for a week), Open link, Edit. Each has a key.
- **Edit in place.** Edit turns the row into a small form: description, project, due (any Taskwarrior date: `2026-10-07`, `friday`, `eom`), priority and tags. Enter saves only what changed, Esc cancels.
- **Links.** URLs in a task's description or annotations, and the `gitlab_url` field if you use one, become an Open link button.
- **Daily digest.** One desktop notification with what's overdue and due today. The gear in the panel turns it on or off, sets the time and the days (weekdays by default), and has a Send now button.
- **Sync.** Runs `task sync` every 15 minutes, or on demand, when a sync server is configured in `~/.taskrc`. Without one, sync is skipped.
- **Small.** A Rust helper (`omarchy-taskbridge`) that only ever runs `task`, with a hard timeout, plus the QML. No Python, no Timewarrior, no about page.

## Keys

| Key | Does |
| --- | --- |
| `j` / `k`, arrows | Move between tasks |
| `Enter` | Expand or collapse |
| `d` | Done |
| `t` | Due tomorrow |
| `w` | Due in a week |
| `z` | Snooze: hide for a week (`wait:1w`) |
| `o` | Open the task's first link |
| `e` | Edit the task in place |
| `g` or `,` | Daily digest settings |
| `a` or `+` | Jump to the add line |
| `1` `2` `3` `4`, `h` / `l` | Views: Due, Today, Week, All |
| `[` / `]` | Cycle project |
| `u` | Undo the last change |
| `s` / `r` | Sync / refresh |
| `Esc` | Collapse, then close |

Middle-click a row to mark it done without expanding it.

## Requirements

- Omarchy 4 or newer (the Quickshell `omarchy-shell`)
- Taskwarrior 3: the `task` package in your distribution
- Rust, to build the helper: the `rustup` package, then `rustup default stable`
- Optional: a Taskwarrior sync server, configured in `~/.taskrc`, for the Sync button

## Install

```bash
omarchy plugin add https://github.com/derekross/omarchy-tasks.git --enable
~/.config/omarchy/plugins/derekross.tasks/dist/install.sh
omarchy bar move derekross.tasks --section right
```

From a checkout somewhere else, run `./dist/install.sh` inside it; that links the checkout into `~/.config/omarchy/plugins/` so edits reload live.

`install.sh` builds `omarchy-taskbridge` with cargo (`--locked`, so the reviewed `Cargo.lock` is what gets built) and puts it in `~/.local/bin`, recording its SHA-256 in `~/.local/state/omarchy-tasks/installed.tsv`. If something else already sits at that path, the script refuses and says so; `--replace-existing` moves that file to a backup under the same state folder instead. It writes nothing else. No sudo or pkexec is required, and nothing is downloaded beyond the crates cargo fetches to build the helper.

## Settings

In the bar's widget settings, or the `derekross.tasks` entry in `~/.config/omarchy/shell.json`:

| Setting | Default | What |
| --- | --- | --- |
| `countMode` | `due` | Number on the bar: `due` (overdue + today), `overdue`, `pending`, or the name of any filter you define |
| `showWhenEmpty` | `true` | Keep the icon when nothing is due |
| `defaultView` | `due` | The filter the panel opens on: its name, or a window like `month` |
| `includeWaiting` | `false` | List tasks whose `wait:` date hasn't passed |
| `digestEnabled` | `true` | Daily digest notification on or off |
| `digestTime` | `09:00` | When it goes out, 24-hour `HH:mm` |
| `digestDays` | `mon,tue,wed,thu,fri` | Which days |
| `refreshSeconds` | `30` | How often to re-read Taskwarrior |
| `syncMinutes` | `15` | `task sync` interval when a sync server is configured; `0` turns it off |
| `filters` | *(the six below)* | The chips the panel shows, and what each one means |

## Filters

The chips in the panel are filters, and `omarchy-taskbridge` does the
matching, so a filter's count is the number of rows the panel shows for it -
and can also be the number on the bar.

Each filter has a name, a time window (`due`, `today`, `week`, `month`,
`quarter`, `all`), any number of projects, any number of tags, and a
priority. A task is in a filter when all of those hold:

- **Time** keeps what is already late. `Month` is everything left to do by
  the end of this calendar month and `Quarter` by the end of this quarter;
  `due` is overdue plus due today, `today` reaches tomorrow, `week` seven
  days, and `all` is every pending task.
- **Projects** are any-of, since a task has one project.
- **Tags** are any-of unless the filter asks for all of them.
- **Priority** is exact, or "or above" so that `M` also takes `H`.

With no `filters` setting the chips are `Due`, `Today`, `Week`, `Month`,
`Quarter` and `All`. The gear in the panel edits the list: add, rename,
reorder, remove, and back to the defaults. Every change is written to
`shell.json` as it is made and the counts come back on the next snapshot, so
nothing about a filter is decided twice.

`countMode` takes a filter's name as well as the three modes, which is how a
filter's number gets onto the bar:

```
omarchy bar set derekross.tasks countMode "BTC Map"
```

Filters live in the helper, so an install from before this change needs
`dist/install.sh` run again; the panel says so instead of showing an empty
row.

## Update

```bash
omarchy plugin update derekross.tasks
~/.config/omarchy/plugins/derekross.tasks/dist/install.sh
```

## Remove

```bash
~/.config/omarchy/plugins/derekross.tasks/dist/uninstall.sh
omarchy plugin remove derekross.tasks    # if added with omarchy plugin add
```

`uninstall.sh` deletes the helper only if it is a regular file whose SHA-256 matches the install record, and the plugin link only if it points at this checkout. It never runs the file to find out what it is. Anything else at those paths is left in place and named in the output.

## Privacy and security

- Nothing leaves your computer except `task sync`, to the server you configured in `~/.taskrc`, and only if you configured one. Links open only when you click Open link or press `o`.
- The helper is the only thing that runs `task`. Every call is a plain argument list (no shell), with `task` in its own process group under a hard timeout: 8 seconds for reads and changes, 60 for sync.
- The helper checks what the panel sends before it reaches `task`: full UUIDs only; `modify` may set only `due:`, `wait:`, `scheduled:`, `until:`, `priority:`, `project:`, `description:` and `+tag`/`-tag`; `add` refuses `rc.` overrides.
- Links must be http(s) with no whitespace, control or bidirectional characters, and are checked again in the panel before Qt asks the desktop to open them.
- Task text is drawn as plain text, so a description can't carry markup. The daily digest escapes it for the notification daemon.
- Undo only offers to take back changes made from this panel.
- Settings are written only to this widget's entry in `~/.config/omarchy/shell.json`, and only when you change them in the panel.
- The plugin runs, like every Omarchy shell plugin, unsandboxed inside `omarchy-shell`. Read the source before installing; it's short.

## How it works

`omarchy-taskbridge snapshot` runs `task status:pending export`, buckets each task by local calendar day (overdue, today, tomorrow, week, later), collects links, and prints one JSON object. The plugin's service runs it every 30 seconds and after every action. Actions (`add`, `done`, `modify`, `undo`, `sync`) go through the same helper with the checks above. `task` runs with confirmation and colour off.

## Development

```bash
cargo test                # the helper
node --test tests/*.test.js   # Model.js
./dist/install.sh         # rebuild and reinstall; QML reloads on save
```
