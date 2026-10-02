import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless Taskwarrior service. Runs the taskbridge helper on a timer for a
// snapshot of pending tasks, queues the actions the panel asks for (add,
// done, modify, undo) one at a time, runs `task sync` on its own interval,
// and sends the daily digest. The bar widget pushes its settings in
// through configure().
Item {
  id: root

  property var manifest: null
  property var shell: null

  // Settings, overridden by the bar widget's shell.json entry.
  property int refreshSeconds: 30
  property int syncMinutes: 15
  property bool includeWaiting: false
  property bool digestEnabled: true
  property string digestTime: "09:00"
  property string digestDays: Model.DEFAULT_DIGEST_DAYS
  // Fixed on purpose: nothing in shell.json can point the plugin at another binary.
  readonly property string homeDir: String(Quickshell.env("HOME") || "")
  readonly property string helperPath: homeDir + "/.local/bin/omarchy-taskbridge"

  // State the widget and panel read.
  property var tasks: []
  property var counts: ({})
  property var projects: []
  /// The filters the plugin defined, sent to the helper with every snapshot.
  property var filters: []
  /// What the helper echoed back: name, window, selectors and count. This is
  /// what the bar's pill and the panel's chips read.
  property var filterList: []
  /// False while the installed helper predates filters.
  property bool filtersSupported: true
  property var taskVersion: ""
  property bool helperAvailable: true
  property bool taskAvailable: true
  property bool refreshing: false
  property bool syncing: false
  property bool busy: false
  property string lastError: ""
  property string syncError: ""
  property string lastAction: ""
  property double lastRefresh: 0
  property double lastSync: 0
  property string lastDigestDay: ""
  // Changes made from this panel that `undo` may take back. Undo is never
  // offered for changes made elsewhere (a terminal, another computer).
  property int undoable: 0
  property bool syncWanted: false
  // Bumped on every new snapshot so the panel can react once per load.
  property int generation: 0
  property bool settled: false

  property var _queue: []

  Component.onCompleted: {
    if (homeDir.indexOf("/") !== 0) {
      helperAvailable = false
      lastError = "HOME is not set, so the helper can't be found."
    }
  }

  function configure(settings) {
    var s = settings || {}
    refreshSeconds = Model.clampInt(s.refreshSeconds, 30, 5, 3600)
    syncMinutes = Model.clampInt(s.syncMinutes, 15, 0, 1440)
    includeWaiting = s.includeWaiting === true
    digestEnabled = s.digestEnabled === undefined || s.digestEnabled === null ? true : s.digestEnabled === true
    digestTime = Model.parseHHMM(s.digestTime) ? String(s.digestTime).trim() : "09:00"
    digestDays = s.digestDays === undefined || s.digestDays === null ? Model.DEFAULT_DIGEST_DAYS : String(s.digestDays)
    var wanted = Model.arrayFrom(s.filters)
    var changed = Model.filtersJson(wanted) !== Model.filtersJson(filters)
    filters = wanted
    if (settled && changed) Qt.callLater(refresh)
    if (!settled) {
      settled = true
      Qt.callLater(refresh)
    }
  }

  onIncludeWaitingChanged: if (settled) Qt.callLater(refresh)

  function refresh() {
    if (!helperAvailable || snapProc.running) return
    refreshing = true
    var args = [helperPath, "snapshot"]
    if (includeWaiting) args.push("--waiting")
    // The helper does the matching, so a filter means the same thing on the
    // bar, on its chip and in the list.
    if (filters.length > 0) {
      args.push("--filters")
      args.push(Model.filtersJson(filters))
    }
    snapProc.command = args
    snapProc.running = true
  }

  // Sync and actions never run at the same time: a write waiting on the
  // database lock behind a long sync would only time out.
  function sync() {
    if (!helperAvailable || syncing) return
    if (actProc.running) { syncWanted = true; return }
    syncWanted = false
    syncing = true
    syncError = ""
    syncProc.command = [helperPath, "sync"]
    syncProc.running = true
  }

  // Actions run one after another; each is followed by a refresh so the
  // list reflects what task actually did.
  function act(args, label) {
    if (!helperAvailable) return
    _queue.push({ args: args, label: label })
    _next()
  }

  function _next() {
    if (actProc.running) return
    if (_queue.length === 0) { if (syncWanted) sync(); return }
    if (syncProc.running) return
    var job = _queue.shift()
    actProc.label = job.label
    actProc.command = [helperPath].concat(job.args)
    busy = true
    actProc.running = true
  }

  function add(text) {
    var words = Model.splitAddText(text)
    if (words.length === 0) return
    act(["add"].concat(words), "Added")
  }

  function done(uuid) { act(["done", uuid], "Done") }
  function modify(uuid, changes) { if (changes.length > 0) act(["modify", uuid].concat(changes), "Saved") }
  function defer(uuid, due) { act(["modify", uuid, "due:" + due], "Moved to " + due) }
  function wait(uuid, until) { act(["modify", uuid, "wait:" + until], "Waiting until " + until) }
  function undo() { if (undoable > 0) act(["undo"], "Undone") }

  // The daily digest: once per calendar day, at digestTime on the chosen
  // days, checked every half minute.
  function checkDigest() {
    if (!digestEnabled || !settled || lastError !== "") return
    var d = new Date()
    if (Model.formatHHMM(d.getHours(), d.getMinutes()) !== digestTime) return
    if (!Model.parseDigestDays(digestDays)[d.getDay()]) return
    var day = d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
    if (day === lastDigestDay) return
    lastDigestDay = day
    sendDigest()
  }

  // The notification itself, also behind "Send now" in the settings.
  function sendDigest() {
    var due = []
    for (var i = 0; i < tasks.length && due.length < 6; i++) {
      var t = tasks[i]
      if (t.bucket === "overdue" || t.bucket === "today") due.push((t.bucket === "overdue" ? "! " : "• ") + Model.escapeMarkup(t.description))
    }
    var body = due.length === 0 ? "Nothing overdue or due today." : due.join("\n")
    var more = (counts.due || 0) - due.length
    if (more > 0) body += "\n… and " + more + " more"
    notifyProc.command = ["notify-send", "-a", "Tasks", "-i", "checkbox-marked-outline", Model.summary(counts), body]
    notifyProc.running = true
  }

  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  Process {
    id: checkProc
    command: ["test", "-x", root.helperPath]
    running: root.homeDir.indexOf("/") === 0
    onExited: function(exitCode) {
      root.helperAvailable = exitCode === 0
      if (!root.helperAvailable) root.lastError = "taskbridge is not installed. Run dist/install.sh from the plugin folder."
      else if (root.settled) root.refresh()
    }
  }

  Process {
    id: snapProc
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: snapProc.output = text
    }
    onExited: function(exitCode) {
      var data = root.parse(snapProc.output)
      snapProc.output = ""
      root.refreshing = false
      if (!data) {
        root.lastError = exitCode === 127 ? "taskbridge is not installed." : "taskbridge gave no answer (exit " + exitCode + ")"
        return
      }
      root.taskAvailable = data.available !== false
      if (!data.ok) {
        root.lastError = String(data.error || "task failed")
        return
      }
      // The JS engine follows the zone the helper bucketed in.
      if (typeof Date.timeZoneUpdated === "function") Date.timeZoneUpdated()
      root.tasks = data.tasks || []
      root.counts = data.counts || {}
      root.projects = data.projects || []
      // A helper older than the plugin returns no filters at all, and the
      // panel says so rather than showing an empty row of chips.
      root.filtersSupported = data.filters !== undefined
      root.filterList = data.filters || []
      root.taskVersion = String(data.taskVersion || "")
      root.lastError = ""
      root.lastRefresh = Date.now()
      root.generation++
    }
  }

  Process {
    id: actProc
    property string label: ""
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: actProc.output = text
    }
    onExited: function(exitCode) {
      var data = root.parse(actProc.output)
      actProc.output = ""
      if (data && data.ok) {
        root.lastAction = actProc.label
        root.lastError = ""
        if (actProc.label === "Undone") root.undoable = Math.max(0, root.undoable - 1)
        else root.undoable++
      } else {
        root.lastError = data && data.error ? String(data.error) : (actProc.label + " failed")
      }
      root.busy = root._queue.length > 0
      root.refresh()
      root._next()
    }
  }

  Process {
    id: syncProc
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: syncProc.output = text
    }
    onExited: function(exitCode) {
      var data = root.parse(syncProc.output)
      syncProc.output = ""
      root.syncing = false
      if (data && data.ok && data.skipped) {
        root.syncError = "No sync server configured"
      } else if (data && data.ok) {
        root.lastSync = Date.now()
        root.syncError = ""
      } else {
        root.syncError = data && data.error ? String(data.error) : "sync failed"
      }
      root.refresh()
      root._next()
    }
  }

  Process {
    id: notifyProc
  }

  // Belt and braces: the helper has its own timeout, but if it ever failed
  // to exit the shell must not wait on it forever.
  Timer {
    interval: 20000
    running: snapProc.running
    onTriggered: { snapProc.running = false; root.refreshing = false; root.lastError = "The helper did not answer in time." }
  }

  Timer {
    interval: 20000
    running: actProc.running
    onTriggered: { actProc.running = false; root.busy = false; root.lastError = actProc.label + " did not finish in time."; root._next() }
  }

  Timer {
    interval: 90000
    running: syncProc.running
    onTriggered: { syncProc.running = false; root.syncing = false; root.syncError = "Sync did not finish in time."; root._next() }
  }

  Timer {
    interval: 30000
    running: root.settled
    repeat: true
    onTriggered: root.checkDigest()
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: root.settled && root.helperAvailable
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: Math.max(1, root.syncMinutes) * 60000
    running: root.settled && root.helperAvailable && root.syncMinutes > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sync()
  }
}
