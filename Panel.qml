import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "shota.rdp"
  ipcTarget: "shota.rdp"
  manageIpc: false

  property int rowIndex: 0
  property bool cursorActive: false
  // Editor: editing opens the form; editId is "" for a new bookmark.
  property bool editing: false
  property string editId: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var prompt: rdp.prompt
  readonly property bool promptOpen: rdp.phase === "prompt" && prompt !== null
  readonly property var working: rdp.phase !== "idle" ? rdp.connectionById(rdp.activeId) : null

  readonly property string heroMeta: {
    if (rdp.phase === "vpn") return "Connecting VPN…"
    if (rdp.phase === "checking") return "Checking server…"
    if (rdp.phase === "prompt") return "Waiting for you"
    if (rdp.phase === "connecting") return "Opening session…"
    if (rdp.activeCount === 1) return "1 session open"
    if (rdp.activeCount > 1) return rdp.activeCount + " sessions open"
    return rdp.connections.length === 0 ? "No bookmarks yet" : "No open sessions"
  }

  function activateRow(index) {
    if (index === rdp.connections.length) return startEdit("")
    var conn = rdp.connections[index]
    if (!conn) return
    rdp.activate(conn.id)
    if (conn.active) close()
  }

  function startEdit(id) {
    editId = id || ""
    editing = true
    editor.load(id ? rdp.connectionById(id) : null)
  }

  function stopEdit() {
    editing = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    rdp.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A prompt arriving while the panel is closed (e.g. after the VPN came up) pops it open.
  onPromptOpenChanged: if (promptOpen && !opened) open()

  Service {
    id: rdp
    settings: root.settings
    onSaved: function(id) { root.stopEdit() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { rdp.refresh(); return "ok" }
    function status(): string { return root.heroMeta }
    function connect(name: string): string {
      for (var i = 0; i < rdp.connections.length; i++) {
        var c = rdp.connections[i]
        if (c.name === name || c.id === name) { rdp.activate(c.id); if (!c.active) root.open(); return "ok" }
      }
      return "not found"
    }
    function disconnect(name: string): string {
      for (var i = 0; i < rdp.connections.length; i++) {
        var c = rdp.connections[i]
        if (c.name === name || c.id === name) { rdp.disconnect(c.id); return "ok" }
      }
      return "not found"
    }
    function cancel(): string { rdp.cancel(); return "ok" }
    function add(): string { root.open(); root.startEdit(""); return "ok" }
    function edit(name: string): string {
      for (var i = 0; i < rdp.connections.length; i++) {
        var c = rdp.connections[i]
        if (c.name === name || c.id === name) { root.open(); root.startEdit(c.id); return "ok" }
      }
      return "not found"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢹"
    foreground: rdp.activeCount > 0 ? root.barForeground : Qt.darker(root.barForeground, 1.55)
    tooltipText: root.heroMeta
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The editor and the prompt field own their keys (Esc included).
      blocked: (root.promptOpen && promptCard.fieldFocused) || (root.editing && !root.promptOpen)

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy === 0) return
        // Rows are the bookmarks followed by the "Add" row.
        root.rowIndex = Math.max(0, Math.min(rdp.connections.length, root.rowIndex + dy))
      }
      onActivateRequested: {
        if (root.promptOpen && root.prompt.kind === "cert") return rdp.answer("yes")
        if (root.cursorActive) root.activateRow(root.rowIndex)
      }
      onCloseRequested: {
        if (root.promptOpen) rdp.cancel()
        else root.close()
      }
      onDeleteRequested: {
        var conn = rdp.connections[root.rowIndex]
        if (conn && conn.active) rdp.disconnect(conn.id)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") rdp.refresh()
        else if (t === "n" || t === "N") root.startEdit("")
        else if ((t === "e" || t === "E") && rdp.connections[root.rowIndex]) root.startEdit(rdp.connections[root.rowIndex].id)
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.working ? root.working.name : "Remote Desktop"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: rdp.activeCount > 0 ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰢹"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          RowLayout {
            visible: rdp.missingPackages.length > 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: "Missing packages: " + rdp.missingPackages.join(", ")
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Install"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                rdp.installMissing()
                root.close()
              }
            }
          }

          PromptCard {
            id: promptCard
            visible: root.promptOpen
            width: parent.width
          }

          EditorCard {
            id: editor
            visible: root.editing && !root.promptOpen
            width: parent.width
          }

          RowLayout {
            visible: statusLine.text !== "" && !root.promptOpen
            width: parent.width
            spacing: Style.space(8)

            Text {
              id: statusLine
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: rdp.lastError !== "" ? rdp.lastError : rdp.statusText
              color: rdp.lastError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              visible: rdp.phase !== "idle" && rdp.phase !== "prompt"
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: rdp.cancel()
            }
          }

          PanelSeparator {
            visible: rows.visible
            foreground: root.foreground
          }

          Column {
            id: rows
            visible: !root.editing && !root.promptOpen
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "COMPUTERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: rdp.connections
              ConnectionRow {
                required property var modelData
                required property int index
                width: rows.width
                conn: modelData
                rowIndex: index
              }
            }

            AddRow {
              width: rows.width
            }
          }
        }
      }
    }
  }

  // Login step: certificate trust, username or password. Enter submits,
  // Esc cancels the connection attempt.
  component PromptCard: Column {
    id: card
    readonly property bool isCert: root.prompt ? root.prompt.kind === "cert" : false
    readonly property bool fieldFocused: field.activeFocus
    property bool remember: false
    spacing: Style.space(8)

    function submit() {
      if (field.text.length === 0) return
      var value = field.text
      field.text = ""
      rdp.answer(value, root.prompt && root.prompt.canRemember && card.remember)
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      text: root.prompt ? root.prompt.message : ""
      color: card.isCert && root.prompt && root.prompt.changed ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: card.isCert
      width: parent.width
      text: root.prompt && root.prompt.pin ? root.prompt.pin : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WrapAnywhere
    }

    Text {
      textFormat: Text.PlainText
      visible: !card.isCert
      text: root.prompt ? root.prompt.label : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    RowLayout {
      visible: !card.isCert
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: field
        Layout.fillWidth: true
        password: root.prompt ? root.prompt.secret === true : false
        placeholderText: root.prompt ? root.prompt.label : ""
        foreground: root.foreground
        font.family: root.fontFamily
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onAccepted: card.submit()
        Keys.onEscapePressed: rdp.cancel()
      }

      PanelActionButton {
        iconText: "󰄬"
        tooltipText: "Submit"
        enabled: field.text.length > 0
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: card.submit()
      }
    }

    Toggle {
      visible: root.prompt ? root.prompt.canRemember === true : false
      width: parent.width
      label: "Remember password"
      description: "Stored in your keyring (Secret Service)"
      checked: card.remember
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: card.remember = !card.remember
    }

    Row {
      visible: card.isCert
      spacing: Style.space(6)
      Button {
        text: "Trust"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: rdp.answer("yes")
      }
      Button {
        text: "Cancel"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: rdp.answer("no")
      }
    }

    Connections {
      target: root
      function onPromptChanged() {
        if (!root.prompt) return
        field.text = root.prompt.value || ""
        card.remember = root.prompt.remember === true
        if (root.prompt.kind !== "cert") Qt.callLater(function() { field.forceActiveFocus(); field.selectAll() })
        else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }
  }

  component ConnectionRow: CursorSurface {
    id: row
    property var conn: null
    property int rowIndex: 0
    readonly property bool isActive: conn ? conn.active === true : false
    readonly property bool isWorking: conn && rdp.phase !== "idle" && rdp.activeId === conn.id
    readonly property string subtitle: {
      if (!conn) return ""
      if (isWorking) return root.heroMeta
      if (isActive) return "Open · click to show"
      var via = conn.vpn ? rdp.vpnName(conn.vpn) : ""
      return conn.host + (via ? " · via " + via : "")
    }

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.rowIndex = row.rowIndex }
      onClicked: root.activateRow(row.rowIndex)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: row.isActive ? "󰍹" : "󰶐"
        color: root.foreground
        opacity: row.isActive ? 1.0 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.conn ? row.conn.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: row.conn ? row.conn.rememberPassword === true : false
        text: "󰌾"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        visible: row.isActive
        iconText: "󰅖"
        tooltipText: "Disconnect"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: if (row.conn) rdp.disconnect(row.conn.id)
      }

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Edit"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: if (row.conn) root.startEdit(row.conn.id)
      }
    }
  }

  component AddRow: CursorSurface {
    hasCursor: root.cursorActive && root.rowIndex === rdp.connections.length
    foreground: root.foreground
    implicitHeight: addContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.rowIndex = rdp.connections.length }
      onClicked: root.startEdit("")
    }

    RowLayout {
      id: addContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: "󰐕"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        Layout.fillWidth: true
        text: rdp.connections.length === 0 ? "Add your first computer" : "Add computer"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // Create / edit a bookmark. The password is only sent when typed; leaving
  // it blank keeps whatever is already in the keyring.
  component EditorCard: Column {
    id: form
    property bool confirmDelete: false
    property bool hasSavedPassword: false
    property bool remember: false
    property string vpn: ""
    property bool fullscreen: false
    property int scale: 0
    property bool clipboard: true
    property bool shareHome: false
    property bool sound: true
    property bool kerberos: false
    property bool grabKeyboard: false
    readonly property bool isNew: root.editId === ""
    readonly property bool valid: nameField.text.trim() !== "" && hostField.text.trim() !== ""
    readonly property var vpnOptions: {
      var opts = [{ value: "none", label: "None — connect directly" }]
      for (var i = 0; i < rdp.vpns.length; i++) opts.push({ value: rdp.vpns[i].uuid, label: rdp.vpns[i].name })
      return opts
    }
    spacing: Style.space(8)

    function load(conn) {
      confirmDelete = false
      nameField.text = conn ? conn.name : ""
      hostField.text = conn ? conn.host : ""
      userField.text = conn ? (conn.username || "") : ""
      domainField.text = conn ? (conn.domain || "") : ""
      gatewayField.text = conn ? (conn.gateway || "") : ""
      passwordField.text = ""
      hasSavedPassword = conn ? conn.rememberPassword === true : false
      remember = hasSavedPassword
      vpn = conn ? (conn.vpn || "") : ""
      fullscreen = conn ? conn.fullscreen === true : false
      scale = conn ? (conn.scale || 0) : 0
      clipboard = conn ? conn.clipboard !== false : true
      shareHome = conn ? conn.shareHome === true : false
      sound = conn ? conn.sound !== false : true
      kerberos = conn ? conn.kerberos === true : false
      grabKeyboard = conn ? conn.grabKeyboard === true : false
      Qt.callLater(function() { nameField.focusInput() })
    }

    function submit() {
      if (!valid || rdp.saving) return
      var profile = {
        id: root.editId,
        name: nameField.text.trim(),
        host: hostField.text.trim(),
        username: userField.text.trim(),
        domain: domainField.text.trim(),
        gateway: gatewayField.text.trim(),
        password: form.remember ? passwordField.text : "",
        rememberPassword: form.remember,
        vpn: form.vpn,
        fullscreen: form.fullscreen,
        scale: form.scale,
        clipboard: form.clipboard,
        shareHome: form.shareHome,
        sound: form.sound,
        kerberos: form.kerberos,
        grabKeyboard: form.grabKeyboard
      }
      passwordField.text = ""
      rdp.save(profile)
    }

    PanelSectionHeader {
      text: form.isNew ? "NEW COMPUTER" : "EDIT COMPUTER"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    FormField { id: nameField; label: "Name"; placeholder: "Office PC"; next: hostField }
    FormField { id: hostField; label: "Computer (host or host:port)"; placeholder: "pc01.corp.example.com"; next: userField }
    FormField { id: userField; label: "Username (optional)"; placeholder: "Asked when connecting if empty"; next: domainField }
    FormField { id: domainField; label: "Domain (optional)"; placeholder: "CORP"; next: form.remember ? passwordField : null }

    Toggle {
      width: parent.width
      label: "Remember password"
      description: form.remember && form.hasSavedPassword && passwordField.text === ""
        ? "Saved in your keyring — type to replace"
        : "Stored in your keyring (Secret Service), never in a file"
      checked: form.remember
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.remember = !form.remember
    }

    FormField {
      id: passwordField
      visible: form.remember
      label: "Password"
      password: true
      placeholder: form.hasSavedPassword ? "••••••••  (unchanged)" : "Password"
    }

    FormLabel { text: "Connect VPN first" }
    Dropdown {
      width: parent.width
      showLabel: false
      value: form.vpn === "" ? "none" : form.vpn
      options: form.vpnOptions
      fontFamily: root.fontFamily
      onChanged: function(value) { form.vpn = value === "none" ? "" : value }
    }

    FormLabel { text: "Display" }
    Dropdown {
      width: parent.width
      showLabel: false
      value: form.fullscreen ? "full" : "window"
      fontFamily: root.fontFamily
      options: [
        { value: "window", label: "Window (resizes with the tile)" },
        { value: "full", label: "Full screen" }
      ]
      onChanged: function(value) { form.fullscreen = value === "full" }
    }

    FormLabel { text: "Scale" }
    Dropdown {
      width: parent.width
      showLabel: false
      value: String(form.scale)
      fontFamily: root.fontFamily
      options: [
        { value: "0", label: "Automatic" },
        { value: "100", label: "100%" },
        { value: "125", label: "125%" },
        { value: "150", label: "150%" },
        { value: "175", label: "175%" },
        { value: "200", label: "200%" }
      ]
      onChanged: function(value) { form.scale = parseInt(value) || 0 }
    }

    Toggle {
      width: parent.width
      label: "Shared clipboard"
      description: "Copy and paste between Omarchy and Windows"
      checked: form.clipboard
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.clipboard = !form.clipboard
    }
    Toggle {
      width: parent.width
      label: "Share home folder"
      description: "Your home folder shows up as a drive in Windows"
      checked: form.shareHome
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.shareHome = !form.shareHome
    }
    Toggle {
      width: parent.width
      label: "Play sound here"
      description: "Bring the remote computer's audio to this machine"
      checked: form.sound
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.sound = !form.sound
    }

    Toggle {
      width: parent.width
      label: "Send shortcuts to Windows"
      description: "Grab keyboard and mouse (Alt+Tab, Win key go to the remote). Off keeps Hyprland shortcuts working"
      checked: form.grabKeyboard
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.grabKeyboard = !form.grabKeyboard
    }

    Toggle {
      width: parent.width
      label: "Use Kerberos"
      description: "Only for domain-joined PCs on a network with a domain controller"
      checked: form.kerberos
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: form.kerberos = !form.kerberos
    }

    FormField { id: gatewayField; label: "RD Gateway (optional)"; placeholder: "rdgw.corp.example.com"; next: null }

    Row {
      spacing: Style.space(6)
      Button {
        text: rdp.saving ? "Saving…" : "Save"
        bordered: true
        enabled: form.valid && !rdp.saving
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: form.submit()
      }
      Button {
        text: "Cancel"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.stopEdit()
      }
      Button {
        visible: !form.isNew
        text: form.confirmDelete ? "Really delete?" : "Delete"
        bordered: true
        foreground: form.confirmDelete ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        onClicked: {
          if (!form.confirmDelete) { form.confirmDelete = true; return }
          rdp.deleteConnection(root.editId)
          root.stopEdit()
        }
      }
    }
  }

  component FormLabel: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component FormField: Column {
    id: ff
    property string label: ""
    property string placeholder: ""
    property bool password: false
    property Item next: null
    property alias text: input.text
    function focusInput() { input.forceActiveFocus() }
    width: parent ? parent.width : 0
    spacing: Style.space(3)

    Text {
      text: ff.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    TextField {
      id: input
      width: parent.width
      password: ff.password
      placeholderText: ff.placeholder
      foreground: root.foreground
      font.family: root.fontFamily
      horizontalPadding: Style.spacing.controlGap
      verticalPadding: Style.spacing.controlPaddingY
      onAccepted: ff.next ? ff.next.focusInput() : editor.submit()
      Keys.onEscapePressed: root.stopEdit()
    }
  }
}
