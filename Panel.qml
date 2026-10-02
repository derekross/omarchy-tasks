import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The tasks popup. A quick-add line, a row of filter chips (Due, Today,
// Week, Month, Quarter, All, and any you define), project chips, and the
// list grouped by project. A row expands to its notes, links and the triage
// actions: Done, Tomorrow, Next week, Snooze, Open link, Edit. Everything
// has a key, see the key catcher below.
//
// The chips and their counts come from the helper, which does the matching,
// so the bar pill can show the same number for a filter. BarWidget.qml owns
// the bar label and hands this panel the button to anchor against and the
// service that runs taskbridge.
Panel {
  id: root
  moduleName: "derekross.tasks"
  manageIpc: false

  property var anchorItem: null
  property var service: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The chips the helper matched, and the one the list is showing.
  readonly property var filters: service ? service.filterList : []
  property int filterIndex: 0
  // Kept by name so a refresh, which sends a fresh list, cannot move it.
  property string chosenFilterName: ""
  readonly property var filter: filters.length > 0 ? filters[Math.max(0, Math.min(filters.length - 1, filterIndex))] : null
  property string project: ""
  property string cursorUuid: ""
  property string expandedUuid: ""
  property string editingUuid: ""
  property bool settingsOpen: false
  // Which half of the settings is showing: "digest" or "filters".
  property string settingsTab: "digest"
  property double now: Date.now()
  readonly property bool addFocused: addField.activeFocus
  // Keys go to a text field or a dropdown instead of the list while editing.
  property bool editorFocused: false
  readonly property bool keysBlocked: addFocused || editingUuid !== ""
    || (settingsOpen && (digestSettings.anyPopupOpen || filterSettings.anyPopupOpen
      || filterSettings.anyFieldFocused))

  readonly property var allTasks: service ? service.tasks : []
  readonly property var rows: Model.sortTasks(Model.tasksForFilter(allTasks, root.filterIndex, project), root.filter)
  readonly property var groups: Model.groupByProject(rows)
  readonly property var projects: service ? service.projects : []
  readonly property var counts: service ? service.counts : ({})
  readonly property bool showHeaders: project === "" && groups.length > 1

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property string statusText: {
    if (!service) return "Tasks service is not running. Enable the plugin with omarchy plugin enable derekross.tasks."
    if (!service.helperAvailable) return "The omarchy-taskbridge helper is not installed. Run dist/install.sh from the plugin folder."
    if (!service.taskAvailable) return "Taskwarrior is not installed. Install the task package."
    if (!service.filtersSupported) return "This taskbridge is older than the plugin and knows nothing about filters. Run dist/install.sh from the plugin folder to rebuild it."
    if (service.lastError) return service.lastError
    return ""
  }

  readonly property string emptyText: {
    if (statusText !== "") return statusText
    if (rows.length > 0) return ""
    return Model.emptyText(root.filter, project)
  }

  readonly property string footerText: {
    if (!service) return ""
    var parts = []
    if (service.busy) parts.push("Working…")
    else if (service.lastAction) parts.push(service.lastAction)
    if (service.syncing) parts.push("Syncing…")
    else if (service.syncError) parts.push("Sync: " + service.syncError)
    else if (service.lastSync > 0) parts.push("Synced " + Qt.formatTime(new Date(service.lastSync), "h:mm AP"))
    return parts.join(" · ")
  }

  function open() {
    root.now = Date.now()
    if (service) service.refresh()
    root.controller.show()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function openToAdd() {
    open()
    Qt.callLater(function() { addField.forceActiveFocus() })
  }

  function openSettings() {
    open()
    root.settingsOpen = true
    root.editingUuid = ""
    root.expandedUuid = ""
  }

  // Edit the focused task, or the first one in view.
  function editFirst() {
    open()
    Qt.callLater(function() {
      var task = root.focusedTask() || (root.rows.length > 0 ? root.rows[0] : null)
      root.startEditing(task)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    expandedUuid = ""
    cursorUuid = ""
    editingUuid = ""
    settingsOpen = false
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.now = Date.now()
    if (service) service.refresh()
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
    root.editingUuid = ""
    root.expandedUuid = ""
  }

  function startEditing(task) {
    if (!task) return
    root.expandedUuid = task.uuid
    root.cursorUuid = task.uuid
    root.editingUuid = task.uuid
  }

  function stopEditing() {
    root.editingUuid = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveEdit(task, changes) {
    if (service && changes.length > 0) service.modify(task.uuid, changes)
    stopEditing()
  }

  function setFilterIndex(index) {
    if (root.filters.length === 0) return
    root.filterIndex = Math.max(0, Math.min(root.filters.length - 1, index))
    root.chosenFilterName = root.filter ? String(root.filter.name) : ""
    root.expandedUuid = ""
    root.cursorUuid = ""
  }

  function cycleFilter(delta) {
    if (root.filters.length === 0) return
    root.setFilterIndex(Model.cycleIndex(root.filters.length, root.filterIndex, delta))
  }

  // The helper sends a fresh list on every refresh, so the chip is kept by
  // name and `defaultView` only decides where it starts.
  function syncFilter() {
    if (root.filters.length === 0) { root.filterIndex = 0; return }
    var wanted = root.chosenFilterName !== "" ? root.chosenFilterName : String(root.setting("defaultView", "due"))
    var at = Model.resolveFilterIndex(root.filters, wanted, root.filterIndex)
    if (at !== root.filterIndex) root.filterIndex = at
    if (root.chosenFilterName === "" && root.filter) root.chosenFilterName = String(root.filter.name)
  }

  onFiltersChanged: root.syncFilter()

  function setProject(p) {
    root.project = root.project === p ? "" : p
    root.expandedUuid = ""
    root.cursorUuid = ""
  }

  function cycleProject(delta) {
    var names = [""]
    for (var i = 0; i < projects.length; i++) names.push(projects[i].name)
    var at = Math.max(0, names.indexOf(root.project))
    root.project = names[(at + delta + names.length) % names.length]
    root.expandedUuid = ""
    root.cursorUuid = ""
  }

  function indexOfUuid(uuid) {
    for (var i = 0; i < rows.length; i++) if (rows[i].uuid === uuid) return i
    return -1
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var at = indexOfUuid(cursorUuid)
    at = at === -1 ? (delta > 0 ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, at + delta))
    cursorUuid = rows[at].uuid
    if (expandedUuid !== "") expandedUuid = cursorUuid
  }

  function focusedTask() {
    var at = indexOfUuid(cursorUuid !== "" ? cursorUuid : expandedUuid)
    return at === -1 ? null : rows[at]
  }

  function toggleExpanded(uuid) {
    expandedUuid = expandedUuid === uuid ? "" : uuid
    cursorUuid = uuid
  }

  // The cursor stays on the next task when the focused one goes away.
  function actOn(task, fn) {
    if (!task || !service) return
    var at = indexOfUuid(task.uuid)
    fn(task)
    if (expandedUuid === task.uuid) expandedUuid = ""
    var next = at + 1 < rows.length ? rows[at + 1] : (at > 0 ? rows[at - 1] : null)
    cursorUuid = next && next.uuid !== task.uuid ? next.uuid : ""
  }

  function done(task) { actOn(task, function(t) { service.done(t.uuid) }) }
  function defer(task, due) { actOn(task, function(t) { service.defer(t.uuid, due) }) }
  function snooze(task) { actOn(task, function(t) { service.wait(t.uuid, "1w") }) }

  // No shell: the URL was checked by the helper and is checked again here,
  // then handed to Qt, which asks the desktop to open it.
  function openLink(task) {
    if (!task || !task.links || task.links.length === 0) return
    var url = String(task.links[0])
    if (!Model.isSafeLink(url)) return
    Qt.openUrlExternally(url)
    root.close()
  }


  function submitAdd() {
    var text = addField.text.trim()
    if (text === "" || !service) return
    service.add(text)
    addField.text = ""
  }

  function handleAddKey(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.submitAdd()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      if (addField.text !== "") addField.text = ""
      else keyCatcher.forceActiveFocus()
      event.accepted = true
    }
  }

  // Scroll so a row is fully visible, top first.
  function ensureVisible(item) {
    if (!item || !scroller) return
    var y = item.mapToItem(column, 0, 0).y
    var maxY = Math.max(0, scroller.contentHeight - scroller.height)
    if (y < scroller.contentY) scroller.contentY = Math.max(0, y - Style.space(4))
    else if (y + item.height > scroller.contentY + scroller.height)
      scroller.contentY = Math.min(maxY, y + item.height - scroller.height + Style.space(4))
  }

  onOpenedChanged: if (!opened) { expandedUuid = ""; cursorUuid = ""; editingUuid = ""; settingsOpen = false }

  Connections {
    target: root.service
    function onGenerationChanged() { root.now = Date.now() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.keysBlocked
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0) root.cycleFilter(dx)
      }
      onActivateRequested: { var t = root.focusedTask(); if (t) root.toggleExpanded(t.uuid) }
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false
        else if (root.expandedUuid !== "") root.expandedUuid = ""
        else if (root.cursorUuid !== "") root.cursorUuid = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var task = root.focusedTask()
        if (t === "a" || t === "A" || t === "+") addField.forceActiveFocus()
        else if (t === "d" || t === "D") root.done(task)
        else if (t === "t" || t === "T") root.defer(task, "tomorrow")
        else if (t === "w" || t === "W") root.defer(task, "1w")
        else if (t === "z" || t === "Z") root.snooze(task)
        else if (t === "o" || t === "O") root.openLink(task)
        else if (t === "e" || t === "E") root.startEditing(task)
        else if (t === "," || t === "g" || t === "G") root.toggleSettings()
        else if (t === "s" || t === "S") { if (root.service) root.service.sync() }
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "u" || t === "U") { if (root.service) root.service.undo() }
        else if (t === "[") root.cycleProject(-1)
        else if (t === "]") root.cycleProject(1)
        else if (t >= "1" && t <= "9") {
          // A digit picks a chip, and stops at the number of filters there are.
          var at = parseInt(t, 10) - 1
          if (at < root.filters.length) root.setFilterIndex(at)
        }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(8)

          // ---- Header: title, summary, actions.
          Item {
            width: parent.width
            implicitHeight: Math.max(titleColumn.implicitHeight, headerActions.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {

                textFormat: Text.PlainText
                text: "Tasks"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {

                textFormat: Text.PlainText
                width: parent.width
                text: Model.summary(root.counts)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                iconText: "󰕌"
                enabled: root.service && root.service.undoable > 0
                opacity: enabled ? 1 : 0.4
                tooltipText: enabled ? "Undo the last change made here (u)" : "Nothing to undo from this panel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.undo()
              }

              PanelActionButton {
                iconText: "󰓦"
                tooltipText: root.service && root.service.syncing ? "Syncing…" : "Sync with the server (s)"
                foreground: root.service && root.service.syncing ? Color.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.sync()
              }

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }

              PanelActionButton {
                iconText: "󰒓"
                tooltipText: root.settingsOpen ? "Back to the list (Esc)" : "Settings (g): the daily digest and the filter chips"
                foreground: root.settingsOpen ? Color.accent : root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleSettings()
              }
            }
          }

          // ---- Settings, in place of the list while open. Two tabs, because
          // nothing in the shell renders a plugin's settings for it.
          Row {
            visible: root.settingsOpen
            spacing: Style.space(4)

            Repeater {
              model: [
                { id: "digest", label: "Digest", hint: "One notification a day with what's overdue and due today" },
                { id: "filters", label: "Filters", hint: "The chips above: what each one shows, and what the bar counts" }
              ]

              Button {
                required property var modelData
                text: modelData.label
                tooltipText: modelData.hint
                selected: root.settingsTab === modelData.id
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.settingsTab = modelData.id
              }
            }
          }

          DigestSettings {
            id: digestSettings
            visible: root.settingsOpen && root.settingsTab === "digest"
            width: parent.width
            enabled: root.setting("digestEnabled", true) !== false
            time: String(root.setting("digestTime", "09:00"))
            days: String(root.setting("digestDays", Model.DEFAULT_DIGEST_DAYS))
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(values) { root.persistSettings(values) }
            onSendNow: if (root.service) root.service.sendDigest()
            onClosed: root.settingsOpen = false
          }

          FilterSettings {
            id: filterSettings
            visible: root.settingsOpen && root.settingsTab === "filters"
            width: parent.width
            filters: root.filters
            projects: {
              var out = []
              for (var i = 0; i < root.projects.length; i++) out.push(String(root.projects[i].name))
              return out
            }
            tags: Model.tagList(root.allTasks)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(values) { root.persistSettings(values) }
            onClosed: root.settingsOpen = false
          }

          // ---- Quick add. Taskwarrior parses project:, due:, +tag itself.
          TextField {
            id: addField
            visible: !root.settingsOpen
            width: parent.width
            placeholderText: "Add: Call Alex project:nostr4 due:friday +call"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Keys.onPressed: function(event) { root.handleAddKey(event) }
          }

          // ---- Filters. Whatever chips the helper was given, each with its
          // own count; the gear edits them.
          Row {
            visible: !root.settingsOpen
            spacing: Style.space(4)

            Repeater {
              model: root.filters

              Button {
                required property var modelData
                required property int index
                text: modelData.name
                tooltipText: {
                  var parts = [String(modelData.count) + (modelData.count === 1 ? " task" : " tasks")]
                  if (index < 9) parts.push("(" + (index + 1) + ")")
                  var summary = Model.filterSummary(modelData)
                  if (summary !== "") parts.push(summary)
                  return parts.join(" · ")
                }
                selected: root.filterIndex === index
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.setFilterIndex(index)
              }
            }
          }

          // ---- Project chips, only when there is more than one.
          Flow {
            width: parent.width
            spacing: Style.space(4)
            visible: !root.settingsOpen && root.projects.length > 1

            Repeater {
              model: root.projects

              Button {
                required property var modelData
                text: Model.projectLabel(modelData.name) + " " + modelData.pending
                tooltipText: modelData.overdue > 0 ? modelData.overdue + " overdue" : "Only " + Model.projectLabel(modelData.name)
                selected: root.project === modelData.name
                foreground: modelData.overdue > 0 && root.project !== modelData.name ? root.urgent : root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(7)
                verticalPadding: Style.space(3)
                onClicked: root.setProject(modelData.name)
              }
            }
          }

          PanelSeparator {
            visible: !root.settingsOpen
            width: parent.width
            foreground: root.foreground
          }

          // ---- Empty or error state.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.settingsOpen && root.emptyText !== ""
            text: root.emptyText
            color: root.statusText !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            topPadding: Style.space(6)
            bottomPadding: Style.space(6)
          }

          // ---- The list.
          Repeater {
            model: root.settingsOpen ? [] : root.groups

            Column {
              id: group
              required property var modelData
              width: column.width
              spacing: 0

              PanelSectionHeader {
                visible: root.showHeaders
                text: Model.projectLabel(group.modelData.project).toUpperCase() + "  " + group.modelData.tasks.length
                foreground: root.dim
                fontFamily: root.fontFamily
                topPadding: Style.space(6)
                bottomPadding: Style.space(2)
              }

              Repeater {
                model: group.modelData.tasks

                Item {
                  id: row
                  required property var modelData
                  readonly property var task: modelData
                  readonly property bool expanded: root.expandedUuid === task.uuid
                  readonly property bool editing: root.editingUuid === task.uuid
                  readonly property bool hasCursor: root.cursorUuid === task.uuid
                  readonly property string dueText: Model.dueLabel(task.dueMs, root.now)
                  readonly property color dueColor: task.bucket === "overdue" ? root.urgent
                    : task.bucket === "today" ? Color.accent : root.dim

                  width: column.width
                  implicitHeight: body.implicitHeight + (expanded ? detail.implicitHeight : 0)
                  height: implicitHeight

                  onHasCursorChanged: if (hasCursor) root.ensureVisible(row)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: row.hasCursor ? root.selectedFill : (bodyMouse.containsMouse ? root.hoverFill : "transparent")
                  }

                  Item {
                    id: body
                    width: parent.width
                    implicitHeight: Math.max(Style.spacing.popupRowHeight, descriptionText.implicitHeight + Style.space(10))

                    MouseArea {
                      id: bodyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                      onClicked: function(mouse) {
                        if (row.editing) return
                        if (mouse.button === Qt.MiddleButton) root.done(row.task)
                        else root.toggleExpanded(row.task.uuid)
                      }
                    }

                    PanelActionButton {
                      id: doneButton
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: "󰄬"
                      tooltipText: "Done (d)"
                      foreground: root.dim
                      hoverColor: Color.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      onClicked: root.done(row.task)
                    }

                    Text {

                      textFormat: Text.PlainText
                      id: descriptionText
                      anchors.left: doneButton.right
                      anchors.leftMargin: Style.space(4)
                      anchors.right: meta.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      text: row.task.description
                      color: row.task.blocked ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.strikeout: false
                      elide: row.expanded ? Text.ElideNone : Text.ElideRight
                      wrapMode: row.expanded ? Text.WordWrap : Text.NoWrap
                      maximumLineCount: row.expanded ? 6 : 1
                    }

                    Row {
                      id: meta
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      Text {

                        textFormat: Text.PlainText
                        visible: row.task.links && row.task.links.length > 0
                        text: "󰌷"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {

                        textFormat: Text.PlainText
                        visible: row.task.priority !== ""
                        text: Model.priorityMark(row.task.priority)
                        color: row.task.priority === "H" ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {

                        textFormat: Text.PlainText
                        visible: row.dueText !== ""
                        text: row.dueText
                        color: row.dueColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                  }

                  // ---- Expanded: the facts, the notes, the buttons.
                  Column {
                    id: detail
                    visible: row.expanded
                    y: body.implicitHeight
                    x: Style.space(30)
                    width: parent.width - x - Style.space(8)
                    spacing: Style.space(6)
                    bottomPadding: Style.space(8)

                    Loader {
                      active: row.editing
                      visible: active
                      width: parent.width
                      sourceComponent: TaskEditor {
                        width: detail.width
                        task: row.task
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onSaved: function(changes) { root.saveEdit(row.task, changes) }
                        onCancelled: root.stopEditing()
                      }
                    }

                    Text {

                      textFormat: Text.PlainText
                      visible: !row.editing
                      width: parent.width
                      text: {
                        var parts = []
                        parts.push("#" + row.task.id)
                        if (row.task.project !== "") parts.push(row.task.project)
                        if (row.task.dueMs) parts.push("due " + Model.dueLong(row.task.dueMs))
                        if (row.task.tags && row.task.tags.length) parts.push("+" + row.task.tags.join(" +"))
                        if (row.task.recurring) parts.push("recurring")
                        if (row.task.blocked) parts.push("blocked")
                        parts.push("urgency " + Number(row.task.urgency).toFixed(1))
                        parts.push(Model.ageLabel(row.task.entryMs, root.now))
                        return parts.join(" · ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }

                    Repeater {
                      model: row.editing ? [] : (row.task.notes || [])

                      Text {

                        textFormat: Text.PlainText
                        required property string modelData
                        width: detail.width
                        text: "› " + modelData
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }

                    Flow {
                      visible: !row.editing
                      width: parent.width
                      spacing: Style.space(4)

                      Button {
                        text: "Done"
                        tooltipText: "task done (d)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.done(row.task)
                      }
                      Button {
                        text: "Tomorrow"
                        tooltipText: "due:tomorrow (t)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.defer(row.task, "tomorrow")
                      }
                      Button {
                        text: "Next week"
                        tooltipText: "due one week from now (w)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.defer(row.task, "1w")
                      }
                      Button {
                        text: "Snooze"
                        tooltipText: "Hide for a week: wait:1w (z)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.snooze(row.task)
                      }
                      Button {
                        visible: row.task.links && row.task.links.length > 0
                        text: "Open link"
                        tooltipText: row.task.links && row.task.links.length > 0 ? row.task.links[0] + " (o)" : ""
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.openLink(row.task)
                      }
                      Button {
                        text: "Edit"
                        tooltipText: "Change description, project, priority, due, tags (e)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: root.startEditing(row.task)
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Footer.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.footerText !== ""
            text: root.footerText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            topPadding: Style.space(4)
          }
        }
      }
    }
  }
}
