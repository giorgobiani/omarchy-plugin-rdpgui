import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var settings: ({})

  property var connections: []
  property var vpns: []
  property bool clientInstalled: true
  // Required packages pacman doesn't have yet; the panel offers to install them.
  property var missingPackages: []
  // idle | vpn | checking | prompt | connecting
  property string phase: "idle"
  property string activeId: ""
  property var prompt: null
  property string statusText: ""
  property string lastError: ""

  readonly property string helperPath: Qt.resolvedUrl("helper.py").toString().replace(/^file:\/\//, "")
  readonly property bool saving: saveProcess.running
  readonly property int activeCount: {
    var n = 0
    for (var i = 0; i < connections.length; i++) if (connections[i].active) n++
    return n
  }
  readonly property int refreshIntervalSec: Math.max(2, parseInt(settings && settings.refreshIntervalSec) || 5)

  signal saved(string id)

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  // Runs `omarchy pkg add` in Omarchy's floating terminal, where sudo can ask
  // for the password. The panel picks up the result on its next refresh.
  function installMissing() {
    if (missingPackages.length === 0) return
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "omarchy pkg add " + missingPackages.join(" ")])
  }

  function connectionById(id) {
    for (var i = 0; i < connections.length; i++) if (connections[i].id === id) return connections[i]
    return null
  }

  function vpnName(uuid) {
    for (var i = 0; i < vpns.length; i++) if (vpns[i].uuid === uuid) return vpns[i].name
    return ""
  }

  function connect(id) {
    if (connectProcess.running || !id) return
    lastError = ""
    prompt = null
    activeId = id
    phase = "checking"
    statusText = "Starting…"
    connectProcess.command = ["python3", helperPath, "connect", id]
    connectProcess.running = true
  }

  function answer(text, remember) {
    if (!connectProcess.running || phase !== "prompt") return
    connectProcess.write(JSON.stringify({ answer: String(text), remember: remember === true }) + "\n")
    prompt = null
    phase = "connecting"
  }

  function cancel() {
    if (!connectProcess.running) return
    if (phase === "prompt") connectProcess.write(JSON.stringify({ cancel: true }) + "\n")
    else connectProcess.signal(15)
  }

  // Click on a bookmark: jump to a live session, otherwise open one.
  function activate(id) {
    var conn = connectionById(id)
    if (!conn) return
    if (conn.active) run(["focus", id])
    else if (phase !== "idle" && activeId === id) cancel()
    else connect(id)
  }

  function disconnect(id) { run(["disconnect", id]) }
  function deleteConnection(id) { run(["delete", id]) }

  function run(args) {
    if (controlProcess.running) return
    controlProcess.command = ["python3", helperPath].concat(args)
    controlProcess.running = true
  }

  // Sent over stdin so the password never shows up in argv / ps.
  function save(profile) {
    if (saveProcess.running) return
    lastError = ""
    saveProcess.payload = JSON.stringify(profile)
    saveProcess.running = true
  }

  function handleEvent(line) {
    var ev
    try { ev = JSON.parse(line) } catch (e) { return }
    if (ev.event === "prompt") {
      prompt = ev
      phase = "prompt"
      statusText = ""
    } else if (ev.event === "state") {
      if (ev.state === "vpn" || ev.state === "checking" || ev.state === "connecting") {
        phase = ev.state
        statusText = ev.text || ""
      } else if (ev.state === "connected") {
        statusText = ""
      }
    } else if (ev.event === "log") {
      statusText = ev.text
    } else if (ev.event === "error") {
      lastError = ev.text
    }
  }

  Process {
    id: listProcess
    command: ["python3", root.helperPath, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.connections = parsed.connections || []
          root.vpns = parsed.vpns || []
          root.clientInstalled = parsed.clientInstalled !== false
          root.missingPackages = parsed.missing || []
        } catch (e) {
          root.lastError = "Could not read Remote Desktop bookmarks"
        }
      }
    }
  }

  Process {
    id: connectProcess
    stdinEnabled: true
    stdout: SplitParser { onRead: function(data) { root.handleEvent(data) } }
    onExited: function(exitCode) {
      root.phase = "idle"
      root.prompt = null
      root.statusText = ""
      root.refresh()
    }
  }

  Process {
    id: saveProcess
    property string payload: ""
    command: ["python3", root.helperPath, "save"]
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: SplitParser {
      onRead: function(data) {
        var ev
        try { ev = JSON.parse(data) } catch (e) { return }
        if (ev.event === "error") root.lastError = ev.text
        else if (ev.event === "saved") root.saved(ev.id)
      }
    }
    onExited: root.refresh()
  }

  Process {
    id: controlProcess
    onExited: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
