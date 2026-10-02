import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The gear's second tab: the filter chips the panel shows, and what each one
// means. The chips are matched by the helper, so the count on each one is the
// number of rows the panel shows for it and the number the bar can put on the
// pill. Every edit is written straight to shell.json through the panel's
// persistSettings and comes back on the next snapshot.
Column {
  id: settings

  // The filters as the helper last echoed them: name, window, selectors and
  // count. The projects and tags worth offering come from the tasks.
  property var filters: []
  property var projects: []
  property var tags: []
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal changed(var values)
  signal closed()

  // The helper caps the list at one per digit key plus a few for h/l.
  readonly property int maxFilters: 12

  readonly property bool anyPopupOpen: {
    for (var i = 0; i < editors.count; i++) {
      var card = editors.itemAt(i)
      if (card && card.anyPopupOpen) return true
    }
    return false
  }

  // A name being typed must keep the keyboard: the panel's own keys would
  // otherwise read "d" as "done the focused task".
  readonly property bool anyFieldFocused: {
    for (var i = 0; i < editors.count; i++) {
      var card = editors.itemAt(i)
      if (card && card.fieldFocused) return true
    }
    return false
  }

  spacing: Style.space(8)

  // ---- Editing the list. Every change sends the whole list, so the helper
  // and shell.json always agree on one document.

  function publish(list) {
    settings.changed({ filters: list })
  }

  // The helper's echo carries a `count` and a normalised window; both are the
  // helper's to set, so only the fields it reads are sent back.
  function editable(list) {
    var out = []
    var items = Model.arrayFrom(list)
    for (var i = 0; i < items.length; i++) out.push(Model.filterInput(items[i]))
    return out
  }

  function update(index, patch) {
    var list = editable(settings.filters)
    if (index < 0 || index >= list.length) return
    for (var key in patch) list[index][key] = patch[key]
    publish(list)
  }

  function addFilter() {
    if (settings.filters.length >= settings.maxFilters) return
    var list = editable(settings.filters)
    list.push(Model.draftFilter("Filter " + (list.length + 1)))
    publish(list)
  }

  function removeFilter(index) {
    var list = editable(settings.filters)
    if (index < 0 || index >= list.length) return
    list.splice(index, 1)
    publish(list)
  }

  function moveFilter(index, delta) {
    var list = editable(settings.filters)
    var to = index + delta
    if (index < 0 || index >= list.length || to < 0 || to >= list.length) return
    var moved = list.splice(index, 1)[0]
    list.splice(to, 0, moved)
    publish(list)
  }

  // An empty list is not "no chips": the helper hands back its own defaults.
  function resetToDefaults() {
    settings.changed({ filters: [] })
  }

  // ---- Options and copy.

  function timeOptions() {
    var out = []
    for (var i = 0; i < Model.TIME_KEYS.length; i++) {
      out.push({ value: Model.TIME_KEYS[i], label: Model.TIME_LABELS[Model.TIME_KEYS[i]] })
    }
    return out
  }

  function priorityOptions() {
    return [
      { value: "", label: "Any" },
      { value: "H", label: "High" },
      { value: "M", label: "Medium" },
      { value: "L", label: "Low" }
    ]
  }

  function priorityModeOptions() {
    return [
      { value: "exact", label: "Exactly" },
      { value: "atleast", label: "Or above" }
    ]
  }

  function tagModeOptions() {
    return [
      { value: "any", label: "Any of them" },
      { value: "all", label: "All of them" }
    ]
  }

  function valuesOf(values) {
    return Model.arrayFrom(values).map(function(v) { return String(v) })
  }

  function explain(filter) {
    var summary = Model.filterSummary(filter)
    if (summary === "") summary = "everything pending"
    var count = Number(filter && filter.count ? filter.count : 0)
    return count + (count === 1 ? " task: " : " tasks: ") + summary
  }

  // ---- Heading.

  Item {
    width: parent.width
    implicitHeight: Math.max(title.implicitHeight, closeButton.implicitHeight)

    Text {
      id: title
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Filters"
      color: settings.foreground
      font.family: settings.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰅙"
      tooltipText: "Back to the list"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      onClicked: settings.closed()
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: settings.filters.length === 0
    width: parent.width
    text: "No filters yet. The panel is showing the built-in chips (Due, Today, Week, Month, Quarter, All); add one to define your own."
    color: settings.dim
    font.family: settings.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // ---- One card per chip.

  Repeater {
    id: editors
    model: settings.filters

    delegate: BorderSurface {
      id: card
      required property var modelData
      required property int index

      width: parent ? parent.width : 0
      implicitHeight: cardColumn.implicitHeight + Style.space(14)
      radius: Style.cornerRadius
      color: "transparent"
      borderSpec: Border.controlSpec("normal", settings.foreground, Color.accent)

      readonly property bool anyPopupOpen: timeBox.popupOpen || priorityBox.popupOpen
        || priorityModeBox.popupOpen || tagBox.popupOpen || tagModeBox.popupOpen
        || projectBox.popupOpen
      readonly property bool fieldFocused: nameField.activeFocus

      function patch(values) { settings.update(card.index, values) }

      Column {
        id: cardColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(7)
        spacing: Style.space(5)

        Row {
          width: parent.width
          spacing: Style.space(4)

          TextField {
            id: nameField
            width: parent.width - cardButtons.width - parent.spacing
            text: String(card.modelData.name === undefined ? "" : card.modelData.name)
            placeholderText: "Filter name"
            foreground: settings.foreground
            font.family: settings.fontFamily
            font.pixelSize: Style.font.body
            onEditingFinished: card.patch({ name: text })
          }

          Row {
            id: cardButtons
            spacing: Style.space(2)

            PanelActionButton {
              iconText: "󰁝"
              enabled: card.index > 0
              opacity: enabled ? 1 : 0.4
              tooltipText: "Move this chip left"
              foreground: settings.foreground
              fontFamily: settings.fontFamily
              onClicked: settings.moveFilter(card.index, -1)
            }

            PanelActionButton {
              iconText: "󰁜"
              enabled: card.index < settings.filters.length - 1
              opacity: enabled ? 1 : 0.4
              tooltipText: "Move this chip right"
              foreground: settings.foreground
              fontFamily: settings.fontFamily
              onClicked: settings.moveFilter(card.index, 1)
            }

            PanelActionButton {
              iconText: "󰅖"
              tooltipText: "Remove this chip"
              foreground: settings.foreground
              fontFamily: settings.fontFamily
              onClicked: settings.removeFilter(card.index)
            }
          }
        }

        Row {
          spacing: Style.space(8)

          Dropdown {
            id: timeBox
            label: "Time"
            width: Style.space(150)
            value: Model.normalizeTime(card.modelData.time)
            options: settings.timeOptions()
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(v) { card.patch({ time: v }) }
          }

          Dropdown {
            id: priorityBox
            label: "Priority"
            width: Style.space(120)
            value: String(card.modelData.priority === undefined ? "" : card.modelData.priority)
            options: settings.priorityOptions()
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(v) { card.patch({ priority: v }) }
          }

          Dropdown {
            id: priorityModeBox
            label: "Priority match"
            width: Style.space(150)
            enabled: String(card.modelData.priority === undefined ? "" : card.modelData.priority) !== ""
            opacity: enabled ? 1 : 0.5
            value: String(card.modelData.priorityMode === "atleast" ? "atleast" : "exact")
            options: settings.priorityModeOptions()
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(v) { card.patch({ priorityMode: v }) }
          }
        }

        Row {
          spacing: Style.space(8)

          MultiSelect {
            id: projectBox
            label: "Projects"
            width: Style.space(230)
            values: settings.valuesOf(card.modelData.projects)
            options: settings.projects
            placeholderText: "Search projects…"
            emptyText: "No projects yet"
            noSelectionText: "Any project"
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(values) { card.patch({ projects: Model.arrayFrom(values) }) }
          }

          MultiSelect {
            id: tagBox
            label: "Tags"
            width: Style.space(230)
            values: settings.valuesOf(card.modelData.tags)
            options: settings.tags
            placeholderText: "Search tags…"
            emptyText: "No tags yet"
            noSelectionText: "Any tag"
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(values) { card.patch({ tags: Model.arrayFrom(values) }) }
          }

          Dropdown {
            id: tagModeBox
            label: "Tags match"
            width: Style.space(150)
            enabled: settings.valuesOf(card.modelData.tags).length > 1
            opacity: enabled ? 1 : 0.5
            value: String(card.modelData.match === "all" ? "all" : "any")
            options: settings.tagModeOptions()
            foreground: settings.foreground
            fontFamily: settings.fontFamily
            onChanged: function(v) { card.patch({ match: v }) }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: settings.explain(card.modelData)
          color: settings.dim
          font.family: settings.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---- Footer.

  Row {
    spacing: Style.space(4)

    Button {
      text: "Add filter"
      tooltipText: settings.filters.length >= settings.maxFilters
        ? "That is as many chips as there is room for"
        : "A new chip, starting with every pending task"
      enabled: settings.filters.length < settings.maxFilters
      opacity: enabled ? 1 : 0.5
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: settings.addFilter()
    }

    Button {
      text: "Reset to defaults"
      tooltipText: "Back to Due, Today, Week, Month, Quarter, All"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: settings.resetToDefaults()
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "A chip shows the tasks that match all of its parts: the time window, the projects, the tags and the "
      + "priority. Projects are any-of; tags are any-of unless you ask for all of them. Time windows keep what "
      + "is already late, and Month and Quarter end with the calendar month and quarter. "
      + "The counts come from taskbridge. Name a chip here and `omarchy bar set derekross.tasks countMode \"<name>\"` "
      + "puts its number on the bar."
    color: settings.dim
    font.family: settings.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
