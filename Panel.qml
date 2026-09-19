import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "acer.predator"
  ipcTarget: "acer.predator"

  readonly property string cpuCapPath: "/sys/devices/system/cpu/intel_pstate/max_perf_pct"
  readonly property string sensePath: "/sys/devices/platform/acer-wmi/predator_sense"
  readonly property string statsScript: Qt.resolvedUrl("stats.sh").toString().replace("file://", "")

  // ---- live telemetry (from stats.sh) ----
  property var stats: ({})
  readonly property var gpu: stats.gpu || ({})
  readonly property bool gpuActive: gpu.state === "active"
  readonly property var cpuT: stats.cpu_t
  readonly property var gpuT: gpuActive ? gpu.temp : null
  readonly property real ramTotalGb: (stats.ram_total_kb || 0) / 1048576
  readonly property real ramUsedGb: ((stats.ram_total_kb || 0) - (stats.ram_avail_kb || 0)) / 1048576

  // ---- fan state ----
  // fan_speed reads "cpu,gpu" percent; "0,0" means firmware auto.
  property bool fanAuto: true
  property int fanPercent: 50
  property double holdUntil: 0   // ignore telemetry for controls right after a user edit
  property string writeError: ""

  function fmtTemp(v) { return v === null || v === undefined ? "--" : Math.round(v) + "°" }
  function barText() { return "CPU " + fmtTemp(cpuT) + "  GPU " + (gpuActive ? fmtTemp(gpuT) : "Zzz") }

  // Measured on this machine: average fan RPM at a given manual percent. Used to
  // show what percent firmware auto is "really" running, so leaving auto starts
  // the slider at the same speed instead of jumping. Below ~2400 RPM (idle) a
  // manual 1-5% gives the same RPM as auto.
  readonly property var rpmCurve: [[2362, 5], [2740, 10], [3046, 20], [3468, 35], [4167, 50], [4481, 65], [5045, 80], [5885, 100]]
  function rpmToPercent(rpm) {
    var c = rpmCurve
    if (!(rpm > 0) || rpm <= c[0][0]) return c[0][1]
    for (var i = 1; i < c.length; i++) {
      if (rpm <= c[i][0]) {
        var t = (rpm - c[i - 1][0]) / (c[i][0] - c[i - 1][0])
        var pct = c[i - 1][1] + t * (c[i][1] - c[i - 1][1])
        return Math.max(5, Math.min(100, Math.round(pct / 5) * 5))
      }
    }
    return 100
  }

  function applyStats(s) {
    root.stats = s
    if (Date.now() < holdUntil) return
    var parts = String(s.fan_set || "0,0").split(",")
    var c = parseInt(parts[0], 10), g = parseInt(parts[1], 10)
    var manual = (c > 0 || g > 0)
    root.fanAuto = !manual
    if (manual) root.fanPercent = Math.max(c, g)
    else if (s.fan1 !== null && s.fan1 !== undefined)
      root.fanPercent = rpmToPercent((s.fan1 + (s.fan2 || s.fan1)) / 2)
  }

  function refresh() { if (!statsProc.running) statsProc.running = true }

  function writeSysfs(path, value) {
    root.holdUntil = Date.now() + 3000
    writeProc.command = ["bash", "-c", 'printf "%s" "$1" > "$2"', "_", String(value), path]
    if (writeProc.running) { writeProc.pending = { path: path, value: value }; return }
    writeProc.running = true
  }

  function setFanAuto(auto) {
    root.fanAuto = auto
    writeSysfs(sensePath + "/fan_speed", auto ? "0,0" : root.fanPercent + "," + root.fanPercent)
  }
  function setFanPercent(p) {
    root.fanPercent = Math.round(p)
    if (!root.fanAuto) writeSysfs(sensePath + "/fan_speed", root.fanPercent + "," + root.fanPercent)
  }
  function setCpuCap(on) { writeSysfs(cpuCapPath, on ? 80 : 100) }
  function setBatteryLimit(on) { writeSysfs(sensePath + "/battery_limiter", on ? 1 : 0) }

  Component.onCompleted: refresh()

  Timer {
    interval: root.opened ? 1000 : 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statsProc
    command: ["bash", root.statsScript, root.opened ? "0" : "30"]  // nvidia-smi max age (s)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.applyStats(JSON.parse(String(text).trim())) } catch (e) {}
      }
    }
  }

  Process {
    id: writeProc
    property var pending: null
    stderr: StdioCollector { id: writeErr; waitForEnd: true }
    onExited: function(code) {
      root.writeError = code === 0 ? "" : "Permission denied. Run once: sudo bash ~/.config/omarchy/plugins/acer.predator/install-perms.sh"
      root.holdUntil = Date.now() + 1500
      if (pending) {
        var p = pending; pending = null
        writeProc.command = ["bash", "-c", 'printf "%s" "$1" > "$2"', "_", String(p.value), p.path]
        writeProc.running = true
      } else {
        root.refresh()
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText()
    active: (root.cpuT !== null && root.cpuT >= 90) || (root.gpuT !== null && root.gpuT >= 85)
    tooltipText: "Predator — click for controls"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(800))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth - (panelColumn.implicitHeight > scrollArea.height ? Style.space(14) : 0)
          spacing: Style.space(12)

          // ---------- CPU ----------
          SectionRow { title: "CPU"; value: root.fmtTemp(root.cpuT) + "C" }
          InfoRow {
            label: "Clock (fastest core)"
            value: (stats.cpu_khz !== null && stats.cpu_khz !== undefined) ? (stats.cpu_khz / 1000000).toFixed(2) + " GHz" : "n/a"
          }
          Toggle {
            width: parent.width
            label: "Limit CPU to 80%"
            description: "Caps boost clocks so it runs cooler"
            checked: stats.cpu_cap !== null && stats.cpu_cap !== undefined && stats.cpu_cap <= 80
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.setCpuCap(!(stats.cpu_cap !== null && stats.cpu_cap !== undefined && stats.cpu_cap <= 80))
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- GPU ----------
          SectionRow { title: "GPU"; value: root.gpuActive ? root.fmtTemp(root.gpuT) + "C" : String(root.gpu.state || "n/a") }
          InfoRow { label: "Model"; value: root.gpuActive ? String(root.gpu.name || "") : "—"; visible: root.gpuActive }
          InfoRow { label: "Load"; value: root.gpuActive ? root.gpu.util + "%  ·  " + Math.round(root.gpu.power) + " W" : "—" }
          InfoRow {
            label: "VRAM"
            value: root.gpuActive ? ((root.gpu.mem_used || 0) + (root.gpu.mem_reserved || 0)) + " / " + root.gpu.mem_total + " MiB" : "—"
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Memory ----------
          SectionRow { title: "MEMORY"; value: root.ramUsedGb.toFixed(1) + " / " + root.ramTotalGb.toFixed(1) + " GB" }
          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Style.selectedFillFor(root.bar.foreground, Color.accent)
            Rectangle {
              height: parent.height
              radius: parent.radius
              color: root.bar.foreground
              width: root.ramTotalGb > 0 ? parent.width * Math.min(1, root.ramUsedGb / root.ramTotalGb) : 0
            }
          }
          InfoRow { label: "Available"; value: (root.ramTotalGb - root.ramUsedGb).toFixed(1) + " GB" }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Fan control ----------
          SectionRow {
            title: "FAN SPEED"
            value: root.fanAuto ? "AUTO" : (fanSlider.dragging ? Math.round(fanSlider.liveValue) : root.fanPercent) + "%"
          }
          InfoRow {
            label: "Current speed"
            value: (stats.fan1 !== null && stats.fan1 !== undefined)
              ? stats.fan1 + " / " + stats.fan2 + " RPM" : "n/a"
          }
          PanelSlider {
            id: fanSlider
            width: parent.width
            bar: root.bar
            minimum: 5
            maximum: 100
            step: 5
            integer: true
            value: root.fanPercent
            enabled: !root.fanAuto
            opacity: root.fanAuto ? 0.35 : 1
            onMoved: function(v) { root.fanPercent = Math.round(v) }
            onReleased: function(v) { root.setFanPercent(v) }
          }
          Toggle {
            width: parent.width
            label: "Automatic fan control"
            description: "Let the firmware pick the fan curve"
            checked: root.fanAuto
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.setFanAuto(!root.fanAuto)
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Battery ----------
          SectionRow {
            title: "BATTERY"
            value: (stats.batt_cap !== null && stats.batt_cap !== undefined ? stats.batt_cap + "%" : "--") + "  " + String(stats.batt_status || "")
          }
          Toggle {
            width: parent.width
            label: "Limit charge to 80%"
            description: "Extends battery lifespan"
            checked: stats.batt_limit === 1
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.setBatteryLimit(stats.batt_limit !== 1)
          }

          Text {
            visible: root.writeError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.writeError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  component SectionRow: Item {
    property string title: ""
    property string value: ""
    width: parent.width
    implicitHeight: Math.max(hdr.implicitHeight, val.implicitHeight)
    PanelSectionHeader {
      id: hdr
      text: parent.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: val
      textFormat: Text.PlainText
      text: parent.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component InfoRow: Item {
    property string label: ""
    property string value: ""
    width: parent.width
    implicitHeight: lbl.implicitHeight + Style.space(2)
    Text {
      id: lbl
      textFormat: Text.PlainText
      text: parent.label
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width - lbl.width - Style.space(24))
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
