// Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

function loadModel() {
  const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "")
  const ctx = {}
  vm.createContext(ctx)
  vm.runInContext(source, ctx)
  return ctx
}

const M = loadModel()
const same = (a, e, msg) => assert.deepEqual(JSON.parse(JSON.stringify(a)), e, msg)

// Monday 2026-09-28 14:00 local.
const NOW = new Date(2026, 8, 28, 14, 0, 0).getTime()
const day = (n, h) => new Date(2026, 8, 28 + n, h || 0, 0, 0).getTime()

// The helper decides which chips a task is in, so each one carries the
// indexes (see filters[].count in the Rust tests for the matching itself).
const tasks = [
  { uuid: "a", description: "Send counter-reply", project: "nostr4", dueMs: day(2), urgency: 15, bucket: "week", tags: ["nostr", "next"], filters: [2, 3, 4, 5] },
  { uuid: "b", description: "Book flight", project: "amsterdam", dueMs: day(-10), urgency: 12, bucket: "overdue", tags: ["amsterdam"], filters: [0, 1, 2, 3, 4, 5] },
  { uuid: "c", description: "Read", project: "", dueMs: null, urgency: 1, bucket: "none", tags: [], filters: [5] },
  { uuid: "d", description: "Call", project: "nostr4", dueMs: day(0, 23), urgency: 9, bucket: "today", tags: ["nostr"], filters: [0, 1, 2, 3, 4, 5] },
  { uuid: "e", description: "Plan", project: "nostr4", dueMs: day(1), urgency: 20, bucket: "tomorrow", tags: ["next", "call"], filters: [1, 2, 3, 4, 5] },
]

// What the helper echoes back for `--filters`.
const chips = [
  { name: "Due", time: "due", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 2 },
  { name: "Today", time: "today", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 3 },
  { name: "Week", time: "week", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 4 },
  { name: "Month", time: "month", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 4 },
  { name: "Quarter", time: "quarter", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 4 },
  { name: "All", time: "all", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact", count: 5 },
]

test("pill count follows the mode", () => {
  const counts = { due: 3, overdue: 2, pending: 50 }
  assert.equal(M.countForMode(counts, "due"), 3)
  assert.equal(M.countForMode(counts, "overdue"), 2)
  assert.equal(M.countForMode(counts, "pending"), 50)
  assert.equal(M.countForMode(null, "due"), 0)
})

test("summary leaves out zeros and pluralises", () => {
  assert.equal(M.summary({ overdue: 2, today: 0, tomorrow: 1, pending: 1, waiting: 0 }), "2 overdue · 1 tomorrow · 1 pending task")
  assert.equal(M.summary({ pending: 50, waiting: 3 }), "50 pending tasks · 3 waiting")
})

test("due labels are relative and short", () => {
  assert.equal(M.dueLabel(day(-3), NOW), "3d late")
  assert.equal(M.dueLabel(day(0, 23), NOW), "today")
  assert.equal(M.dueLabel(day(1), NOW), "tomorrow")
  assert.equal(M.dueLabel(day(4), NOW), "Fri")
  assert.equal(M.dueLabel(day(9), NOW), "Oct 7")
  assert.equal(M.dueLabel(new Date(2027, 2, 5).getTime(), NOW), "Mar 2027")
  assert.equal(M.dueLabel(null, NOW), "")
})

test("a chip lists the tasks the helper matched", () => {
  same(M.tasksForFilter(tasks, 0, "").map(t => t.uuid), ["b", "d"])
  same(M.tasksForFilter(tasks, 2, "").map(t => t.uuid), ["a", "b", "d", "e"])
  same(M.tasksForFilter(tasks, 5, "").map(t => t.uuid), ["a", "b", "c", "d", "e"])
  same(M.tasksForFilter(tasks, 5, "nostr4").map(t => t.uuid), ["a", "d", "e"])
  same(M.tasksForFilter(tasks, 9, "").map(t => t.uuid), [], "an index the helper never sent")
  same(M.tasksForFilter(null, 0, ""), [])
})

test("a dated chip sorts by date, an unconstrained one by urgency", () => {
  same(M.sortTasks(M.tasksForFilter(tasks, 2, ""), chips[2]).map(t => t.uuid), ["b", "d", "e", "a"])
  same(M.sortTasks(tasks, chips[5]).map(t => t.uuid), ["e", "a", "b", "d", "c"])
  same(M.sortTasks(tasks, null).map(t => t.uuid), ["e", "a", "b", "d", "c"], "no filter at all is unconstrained")
})

test("the chip is resolved by name, then by window", () => {
  assert.equal(M.resolveFilterIndex(chips, "Month", 0), 3)
  assert.equal(M.resolveFilterIndex(chips, "month", 0), 3, "case-insensitively")
  assert.equal(M.resolveFilterIndex(chips, "today", 0), 1, "a window name finds its chip")
  assert.equal(M.resolveFilterIndex(chips, "nope", 2), 2, "an unknown name keeps the fallback")
  assert.equal(M.resolveFilterIndex(chips, "nope", 99), 0, "a fallback out of range starts at the first")
  assert.equal(M.resolveFilterIndex(chips, "", 4), 4)
  assert.equal(M.resolveFilterIndex([], "Month", 0), 0)
  assert.equal(M.cycleIndex(6, 5, 1), 0)
  assert.equal(M.cycleIndex(6, 0, -1), 5)
  assert.equal(M.cycleIndex(0, 0, 1), 0)
})

test("the pill follows a filter name or a built-in mode", () => {
  const counts = { due: 3, overdue: 2, pending: 50 }
  assert.equal(M.countForPill(counts, "due", chips), 3, "the mode wins over a chip of the same name")
  assert.equal(M.countForPill(counts, "overdue", chips), 2)
  assert.equal(M.countForPill(counts, "pending", chips), 50)
  assert.equal(M.countForPill(counts, "Month", chips), 4, "a chip's own count")
  assert.equal(M.countForPill({ due: 0 }, "month", chips), 4, "case-insensitively")
  assert.equal(M.countForPill({ due: 7 }, "BTC Map", chips), 7, "an unknown name falls back to the mode")
  assert.equal(M.countForPill({}, "Month", []), 0)
})

test("the editor sends only the fields the helper reads", () => {
  same(M.filterInput({ name: " X ", time: "MOTH", projects: ["a", "a", 2], tags: ["t"], priority: "z", match: "ALL", priorityMode: "atleast", count: 9 }),
    { name: " X ", time: "all", projects: ["a", "a", 2], tags: ["t"], priority: "", match: "all", priorityMode: "atleast" },
    "the helper trims, de-duplicates and caps; the editor only maps")
  same(M.filterInput(null), { name: "", time: "all", projects: [], tags: [], priority: "", match: "any", priorityMode: "exact" })
  assert.equal(M.filtersJson([{ name: "A" }]),
    '[{"name":"A","time":"all","projects":[],"tags":[],"priority":"","match":"any","priorityMode":"exact"}]')
  assert.equal(M.filtersJson([]), "[]")
  same(M.filterInput(M.draftFilter("B")).name, "B")
})

test("a filter reads back in its own words", () => {
  assert.equal(M.filterSummary({ name: "BTC Map", time: "month", projects: ["btcmap"], tags: ["next", "prague"], priority: "H", priorityMode: "atleast" }),
    "Month · btcmap · +next, +prague · H or above")
  assert.equal(M.filterSummary({ name: "Truck", time: "all", tags: ["truck", "personal"], match: "all" }), "+truck +personal")
  assert.equal(M.filterSummary({ name: "All", time: "all" }), "")
  assert.equal(M.filterSummary(null), "")
  assert.equal(M.emptyText({ name: "Due", time: "due" }, ""), "Nothing overdue or due today.")
  assert.equal(M.emptyText({ name: "Month", time: "month" }, "nostr4"), "Nothing due this month in nostr4.")
  assert.equal(M.emptyText({ name: "Quarter", time: "quarter" }, ""), "Nothing due this quarter.")
  assert.equal(M.emptyText({ name: "Truck", time: "all" }, ""), "Nothing in Truck.")
  assert.equal(M.emptyText(null, ""), "No pending tasks.")
})

test("the pickers are built from the tasks in hand", () => {
  same(M.tagList(tasks), ["amsterdam", "call", "next", "nostr"])
  same(M.tagList(tasks, 2), ["amsterdam", "call"])
  same(M.tagList(null), [])
  same(M.arrayFrom("nope"), [], "a string is not a list")
  same(M.arrayFrom({ length: 2, 0: "a", 1: "b" }), ["a", "b"], "a QML list value still walks")
})

test("groups keep first-seen project order", () => {
  const groups = M.groupByProject(M.sortTasks(tasks, "all"))
  same(groups.map(g => [g.project, g.tasks.length]), [["nostr4", 3], ["amsterdam", 1], ["", 1]])
})

test("add text splits like a shell", () => {
  same(M.splitAddText('Call Alex project:nostr4 due:friday +call'), ["Call", "Alex", "project:nostr4", "due:friday", "+call"])
  same(M.splitAddText('Fix "the thing" due:tomorrow'), ["Fix", "the thing", "due:tomorrow"])
  same(M.splitAddText("   "), [])
})

test("digest days parse and label", () => {
  same(M.parseDigestDays("mon,tue,wed,thu,fri"), [false, true, true, true, true, true, false])
  same(M.parseDigestDays("Sat sun"), [true, false, false, false, false, false, true])
  same(M.parseDigestDays(""), [false, false, false, false, false, false, false])
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,tue,wed,thu,fri")), "weekdays")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("sat,sun")), "weekends")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,tue,wed,thu,fri,sat,sun")), "every day")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,thu")), "Mon, Thu")
  assert.equal(M.digestDaysText(M.parseDigestDays("sun,mon")), "mon,sun")
})

test("times parse and format", () => {
  same(M.parseHHMM("9:05"), { hour: 9, minute: 5 })
  same(M.parseHHMM("23:59"), { hour: 23, minute: 59 })
  assert.equal(M.parseHHMM("24:00"), null)
  assert.equal(M.parseHHMM("nine"), null)
  assert.equal(M.formatHHMM(9, 0), "09:00")
  assert.equal(M.hourLabel(0), "12 AM")
  assert.equal(M.hourLabel(13), "1 PM")
})

test("edit changes are the difference between task and form", () => {
  const task = { description: "Call Alex", project: "nostr4", priority: "M", dueMs: new Date(2026, 9, 7).getTime(), tags: ["call", "urgent"] }
  same(M.editChanges(task, { description: "Call Alex", project: "nostr4", priority: "M", due: "2026-10-07", tags: "call urgent" }), [])
  same(M.editChanges(task, { description: "Call Alex about equity", project: "", priority: "", due: "friday", tags: "+call, phone" }),
    ["description:Call Alex about equity", "project:", "priority:", "due:friday", "+phone", "-urgent"])
  same(M.editChanges(task, { description: "   ", project: "nostr4", priority: "M", due: "2026-10-07", tags: "call urgent" }), [], "blank description is ignored")
  same(M.editChanges({ description: "x", project: "", priority: "", dueMs: null, tags: [] }, { description: "x", project: "", priority: "H", due: "", tags: "" }), ["priority:H"])
})

test("links are checked before opening", () => {
  assert.equal(M.isSafeLink("https://gitlab.com/soapbox-pub/agora/-/work_items/44"), true)
  assert.equal(M.isSafeLink("http://example.com/a?b=c#d"), true)
  assert.equal(M.isSafeLink("ftp://example.com"), false)
  assert.equal(M.isSafeLink("https://example.com/a b"), false)
  assert.equal(M.isSafeLink("https://example.com/\u202emoc"), false)
  assert.equal(M.isSafeLink("https://example.com/\u0007"), false)
  assert.equal(M.isSafeLink("https://" + "x".repeat(2100)), false)
  assert.equal(M.isSafeLink(""), false)
})

test("notification text is escaped", () => {
  assert.equal(M.escapeMarkup("a <b> & c"), "a &lt;b&gt; &amp; c")
})
