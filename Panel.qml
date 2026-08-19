import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.dylanmccavitt.omp-stats"
  ipcTarget: "io.github.dylanmccavitt.omp-stats"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Bind directly to the popup palette and shared style tokens. Omarchy's
  // theme IPC updates Color and Style in place, so the panel follows a theme
  // switch without reloading this plugin.
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Color.muted
  readonly property color track: Style.normalFillFor(foreground, accent, urgent)
  readonly property string fontFamily: Style.font.family
  readonly property string statsScript: {
    var path = Qt.resolvedUrl("bin/stats-json").toString()
    if (path.indexOf("file://") === 0) path = path.substring(7)
    try { return decodeURIComponent(path) } catch (error) { return path }
  }

  property var report: null
  property string errorText: ""
  property bool loading: false
  property bool pendingRefresh: false
  property bool refreshStopExpected: false
  property double refreshedAt: 0
  property double nowMs: Date.now()
  property int themeRevision: 0
  property string expandedModelKey: ""

  readonly property var overall: report ? report.overall : null
  readonly property var models: Model.modelRows(report)
  readonly property var folders: Model.folderRows(report)
  readonly property var agents: Model.agentRows(report)
  readonly property var activity: Model.activityRows(report)
  readonly property var modelPreference: Model.modelPreference(report, models, 24)
  readonly property int refreshIntervalSec: Math.max(
    60, Math.min(3600, parseInt(setting("refreshIntervalSec", 300), 10) || 300))
  readonly property bool alarming: overall && Number(overall.errorRate || 0) > 0
  readonly property bool verticalBar: bar ? bar.vertical : false
  readonly property string barDisplay: String(setting("barDisplay", "Requests and cost"))
  readonly property string barMetricText:
    Model.barMetric(report, barDisplay, verticalBar, errorText)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, opacity)
  }

  function bumpThemeRevision() {
    themeRevision += 1
  }

  function blendColor(first, second, amount) {
    var mix = Model.clamp(amount, 0, 1)
    return Qt.rgba(
      first.r + (second.r - first.r) * mix,
      first.g + (second.g - first.g) * mix,
      first.b + (second.b - first.b) * mix,
      1)
  }

  function graphColor(index) {
    switch (index % 6) {
    case 0: return accent
    case 1: return urgent
    case 2: return foreground
    case 3: return blendColor(accent, urgent, 0.5)
    case 4: return blendColor(accent, foreground, 0.42)
    default: return blendColor(urgent, foreground, 0.42)
    }
  }

  function refresh() {
    if (statsProcess.running || refreshStopExpected) {
      pendingRefresh = true
      return
    }
    loading = true
    errorText = ""
    statsProcess.command = ["bash", statsScript]
    statsProcess.running = true
    refreshTimeoutTimer.restart()
  }

  function timeoutRefresh() {
    if (!statsProcess.running) return
    pendingRefresh = false
    refreshStopExpected = true
    loading = false
    errorText = "OMP stats refresh timed out after 120 seconds; run omp stats --json directly"
    statsProcess.running = false
  }

  function refreshIfStale() {
    if (!report || Date.now() - refreshedAt >= Math.min(refreshIntervalSec * 1000, 60000)) refresh()
  }

  function heroMeta() {
    if (loading) return "Syncing session files…"
    if (!overall) return errorText !== "" ? "Stats unavailable" : "Waiting for OMP"
    return Model.formatCount(overall.totalRequests) + " requests · last request "
      + Model.relativeTime(overall.lastTimestamp, nowMs)
  }

  function barTooltip() {
    if (!overall) return errorText !== "" ? errorText : "OMP Stats"
    return "OMP Stats · " + Model.formatCost(overall.totalCost)
      + " · " + Model.formatCount(overall.totalRequests) + " requests"
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { root.controller.toggle() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function model(view) {
    var needle = String(view || "").toLowerCase()
    for (var i = 0; i < models.length; i++) {
      var row = models[i]
      if (needle === String(i) || needle === String(row.name || "").toLowerCase()
          || needle === String(row.key || "").toLowerCase()) {
        var expanding = expandedModelKey !== row.key
        expandedModelKey = expanding ? row.key : ""
        if (expanding) Qt.callLater(function() {
          panelFlick.contentY = Model.clamp(
            graphSection.y + modelPreferenceCard.y + modelPreferenceCard.height + Style.space(32),
            0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
        })
        return (expanding ? "expanded " : "collapsed ") + row.name
      }
    }
    return "unknown model"
  }

  Component.onCompleted: refresh()

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    panelFlick.contentY = 0
    refreshIfStale()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Canvas pixels are retained by Qt; ordinary color bindings cannot repaint
  // them. Advance a revision on every palette/style update so graph canvases
  // redraw immediately when `omarchy theme set` or `omarchy font set` runs.
  Connections {
    target: Color
    function onForegroundChanged() { root.bumpThemeRevision() }
    function onBackgroundChanged() { root.bumpThemeRevision() }
    function onAccentChanged() { root.bumpThemeRevision() }
    function onUrgentChanged() { root.bumpThemeRevision() }
    function onMutedChanged() { root.bumpThemeRevision() }
    function onShellValuesChanged() { root.bumpThemeRevision() }
  }

  Connections {
    target: Style
    function onStyleOverridesChanged() { root.bumpThemeRevision() }
    function onFontFamilyChanged() { root.bumpThemeRevision() }
    function onCornerRadiusChanged() { root.bumpThemeRevision() }
  }

  Process {
    id: statsProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: statsStdout
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: statsStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      refreshTimeoutTimer.stop()

      if (root.refreshStopExpected) {
        root.refreshStopExpected = false
        root.loading = false
        if (root.pendingRefresh) {
          root.pendingRefresh = false
          Qt.callLater(root.refresh)
        }
        return
      }

      root.loading = false
      var output = String(statsStdout.text || "")
      var detail = String(statsStderr.text || "").trim()

      if (exitCode !== 0) {
        root.errorText = detail || "OMP stats refresh failed"
      } else {
        try {
          var parsed = Model.parse(output)
          if (!parsed) throw new Error("OMP returned an empty stats report")
          root.report = parsed
          root.refreshedAt = Date.now()
          root.errorText = ""
        } catch (error) {
          root.errorText = error && error.message ? String(error.message) : String(error)
        }
      }

      if (root.pendingRefresh) {
        root.pendingRefresh = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Timer {
    id: refreshTimeoutTimer
    interval: 120000
    repeat: false
    onTriggered: root.timeoutRefresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.switchPanel(dx)
        if (dy !== 0)
          panelFlick.contentY = Model.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                            Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === "m" || text === "M")
          panelFlick.contentY = Model.clamp(graphSection.y, 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
        else if ((text === "g" || text === "G") && root.models.length > 0) {
          var key = root.models[0].key
          root.expandedModelKey = root.expandedModelKey === key ? "" : key
          Qt.callLater(function() {
            panelFlick.contentY = Model.clamp(
              graphSection.y + modelPreferenceCard.y + modelPreferenceCard.height + Style.space(32),
              0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
          })
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "OMP Stats"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              OmpAsciiLogo {}
            }
          }

          Rectangle {
            visible: root.errorText !== ""
            width: parent.width
            implicitHeight: errorLabel.implicitHeight + Style.spacing.xl * 2
            radius: Style.cornerRadius
            color: root.alpha(root.urgent, 0.10)
            border.color: root.alpha(root.urgent, 0.35)
            border.width: 1

            Text {
              id: errorLabel
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.errorText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Grid {
            id: summaryGrid
            visible: !!root.overall
            width: parent.width
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(8)

            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "TOTAL COST"
              value: Model.formatCost(root.overall ? root.overall.totalCost : 0)
            }
            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "REQUESTS"
              value: Model.formatCount(root.overall ? root.overall.totalRequests : 0)
            }
            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "CACHE SAVINGS"
              value: Model.formatPercent(root.overall ? root.overall.cacheSavings : 0)
            }
            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "CACHE RATE"
              value: Model.formatPercent(root.overall ? root.overall.cacheRate : 0)
            }
            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "ERROR RATE"
              value: Model.formatPercent(root.overall ? root.overall.errorRate : 0)
              alarming: root.overall && Number(root.overall.errorRate || 0) > 0
            }
            MetricCard {
              width: Math.floor((summaryGrid.width - summaryGrid.columnSpacing) / 2)
              label: "CONVERSATION TOTAL"
              value: Model.formatCount(Model.conversationTokens(root.overall))
            }
          }

          PanelSeparator {
            visible: !!root.overall
            foreground: root.foreground
          }

          Column {
            id: graphSection
            visible: root.modelPreference.models.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "MODELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ModelPreferenceGraph {
              id: modelPreferenceCard
              width: parent.width
              preference: root.modelPreference
            }

            PanelSectionHeader {
              width: parent.width
              text: "MODEL STATISTICS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelStatCard {
                required property var modelData
                width: parent.width
                row: modelData
                performance: Model.modelPerformancePoints(root.report, modelData.key, 24)
                expanded: root.expandedModelKey === modelData.key
                onToggleRequested: root.expandedModelKey = expanded ? "" : modelData.key
              }
            }
          }

          PanelSeparator {
            visible: !!root.overall
            foreground: root.foreground
          }

          Column {
            visible: !!root.overall
            width: parent.width
            spacing: Style.space(7)

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS & PERFORMANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              id: detailGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "UNCACHED INPUT"
                value: Model.formatCount(root.overall ? root.overall.totalInputTokens : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "CACHE READ"
                value: Model.formatCount(root.overall ? root.overall.totalCacheReadTokens : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "OUTPUT TOKENS"
                value: Model.formatCount(root.overall ? root.overall.totalOutputTokens : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "CACHE WRITE"
                value: Model.formatCount(root.overall ? root.overall.totalCacheWriteTokens : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "TOKENS/S"
                value: Model.formatRate(root.overall ? root.overall.avgTokensPerSecond : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "AVG LATENCY"
                value: Model.formatDuration(root.overall ? root.overall.avgDuration : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "AVG TTFT"
                value: Model.formatDuration(root.overall ? root.overall.avgTtft : 0)
              }
              MetricCard {
                width: Math.floor((detailGrid.width - detailGrid.columnSpacing) / 2)
                label: "PREMIUM REQUESTS"
                value: Model.formatCount(root.overall ? root.overall.totalPremiumRequests : 0)
              }
            }
          }


          PanelSeparator {
            visible: root.folders.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.folders.length > 0
            width: parent.width
            spacing: Style.space(7)

            PanelSectionHeader {
              width: parent.width
              text: "PROJECTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.folders
              BreakdownRow {
                required property var modelData
                width: parent.width
                title: modelData.name
                detail: Model.formatCount(modelData.requests) + " req · "
                  + Model.formatCount(modelData.tokens) + " tok"
                value: Model.formatCost(modelData.cost)
                share: modelData.share
              }
            }
          }

          PanelSeparator {
            visible: root.agents.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.agents.length > 0
            width: parent.width
            spacing: Style.space(7)

            PanelSectionHeader {
              width: parent.width
              text: "AGENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.agents
              BreakdownRow {
                required property var modelData
                width: parent.width
                title: modelData.name
                detail: Model.formatCount(modelData.requests) + " req · "
                  + Model.formatCost(modelData.cost)
                value: Model.formatCount(modelData.tokens) + " tok"
                share: modelData.share
              }
            }
          }

          PanelSeparator {
            visible: root.activity.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.activity.length > 0
            width: parent.width
            spacing: Style.space(7)

            PanelSectionHeader {
              width: parent.width
              text: "RECENT ACTIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.activity
              ActivityRow {
                required property var modelData
                width: parent.width
                label: modelData.label
                requests: modelData.requests
                errors: modelData.errors
                cost: modelData.cost
                share: modelData.share
              }
            }
          }

          Text {
            width: parent.width
            text: "G details · R refresh · " + Math.round(root.refreshIntervalSec / 60) + "m auto"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // Canonical terminal PI_LOGO from OMP's components/welcome.ts. Keep the
  // literal block characters so this remains the real OMP mark, not a glyph
  // approximation whose appearance depends on the active icon font.
  component OmpAsciiLogo: Column {
    id: asciiLogo

    readonly property real glyphSize: Math.max(6, Style.font.caption * 0.7)

    width: implicitWidth
    height: implicitHeight
    spacing: -Math.max(1, glyphSize * 0.16)

    Repeater {
      model: [
        { "text": "▀██████████▀", "color": "#78ffdc" },
        { "text": " ╘██    ██", "color": "#3cc8ff" },
        { "text": "  ██    ██", "color": "#7882ff" },
        { "text": "  ██    ██", "color": "#c86eff" },
        { "text": " ▄██▄  ▄██▄", "color": "#ff5cc8" }
      ]

      Text {
        required property var modelData
        text: modelData.text
        color: modelData.color
        font.family: "monospace"
        font.pixelSize: asciiLogo.glyphSize
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
  }

  component MetricCard: Rectangle {
    property string label: ""
    property string value: ""
    property bool alarming: false

    implicitHeight: Style.space(68)
    radius: Style.cornerRadius
    color: alarming ? root.alpha(root.urgent, 0.10)
                    : Style.normalFillFor(root.foreground, root.accent, root.urgent)
    border.color: alarming ? root.alpha(root.urgent, 0.35)
                           : Style.normalBorderFor(root.foreground, root.accent, root.urgent)
    border.width: Style.normalBorderWidth

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: label
        color: alarming ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: value
        color: alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
    }
  }

  component ModelPreferenceGraph: Rectangle {
    id: preferenceGraph

    property var preference: ({ models: [], points: [] })
    readonly property var models: preference && preference.models ? preference.models : []
    readonly property var points: preference && preference.points ? preference.points : []

    implicitHeight: Style.space(224)
      + Math.max(0, preferenceLegend.height - Style.space(18))
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.foreground, root.accent, root.urgent)
    border.color: Style.normalBorderFor(root.foreground, root.accent, root.urgent)
    border.width: Style.normalBorderWidth

    Text {
      id: preferenceTitle
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(12)
      anchors.topMargin: Style.space(10)
      text: "MODEL PREFERENCE"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: preferenceSubtitle
      anchors.left: parent.left
      anchors.top: preferenceTitle.bottom
      anchors.leftMargin: Style.space(12)
      anchors.topMargin: Style.space(2)
      text: "Share of requests over recent activity"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Flow {
      id: preferenceLegend
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: preferenceSubtitle.bottom
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(7)
      height: Math.max(Style.space(18), childrenRect.height)
      spacing: Style.space(10)

      Repeater {
        model: preferenceGraph.models

        Row {
          required property var modelData
          required property int index
          spacing: Style.space(4)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: width
            radius: width / 2
            color: root.alpha(root.graphColor(index), 0.18)
            border.color: root.graphColor(index)
            border.width: 1
          }

          Text {
            text: modelData.name
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Canvas {
      id: preferenceCanvas
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: preferenceLegend.bottom
      anchors.bottom: preferenceStartLabel.top
      anchors.leftMargin: Style.space(40)
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(7)
      anchors.bottomMargin: Style.space(5)

      property int paintRevision: root.themeRevision
      property var paintModels: preferenceGraph.models
      property var paintPoints: preferenceGraph.points

      onPaintRevisionChanged: requestPaint()
      onPaintModelsChanged: requestPaint()
      onPaintPointsChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onVisibleChanged: if (visible) requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)

        var values = preferenceGraph.points || []
        var series = preferenceGraph.models || []
        if (values.length === 0 || series.length === 0 || width <= 0 || height <= 0) return

        var left = 1
        var right = Math.max(left, width - 1)
        var top = 2
        var bottom = Math.max(top, height - 2)
        var chartWidth = right - left
        var chartHeight = bottom - top
        var renderCount = values.length === 1 ? 2 : values.length

        function pointAt(index) {
          return values.length === 1 ? values[0] : values[index]
        }
        function pointX(index) {
          return left + chartWidth * index / Math.max(1, renderCount - 1)
        }
        function pointY(share) {
          return bottom - chartHeight * Model.clamp(share, 0, 1)
        }
        function cumulative(point, endIndex) {
          var total = 0
          var shares = point && point.shares ? point.shares : []
          for (var shareIndex = 0; shareIndex < endIndex; shareIndex++)
            total += Number(shares[shareIndex] || 0)
          return total
        }

        for (var modelIndex = 0; modelIndex < series.length; modelIndex++) {
          ctx.beginPath()
          for (var upperIndex = 0; upperIndex < renderCount; upperIndex++) {
            var upperPoint = pointAt(upperIndex)
            var upperY = pointY(cumulative(upperPoint, modelIndex + 1))
            if (upperIndex === 0) ctx.moveTo(pointX(upperIndex), upperY)
            else ctx.lineTo(pointX(upperIndex), upperY)
          }
          for (var lowerIndex = renderCount - 1; lowerIndex >= 0; lowerIndex--) {
            var lowerPoint = pointAt(lowerIndex)
            ctx.lineTo(pointX(lowerIndex), pointY(cumulative(lowerPoint, modelIndex)))
          }
          ctx.closePath()
          ctx.fillStyle = root.alpha(root.graphColor(modelIndex), 0.16)
          ctx.fill()

          ctx.beginPath()
          for (var lineIndex = 0; lineIndex < renderCount; lineIndex++) {
            var linePoint = pointAt(lineIndex)
            var lineY = pointY(cumulative(linePoint, modelIndex + 1))
            if (lineIndex === 0) ctx.moveTo(pointX(lineIndex), lineY)
            else ctx.lineTo(pointX(lineIndex), lineY)
          }
          ctx.strokeStyle = root.graphColor(modelIndex)
          ctx.lineWidth = 1.5
          ctx.lineJoin = "round"
          ctx.stroke()
        }

        ctx.strokeStyle = root.alpha(root.foreground, 0.10)
        ctx.lineWidth = 1
        for (var gridIndex = 0; gridIndex <= 4; gridIndex++) {
          var gridY = top + chartHeight * gridIndex / 4
          ctx.beginPath()
          ctx.moveTo(left, gridY)
          ctx.lineTo(right, gridY)
          ctx.stroke()
        }
        for (var verticalIndex = 0; verticalIndex <= 2; verticalIndex++) {
          var gridX = left + chartWidth * verticalIndex / 2
          ctx.beginPath()
          ctx.moveTo(gridX, top)
          ctx.lineTo(gridX, bottom)
          ctx.stroke()
        }
      }
    }

    Text {
      anchors.left: parent.left
      anchors.top: preferenceCanvas.top
      anchors.leftMargin: Style.space(10)
      text: "100%"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: preferenceCanvas.verticalCenter
      anchors.leftMargin: Style.space(14)
      text: "50%"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.left: parent.left
      anchors.bottom: preferenceCanvas.bottom
      anchors.leftMargin: Style.space(18)
      text: "0%"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.centerIn: preferenceCanvas
      visible: preferenceGraph.points.length === 0
      text: "No model activity yet"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: preferenceStartLabel
      anchors.left: preferenceCanvas.left
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      text: preferenceGraph.points.length > 0 ? preferenceGraph.points[0].label : "—"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: preferenceCanvas.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      text: preferenceGraph.points.length > 1
        ? preferenceGraph.points[preferenceGraph.points.length - 1].label : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component ModelStatCard: Rectangle {
    id: modelStat

    property var row: ({})
    property var performance: []
    property bool expanded: false
    signal toggleRequested()

    implicitHeight: Style.space(48) + modelMetricGrid.implicitHeight
      + (expanded ? expandedContent.implicitHeight + Style.space(22) : Style.space(12))
    radius: Style.cornerRadius
    color: expanded
      ? Style.selectedFillFor(root.foreground, root.accent, root.urgent)
      : (modelHover.hovered
          ? Style.hoverFillFor(root.foreground, root.accent, root.urgent)
          : Style.normalFillFor(root.foreground, root.accent, root.urgent))
    border.color: expanded
      ? Style.selectedBorderFor(root.foreground, root.accent, root.urgent)
      : Style.normalBorderFor(root.foreground, root.accent, root.urgent)
    border.width: expanded ? Style.selectedBorderWidth : Style.normalBorderWidth
    clip: true

    HoverHandler { id: modelHover }
    TapHandler { onTapped: modelStat.toggleRequested() }

    Text {
      id: modelName
      anchors.left: parent.left
      anchors.right: modelChevron.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(8)
      anchors.topMargin: Style.space(9)
      text: modelStat.row.name || "Unknown model"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      anchors.left: parent.left
      anchors.right: modelChevron.left
      anchors.top: modelName.bottom
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(8)
      anchors.topMargin: Style.space(1)
      text: modelStat.row.provider || ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: modelChevron
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(14)
      text: modelStat.expanded ? "⌃" : "⌄"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Grid {
      id: modelMetricGrid
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(48)
      columns: 3
      columnSpacing: Style.space(7)
      rowSpacing: Style.space(5)

      ModelMetricCell {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        label: "REQUESTS"
        value: Model.formatCount(modelStat.row.requests)
      }
      ModelMetricCell {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        label: "COST"
        value: Model.formatCost(modelStat.row.cost)
      }
      ModelMetricCell {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        label: "TOKENS"
        value: Model.formatCount(modelStat.row.tokens)
      }
      ModelMetricCell {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        label: "TOKENS/S"
        value: Model.formatRate(modelStat.row.avgTokensPerSecond)
      }
      ModelMetricCell {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        label: "TTFT"
        value: Model.formatDurationPrecise(modelStat.row.avgTtft)
      }

      Item {
        width: Math.floor((modelMetricGrid.width - modelMetricGrid.columnSpacing * 2) / 3)
        implicitHeight: Style.space(36)

        Text {
          anchors.left: parent.left
          anchors.top: parent.top
          text: "24H TREND"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Sparkline {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.topMargin: Style.space(13)
          points: modelStat.row.trend || []
          valueKey: "requests"
          lineColor: root.accent
        }
      }
    }

    Column {
      id: expandedContent
      visible: modelStat.expanded
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: modelMetricGrid.bottom
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        width: parent.width
        height: 1
        color: root.alpha(root.foreground, 0.12)
      }

      Grid {
        id: efficiencyGrid
        width: parent.width
        columns: 4
        columnSpacing: Style.space(6)

        ModelMetricCell {
          width: Math.floor((efficiencyGrid.width - efficiencyGrid.columnSpacing * 3) / 4)
          label: "ERROR"
          value: Model.formatPercent(modelStat.row.errorRate)
        }
        ModelMetricCell {
          width: Math.floor((efficiencyGrid.width - efficiencyGrid.columnSpacing * 3) / 4)
          label: "CACHE"
          value: Model.formatPercent(modelStat.row.cacheRate)
        }
        ModelMetricCell {
          width: Math.floor((efficiencyGrid.width - efficiencyGrid.columnSpacing * 3) / 4)
          label: "SAVED"
          value: Model.formatPercent(modelStat.row.cacheSavings)
        }
        ModelMetricCell {
          width: Math.floor((efficiencyGrid.width - efficiencyGrid.columnSpacing * 3) / 4)
          label: "DURATION"
          value: Model.formatDurationPrecise(modelStat.row.avgDuration)
        }
      }

      ModelPerformanceGraph {
        width: parent.width
        points: modelStat.performance
      }
    }
  }

  component ModelMetricCell: Item {
    property string label: ""
    property string value: ""

    implicitHeight: Style.space(36)

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }
  }

  component Sparkline: Canvas {
    property var points: []
    property string valueKey: "requests"
    property color lineColor: root.accent
    property int paintRevision: root.themeRevision

    onPaintRevisionChanged: requestPaint()
    onPointsChanged: requestPaint()
    onValueKeyChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var values = points || []
      if (values.length === 0 || width <= 0 || height <= 0) return

      var maximum = 0
      for (var i = 0; i < values.length; i++)
        maximum = Math.max(maximum, Number(values[i][valueKey] || 0))
      if (maximum <= 0) maximum = 1

      function pointX(index) {
        return values.length === 1 ? width / 2 : 1 + (width - 2) * index / (values.length - 1)
      }
      function pointY(value) {
        return height - 2 - (height - 4) * Number(value || 0) / maximum
      }

      ctx.beginPath()
      ctx.moveTo(0, height - 1)
      ctx.lineTo(width, height - 1)
      ctx.strokeStyle = root.alpha(root.foreground, 0.10)
      ctx.lineWidth = 1
      ctx.stroke()

      ctx.beginPath()
      for (var pointIndex = 0; pointIndex < values.length; pointIndex++) {
        var x = pointX(pointIndex)
        var y = pointY(values[pointIndex][valueKey])
        if (pointIndex === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.strokeStyle = lineColor
      ctx.lineWidth = 1.5
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.stroke()

      if (values.length === 1) {
        ctx.beginPath()
        ctx.arc(pointX(0), pointY(values[0][valueKey]), 2, 0, Math.PI * 2)
        ctx.fillStyle = lineColor
        ctx.fill()
      }
    }
  }

  component ModelPerformanceGraph: Item {
    id: performanceGraph

    property var points: []
    implicitHeight: Style.space(154)

    Text {
      id: performanceTitle
      anchors.left: parent.left
      anchors.top: parent.top
      text: "MODEL PERFORMANCE"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Row {
      id: performanceLegend
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      Row {
        spacing: Style.space(4)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.alpha(root.urgent, 0.18)
          border.color: root.urgent
          border.width: 1
        }
        Text {
          text: "TTFT"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        spacing: Style.space(4)
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.alpha(root.accent, 0.18)
          border.color: root.accent
          border.width: 1
        }
        Text {
          text: "Tokens/s"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Canvas {
      id: performanceCanvas
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: performanceTitle.bottom
      anchors.bottom: performanceStartLabel.top
      anchors.topMargin: Style.space(8)
      anchors.bottomMargin: Style.space(5)

      property int paintRevision: root.themeRevision
      property var paintPoints: performanceGraph.points

      onPaintRevisionChanged: requestPaint()
      onPaintPointsChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onVisibleChanged: if (visible) requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        var values = performanceGraph.points || []
        if (values.length === 0 || width <= 0 || height <= 0) return

        var left = 1
        var right = Math.max(left, width - 1)
        var top = 2
        var bottom = Math.max(top, height - 2)
        var chartWidth = right - left
        var chartHeight = bottom - top
        var minRate = Number(values[0].rate || 0)
        var maxRate = minRate
        var minTtft = Number(values[0].ttft || 0)
        var maxTtft = minTtft

        for (var i = 1; i < values.length; i++) {
          minRate = Math.min(minRate, Number(values[i].rate || 0))
          maxRate = Math.max(maxRate, Number(values[i].rate || 0))
          minTtft = Math.min(minTtft, Number(values[i].ttft || 0))
          maxTtft = Math.max(maxTtft, Number(values[i].ttft || 0))
        }

        function pointX(index) {
          return values.length === 1 ? left + chartWidth / 2
            : left + chartWidth * index / (values.length - 1)
        }
        function scaledY(value, minimum, maximum) {
          if (maximum <= minimum) return top + chartHeight / 2
          return bottom - chartHeight * (Number(value || 0) - minimum) / (maximum - minimum)
        }
        function drawSeries(key, color, minimum, maximum) {
          ctx.beginPath()
          for (var pointIndex = 0; pointIndex < values.length; pointIndex++) {
            var x = pointX(pointIndex)
            var y = scaledY(values[pointIndex][key], minimum, maximum)
            if (pointIndex === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.strokeStyle = color
          ctx.lineWidth = 1.5
          ctx.lineJoin = "round"
          ctx.lineCap = "round"
          ctx.stroke()
          if (values.length === 1) {
            ctx.beginPath()
            ctx.arc(pointX(0), scaledY(values[0][key], minimum, maximum), 2.5, 0, Math.PI * 2)
            ctx.fillStyle = color
            ctx.fill()
          }
        }

        ctx.strokeStyle = root.alpha(root.foreground, 0.10)
        ctx.lineWidth = 1
        for (var gridIndex = 0; gridIndex <= 3; gridIndex++) {
          var gridY = top + chartHeight * gridIndex / 3
          ctx.beginPath()
          ctx.moveTo(left, gridY)
          ctx.lineTo(right, gridY)
          ctx.stroke()
        }

        drawSeries("ttft", root.urgent, minTtft, maxTtft)
        drawSeries("rate", root.accent, minRate, maxRate)
      }
    }

    Text {
      anchors.centerIn: performanceCanvas
      visible: performanceGraph.points.length === 0
      text: "No performance samples yet"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: performanceStartLabel
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: performanceGraph.points.length > 0 ? performanceGraph.points[0].label : "—"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      text: performanceGraph.points.length > 1
        ? performanceGraph.points[performanceGraph.points.length - 1].label : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component BreakdownRow: Item {
    property string title: ""
    property string detail: ""
    property string value: ""
    property real share: 0

    implicitHeight: Style.space(52)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent, root.urgent)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * Model.clamp(share, 0, 1)
      radius: Style.cornerRadius
      color: Style.selectedFillFor(root.foreground, root.accent, root.urgent)
    }

    Text {
      anchors.left: parent.left
      anchors.right: breakdownValue.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.topMargin: Style.space(7)
      text: title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      anchors.left: parent.left
      anchors.right: breakdownValue.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.bottomMargin: Style.space(7)
      text: detail
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: breakdownValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Style.space(10)
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  component ActivityRow: Item {
    property string label: ""
    property real requests: 0
    property real errors: 0
    property real cost: 0
    property real share: 0

    implicitHeight: Style.space(26)

    Text {
      id: activityLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(44)
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: activityTrack
      anchors.left: activityLabel.right
      anchors.right: activityValue.left
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(5)
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width * Model.clamp(share, 0, 1)
        height: parent.height
        radius: parent.radius
        color: errors > 0 ? root.urgent : root.accent
      }
    }

    Text {
      id: activityValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(98)
      text: Model.formatCount(requests) + " req · " + Model.formatCost(cost)
      color: errors > 0 ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
    }
  }
}
