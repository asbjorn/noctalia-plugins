import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import qs.Services.UI

Rectangle {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    property int sectionWidgetIndex: -1
    property int sectionWidgetsCount: 0

    property var main: pluginApi?.mainInstance ?? null

    readonly property color _fgColor: {
        if (!root.main?.connected)
            return Color.mOnSurfaceVariant;
        switch (root.main?.bgStatus) {
        case "low":
            return Color.mError;
        case "high":
            return Color.mError;
        case "normal":
            return Color.mPrimary;
        default:
            return Color.mOnSurfaceVariant;
        }
    }

    implicitWidth: row.implicitWidth + Style.marginM * 2
    implicitHeight: Style.barHeight

    color: mouseArea.containsMouse ? Color.mHover : Color.mSurfaceVariant
    radius: Style.radiusM

    readonly property string _tooltipText: {
        if (!root.main?.connected)
            return "CGM: Not connected";
        if (root.main?.isStale)
            return "CGM: " + (root.main?.displayBG ?? "--") + " (stale)";
        return "CGM: " + (root.main?.displayBG ?? "--") + " " + (root.main?.trendArrow ?? "") + " " + (root.main?.delta ?? "");
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pluginApi.togglePanel(root.screen, root)
        onEntered: TooltipService.show(root, root._tooltipText)
        onExited: TooltipService.hide()
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.marginS

        NIcon {
            icon: "activity"
            color: root._fgColor
        }

        NText {
            visible: root.main?.connected ?? false
            text: (root.main?.displayBG ?? "--") + " " + (root.main?.trendArrow ?? "")
            color: mouseArea.containsMouse ? Color.mOnHover : root._fgColor
            pointSize: Style.fontSizeS
            font.weight: Font.Bold
        }
    }

    // Pulse when data is stale
    SequentialAnimation on opacity {
        running: root.main?.isStale ?? false
        loops: Animation.Infinite
        NumberAnimation {
            to: 0.3
            duration: 600
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            to: 1.0
            duration: 600
            easing.type: Easing.InOutSine
        }
    }

    opacity: !(root.main?.isStale ?? false) ? 1.0 : opacity
}
