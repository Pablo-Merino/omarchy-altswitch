// Windows-style ALT+TAB window list.
//
// This is the display half only. All key handling and all state live in
// altswitch.lua next to this file, loaded from the Hyprland config. It owns the
// frozen window list and the cursor, and drives this panel over IPC:
//
//   omarchy-shell altswitch show '{"windows":[...],"index":1}'
//   omarchy-shell altswitch select 2
//   omarchy-shell altswitch hide
//
// The panel takes exclusive keyboard focus purely so that keys the switcher
// does not bind are swallowed instead of leaking into the window underneath.
// It deliberately handles no keys of its own, so there is exactly one place
// where a keypress can be interpreted.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by Omarchy's panel loader.
  property var shell: null
  property var manifest: null
  property bool opened: false
  property var windows: []
  property int selectedIndex: 0
  property string activeWindowScope: "current"

  readonly property string pluginId: String((manifest && manifest.id) || "io.github.makiwinster72.altswitch")
  readonly property var pluginEntry: {
    const config = shell ? shell.shellConfig : null
    const plugins = config && Array.isArray(config.plugins) ? config.plugins : []
    for (let i = 0; i < plugins.length; i++) {
      const entry = plugins[i]
      if (entry && entry.id === root.pluginId) return entry
    }
    return ({})
  }
  readonly property bool showIcons: pluginEntry.showIcons !== false
  readonly property string windowScope: pluginEntry.scope === "all" ? "all" : "current"

  readonly property int rowHeight: Math.max(Style.space(34), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int hintHeight: Style.space(28)
  readonly property bool chineseLocale: String(Qt.locale().name).toLowerCase().indexOf("zh") === 0
  readonly property string scopeHint: chineseLocale
    ? (activeWindowScope === "current" ? "当前工作区 · 按 A 切换到全部工作区" : "全部工作区 · 按 A 切换到当前工作区")
    : (activeWindowScope === "current" ? "Current workspace · Press A for all workspaces" : "All workspaces · Press A for current workspace")
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  readonly property int maxCardHeight: panel.height - Style.gapsOut * 2

  function updatePluginSetting(name, value) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false

    const next = ({})
    for (const key in root.pluginEntry) if (key !== "id") next[key] = root.pluginEntry[key]
    next[name] = value
    shell.updateEntryInline(root.pluginId, next)
    return true
  }

  function setPluginSetting(name, rawValue) {
    const value = String(rawValue || "").trim().toLowerCase()

    if (name === "showIcons") {
      if (value !== "true" && value !== "false") return "showIcons must be true or false"
      const enabled = value === "true"
      if (!root.updatePluginSetting(name, enabled)) return "unavailable"
      return String(enabled)
    }

    if (name === "scope") {
      if (value !== "current" && value !== "all") return "scope must be current or all"
      if (!root.updatePluginSetting(name, value)) return "unavailable"
      return value
    }

    return "unknown setting: " + name
  }

  function syncWindowScope() {
    Quickshell.execDetached([
      "hyprctl", "eval", "__altswitch_set_scope(" + JSON.stringify(root.windowScope) + ")"
    ])
  }

  onWindowScopeChanged: syncWindowScope()
  Component.onCompleted: syncWindowScope()

  function friendlyAppName(appClass) {
    const raw = String(appClass || "").trim()
    if (!raw) return "Unknown"

    // Window classes usually match a desktop-file id or StartupWMClass.
    // Let Quickshell resolve both before falling back to formatting the id.
    const entry = DesktopEntries.heuristicLookup(raw)
    if (entry && entry.name) return String(entry.name)

    let name = raw.replace(/^steam_app_/i, "")
    if (name.indexOf(".") !== -1) name = name.split(".").pop()
    name = name.replace(/[_-]+/g, " ").trim()
    return name.replace(/(^|\s)\S/g, function(letter) { return letter.toUpperCase() })
  }

  function appIcon(appClass) {
    const raw = String(appClass || "").trim()
    const entry = raw ? DesktopEntries.heuristicLookup(raw) : null
    const icon = entry ? String(entry.icon || "") : ""

    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  function show(payloadJson) {
    // Armed before anything that can throw, so a payload this panel cannot read
    // can never strand it on screen.
    watchdog.restart()

    let payload
    try {
      payload = JSON.parse(payloadJson)
    } catch (error) {
      console.warn("altswitch: unreadable payload:", error)
      root.hide()
      return
    }

    root.windows = payload.windows || []
    root.selectedIndex = payload.index || 0
    root.activeWindowScope = payload.scope === "all" ? "all" : "current"
    root.opened = root.windows.length > 0
  }

  function select(index) {
    root.selectedIndex = index
    watchdog.restart()
  }

  function hide() {
    watchdog.stop()
    root.opened = false
  }

  // A switch ends when ALT is released, which is a keybind in the Hyprland
  // config. If that release is ever missed the panel would sit on screen for
  // good, so it also gives up on its own and tells the config to reset.
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: {
      root.hide()
      Quickshell.execDetached(["hyprctl", "eval", "__altswitch_cancel()"])
    }
  }

  IpcHandler {
    target: "altswitch"

    function show(payloadJson: string): string {
      root.show(payloadJson)
      return "ok"
    }

    function select(index: int): string {
      root.select(index)
      return "ok"
    }

    function hide(): string {
      root.hide()
      return "ok"
    }

    function state(): string {
      return root.opened ? "open" : "closed"
    }

    function set(name: string, value: string): string {
      return root.setPluginSetting(name, value)
    }

    function scope(value: string): string {
      const requested = String(value || "").trim().toLowerCase()
      const wanted = requested === "toggle"
        ? (root.windowScope === "current" ? "all" : "current")
        : requested
      return root.setPluginSetting("scope", wanted)
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-altswitch"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never grab the keyboard. A grab here can outlive the switch and leave the
    // desktop with no way to dismiss it; a purely visual surface cannot.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    BorderSurface {
      id: card

      width: root.cardWidth
      // BorderSurface exposes its padding as numbers rather than insetting its
      // children, so the rows below carry the same insets by hand and the card
      // is measured to match. Filling it outright leaves dead space under the
      // last row.
      height: Math.min(
        root.maxCardHeight,
        root.windows.length * root.rowHeight + root.hintHeight + card.contentTopInset + card.contentBottomInset
      )
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      ListView {
        id: list

        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset + root.hintHeight
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        clip: true
        interactive: false
        model: root.windows
        currentIndex: root.selectedIndex
        highlightMoveDuration: 0
        // Keep the cursor on screen when there are more windows than fit.
        preferredHighlightBegin: 0
        preferredHighlightEnd: height
        highlightRangeMode: ListView.ApplyRange

        delegate: Rectangle {
          required property int index
          required property var modelData

          width: list.width
          height: root.rowHeight
          radius: Style.cornerRadius
          color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
          opacity: modelData.inScope === false ? 0.32 : 1.0

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.md

            // Workspace number, so a switch across workspaces is legible.
            Text {
              Layout.preferredWidth: Style.space(24)
              horizontalAlignment: Text.AlignRight
              text: modelData.workspace
              color: Color.menu.text
              opacity: 0.5
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Image {
              visible: root.showIcons
              Layout.preferredWidth: Style.space(24)
              Layout.preferredHeight: Style.space(24)
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: root.appIcon(modelData.appClass)
              asynchronous: true
            }

            Text {
              Layout.preferredWidth: Style.space(88)
              Layout.maximumWidth: Style.space(88)
              elide: Text.ElideRight
              text: root.friendlyAppName(modelData.appClass)
              color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
              opacity: 0.7
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: modelData.title
              color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
          }
        }
      }

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        height: root.hintHeight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.scopeHint
        color: Color.menu.text
        opacity: 0.58
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
