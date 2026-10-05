import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// In-place editor for one task: description, project, priority, due and
// tags. Save turns the difference into `task modify` arguments (see
// Model.editChanges); Cancel puts everything back. Enter saves from any
// field, Escape cancels.
Column {
  id: editor

  property var task: null
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal saved(var changes)
  signal cancelled()
  signal deleted(string uuid)

  readonly property bool anyFocused: descriptionField.activeFocus || projectField.activeFocus
    || dueField.activeFocus || tagsField.activeFocus || priorityBox.popupOpen

  spacing: Style.space(6)

  function load() {
    if (!task) return
    descriptionField.text = task.description || ""
    projectField.text = task.project || ""
    priorityBox.value = task.priority || ""
    dueField.text = Model.dueEditText(task.dueMs)
    tagsField.text = (task.tags || []).join(" ")
    descriptionField.forceActiveFocus()
    descriptionField.cursorPosition = descriptionField.text.length
  }

  function save() {
    if (!task) return
    var changes = Model.editChanges(task, {
      description: descriptionField.text,
      project: projectField.text,
      priority: priorityBox.value,
      due: dueField.text,
      tags: tagsField.text
    })
    editor.saved(changes)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      editor.save()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      editor.cancelled()
      event.accepted = true
    }
  }

  Component.onCompleted: load()

  TextField {
    id: descriptionField
    width: parent.width
    placeholderText: "Description"
    foreground: editor.foreground
    font.family: editor.fontFamily
    font.pixelSize: Style.font.bodySmall
    Keys.onPressed: function(event) { editor.handleKey(event) }
  }

  Row {
    width: parent.width
    spacing: Style.space(6)

    TextField {
      id: projectField
      width: (parent.width - Style.space(12)) * 0.34
      placeholderText: "Project"
      foreground: editor.foreground
      font.family: editor.fontFamily
      font.pixelSize: Style.font.bodySmall
      Keys.onPressed: function(event) { editor.handleKey(event) }
    }

    TextField {
      id: dueField
      width: (parent.width - Style.space(12)) * 0.36
      placeholderText: "Due: 2026-10-07, friday, eom"
      foreground: editor.foreground
      font.family: editor.fontFamily
      font.pixelSize: Style.font.bodySmall
      Keys.onPressed: function(event) { editor.handleKey(event) }
    }

    Dropdown {
      id: priorityBox
      width: (parent.width - Style.space(12)) * 0.30
      showLabel: false
      value: ""
      options: [
        { value: "", label: "No priority" },
        { value: "L", label: "Low" },
        { value: "M", label: "Medium" },
        { value: "H", label: "High" }
      ]
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      onChanged: function(v) { priorityBox.value = v }
    }
  }

  TextField {
    id: tagsField
    width: parent.width
    placeholderText: "Tags, space separated"
    foreground: editor.foreground
    font.family: editor.fontFamily
    font.pixelSize: Style.font.bodySmall
    Keys.onPressed: function(event) { editor.handleKey(event) }
  }

  Row {
    spacing: Style.space(4)

    Button {
      text: "Save"
      tooltipText: "Enter"
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      fontSize: Style.font.caption
      bordered: true
      selected: true
      onClicked: editor.save()
    }

    Button {
      text: "Cancel"
      tooltipText: "Esc"
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: editor.cancelled()
    }

    Button {
      text: "Delete"
      tooltipText: "task delete: leaves the list, u undoes it"
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: editor.deleted(editor.task ? editor.task.uuid : "")
    }
  }
}
