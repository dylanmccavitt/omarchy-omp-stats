import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.dylanmccavitt.omp-stats"

  readonly property url logoSource: Qt.resolvedUrl("assets/omp-mark.svg")
  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing:
    panelItem ? panelItem.popoutSwitchClosing === true : false
  readonly property bool alarming:
    panelItem ? panelItem.alarming || panelItem.errorText !== "" : false
  readonly property string metricText: panelItem ? panelItem.barMetricText : "…"
  readonly property string metricTooltip: panelItem ? panelItem.barTooltip() : "OMP Stats"

  function injectPanel() {
    if (!panelItem) return
    panelItem.bar = root.bar
    panelItem.settings = root.settings
    panelItem.anchorItem = button
    panelItem.hostWidget = root
  }

  function open() {
    if (panelItem && panelItem.controller) panelItem.controller.show()
  }

  function close() {
    if (panelItem && panelItem.controller) panelItem.controller.hide()
  }

  function toggle() {
    if (panelItem && panelItem.controller) panelItem.controller.toggle()
  }

  function closeForPopoutSwitch() {
    if (!panelItem) return
    panelItem.popoutSwitchClosing = true
    if (panelItem.controller) panelItem.controller.hide()
    Qt.callLater(function() {
      if (root.panelItem) root.panelItem.popoutSwitchClosing = false
    })
  }

  function refresh() {
    if (panelItem) panelItem.refresh()
  }

  function model(view) {
    if (!panelItem) return "not ready"
    root.open()
    return panelItem.model(view)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.broadcast("refresh"); return "ok" }
    function model(view: string): string { return root.model(view) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical
      ? barSize
      : Math.max(barSize, horizontalBarContent.implicitWidth + Style.space(12))
    fixedHeight: vertical
      ? Math.max(barSize, verticalBarContent.implicitHeight + Style.space(4))
      : barSize
    active: root.alarming
    tooltipText: root.metricTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else root.refresh()
    }

    Row {
      id: horizontalBarContent
      visible: !button.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Item {
        width: Style.space(16)
        height: width

        Image {
          anchors.fill: parent
          source: root.logoSource
          sourceSize.width: 32
          sourceSize.height: 32
          fillMode: Image.PreserveAspectFit
          smooth: true
          mipmap: true
        }

        Rectangle {
          visible: button.active
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Style.space(4)
          height: width
          radius: width / 2
          color: Color.urgent
        }
      }

      Text {
        visible: root.metricText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.metricText
        color: button.active ? Color.urgent : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        font.weight: Font.DemiBold
        renderType: Text.NativeRendering
      }
    }

    Column {
      id: verticalBarContent
      visible: button.vertical
      anchors.centerIn: parent
      spacing: Style.space(1)

      Item {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(15)
        height: width

        Image {
          anchors.fill: parent
          source: root.logoSource
          sourceSize.width: 30
          sourceSize.height: 30
          fillMode: Image.PreserveAspectFit
          smooth: true
          mipmap: true
        }

        Rectangle {
          visible: button.active
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Style.space(4)
          height: width
          radius: width / 2
          color: Color.urgent
        }
      }

      Text {
        visible: root.metricText !== ""
        width: button.width
        text: root.metricText
        color: button.active ? Color.urgent : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        renderType: Text.NativeRendering
      }
    }
  }
}
