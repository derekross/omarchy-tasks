import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar pill: a checklist glyph and the number of tasks that need
// attention. Left click opens the panel, right click opens it on the add
// field, middle click syncs. The service does the reading; this only shows.
BarWidget {
  id: root
  moduleName: "derekross.tasks"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("derekross.tasks") : null

  readonly property string countMode: String(setting("countMode", "due"))
  readonly property bool showWhenEmpty: setting("showWhenEmpty", true) !== false

  readonly property var counts: service ? service.counts : ({})
  readonly property var filterList: service ? service.filterList : []
  // countMode is a filter's name or one of the built-in modes.
  readonly property var namedFilter: Model.findFilter(filterList, countMode)
  readonly property int count: Model.countForPill(counts, countMode, filterList)
  readonly property int overdue: counts && counts.overdue ? counts.overdue : 0
  // A filter of the user's own naming is urgent when *it* has something in
  // it; the built-in modes are urgent on anything overdue.
  readonly property bool alerting: namedFilter ? count > 0 : overdue > 0
  readonly property bool healthy: service ? (service.helperAvailable && service.taskAvailable && service.lastError === "") : false

  readonly property string label: count > 0 ? "  " + count : ""
  readonly property string tooltip: {
    if (!service) return "Tasks service is not running. Enable the plugin with omarchy plugin enable derekross.tasks."
    if (!service.helperAvailable) return "The omarchy-taskbridge helper is not installed. Run dist/install.sh from the plugin folder."
    if (!service.taskAvailable) return "Taskwarrior is not installed. Install the task package."
    if (service.lastError) return service.lastError
    if (namedFilter) {
      var what = Model.filterSummary(namedFilter)
      return (what === "" ? namedFilter.name : namedFilter.name + " · " + what) + " — " + Model.plural(count, "task")
    }
    return Model.summary(counts)
  }

  function pushSettings() {
    if (service && typeof service.configure === "function") service.configure(settings)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  onBarChanged: injectPanel()
  onServiceChanged: { pushSettings(); injectPanel() }
  onSettingsChanged: { pushSettings(); injectPanel() }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function openToAdd() { if (panelLoader.item) panelLoader.item.openToAdd() }
  function openSettings() { if (panelLoader.item) panelLoader.item.openSettings() }
  function editFirst() { if (panelLoader.item) panelLoader.item.editFirst() }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  visible: !healthy || count > 0 || showWhenEmpty
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "derekross.tasks"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function add(): void { root.openToAdd() }
    function settings(): void { root.openSettings() }
    function edit(): void { root.editFirst() }
    function refresh(): void { if (root.service) root.service.refresh() }
    function sync(): void { if (root.service) root.service.sync() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    active: root.alerting || !root.healthy
    useActiveColor: true
    dimmed: root.healthy && root.count === 0
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.service) root.service.sync() }
      else if (b === Qt.RightButton) root.openToAdd()
      else root.togglePanel()
    }
  }
}
