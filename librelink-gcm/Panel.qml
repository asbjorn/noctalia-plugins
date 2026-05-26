import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

Item {
    id: root
    property var pluginApi: null

    readonly property var geometryPlaceholder: panelContainer
    readonly property bool allowAttach: true

    property real contentPreferredWidth: 380 * Style.uiScaleRatio
    property real contentPreferredHeight: 420 * Style.uiScaleRatio

    property var main: pluginApi?.mainInstance ?? null

    property int lowThreshold: pluginApi?.pluginSettings?.lowThreshold ?? 70
    property int highThreshold: pluginApi?.pluginSettings?.highThreshold ?? 180
    property string units: main?.units ?? "mmol/L"

    readonly property color _statusColor: {
        if (!main || !main.connected) return Color.mOnSurface;
        if (main.bgStatus === "high") return Color.mError;
        if (main.bgStatus === "low") return Color.mError;
        return Color.mPrimary;
    }

    function formatBG(mgdl) {
        if (root.units === "mmol/L")
            return (mgdl / 18).toFixed(1);
        return Math.round(mgdl).toString();
    }

    function minutesAgo(isoTimestamp) {
        if (!isoTimestamp) return "";
        var ms = Date.now() - Date.parse(isoTimestamp);
        if (isNaN(ms) || ms < 0) return "";
        var mins = Math.round(ms / 60000);
        if (mins < 1) return "just now";
        return mins + " min ago";
    }

    anchors.fill: parent

    Rectangle {
        id: panelContainer
        anchors.fill: parent
        color: "transparent"

        ColumnLayout {
            anchors {
                fill: parent
                margins: Style.marginL
            }
            spacing: Style.marginM

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.marginS

                NIcon {
                    icon: "activity"
                    color: main?.connected ? Color.mPrimary : Color.mOnSurfaceVariant
                }

                NText {
                    text: "CGM Monitor"
                    pointSize: Style.fontSizeL
                    font.weight: Font.Bold
                    color: Color.mOnSurface
                    Layout.fillWidth: true
                }

                Rectangle {
                    width: Style.marginS
                    height: Style.marginS
                    radius: width / 2
                    color: {
                        if (!pluginApi?.pluginSettings?.email) return Color.mOnSurfaceVariant;
                        return main?.connected ? Color.mPrimary : Color.mError;
                    }
                }
            }

            NDivider {
                Layout.fillWidth: true
            }

            // Current Reading
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.marginS

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Style.marginS

                    NText {
                        id: bgText
                        text: main?.displayBG ?? "--"
                        pointSize: Style.fontSizeL * 2.5
                        font.weight: Font.Bold
                        color: root._statusColor
                    }

                    NText {
                        text: main?.trendArrow ?? ""
                        pointSize: Style.fontSizeL * 2
                        font.weight: Font.Bold
                        color: root._statusColor
                    }
                }

                NText {
                    visible: !!(main?.delta) && main.delta !== "--"
                    text: (main?.delta ?? "") + " " + root.units
                    pointSize: Style.fontSizeM
                    color: Color.mOnSurfaceVariant
                    Layout.alignment: Qt.AlignHCenter
                }

                NText {
                    visible: !!(main?.lastUpdated)
                    text: "Updated " + root.minutesAgo(main?.lastUpdated ?? "")
                    pointSize: Style.fontSizeS
                    color: main?.isStale ? Color.mError : Color.mOnSurfaceVariant
                    Layout.alignment: Qt.AlignHCenter
                }
            }

            // Time window buttons
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.marginS

                Item { Layout.fillWidth: true }

                Repeater {
                    model: [
                        { label: "24h", hours: 24 },
                        { label: "7d", hours: 168 },
                        { label: "14d", hours: 336 }
                    ]

                    Rectangle {
                        required property var modelData
                        width: 40 * Style.uiScaleRatio
                        height: 24 * Style.uiScaleRatio
                        radius: Style.radiusS
                        color: (main?.graphHours ?? 24) === modelData.hours ? Color.mPrimary : Color.mSurfaceVariant

                        NText {
                            anchors.centerIn: parent
                            text: parent.modelData.label
                            pointSize: Style.fontSizeS
                            color: (main?.graphHours ?? 24) === parent.modelData.hours ? Color.mOnPrimary : Color.mOnSurfaceVariant
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (main) main.setGraphWindow(parent.modelData.hours)
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }

            // Chart
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 180 * Style.uiScaleRatio
                color: Color.mSurfaceVariant
                radius: Style.radiusM
                clip: true

                Canvas {
                    id: chart
                    anchors.fill: parent

                    // Cached chart geometry for hover lookups
                    property double _minTime: 0
                    property double _maxTime: 0
                    property double _minBg: 40
                    property double _maxBg: 250
                    property double _padX: 35 * Style.uiScaleRatio
                    property double _padY: 20 * Style.uiScaleRatio
                    property double _chartW: 0
                    property double _chartH: 0

                    // Hover state
                    property int hoveredIndex: -1
                    property double hoveredX: 0
                    property double hoveredY: 0

                    function chartGetX(time) {
                        if (_maxTime === _minTime) return _padX + _chartW / 2;
                        return _padX + ((time - _minTime) / (_maxTime - _minTime)) * _chartW;
                    }

                    function chartGetY(val) {
                        return _padY + _chartH - ((val - _minBg) / (_maxBg - _minBg)) * _chartH;
                    }

                    Connections {
                        target: main
                        function onHistoryRevisionChanged() {
                            chart.markDirty(Qt.rect(0, 0, chart.width, chart.height));
                            chart.requestPaint();
                        }
                    }

                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);

                        if (!main || !main.history || main.history.count === 0) return;

                        var count = main.history.count;
                        var graphHours = main.graphHours || 24;

                        // X axis spans the full requested window, not just data range
                        _maxTime = Date.now();
                        _minTime = _maxTime - graphHours * 60 * 60 * 1000;

                        _minBg = 40;
                        _maxBg = 250;
                        for (var i = 0; i < count; i++) {
                            var sgv = main.history.get(i).sgv;
                            if (sgv > _maxBg) _maxBg = sgv + 20;
                            if (sgv < _minBg) _minBg = Math.max(0, sgv - 20);
                        }

                        _padX = 35 * Style.uiScaleRatio;
                        _padY = 20 * Style.uiScaleRatio;
                        _chartW = width - _padX * 2;
                        _chartH = height - _padY * 2;

                        // Threshold lines
                        ctx.lineWidth = 1;
                        ctx.strokeStyle = Color.mOnSurfaceVariant;
                        ctx.setLineDash([5, 3]);

                        var yHigh = chartGetY(root.highThreshold);
                        ctx.beginPath();
                        ctx.moveTo(_padX, yHigh);
                        ctx.lineTo(width - _padX, yHigh);
                        ctx.stroke();

                        var yLow = chartGetY(root.lowThreshold);
                        ctx.beginPath();
                        ctx.moveTo(_padX, yLow);
                        ctx.lineTo(width - _padX, yLow);
                        ctx.stroke();

                        ctx.setLineDash([]);

                        // Y axis labels
                        ctx.fillStyle = Color.mOnSurfaceVariant;
                        ctx.font = Math.round(10 * Style.uiScaleRatio) + "px sans-serif";
                        ctx.textAlign = "right";
                        ctx.textBaseline = "middle";
                        ctx.fillText(root.formatBG(root.highThreshold), _padX - 5, yHigh);
                        ctx.fillText(root.formatBG(root.lowThreshold), _padX - 5, yLow);

                        // Glucose line segments
                        ctx.lineWidth = 2 * Style.uiScaleRatio;

                        for (var j = 0; j < count - 1; j++) {
                            var pt1 = main.history.get(j);
                            var pt2 = main.history.get(j + 1);

                            var x1 = chartGetX(new Date(pt1.timestamp).getTime());
                            var y1 = chartGetY(pt1.sgv);
                            var x2 = chartGetX(new Date(pt2.timestamp).getTime());
                            var y2 = chartGetY(pt2.sgv);

                            var avgSgv = (pt1.sgv + pt2.sgv) / 2;
                            if (avgSgv < root.lowThreshold) {
                                ctx.strokeStyle = "#ef4444";
                             } else if (avgSgv > root.highThreshold) {
                                ctx.strokeStyle = "#ef4444";
                            } else {
                                ctx.strokeStyle = "#22c55e";
                            }

                            ctx.beginPath();
                            ctx.moveTo(x1, y1);
                            ctx.lineTo(x2, y2);
                            ctx.stroke();
                        }

                        // Hover crosshair + dot
                        if (hoveredIndex >= 0 && hoveredIndex < count) {
                            var hPt = main.history.get(hoveredIndex);
                            var hx = chartGetX(new Date(hPt.timestamp).getTime());
                            var hy = chartGetY(hPt.sgv);

                            // Vertical crosshair line
                            ctx.strokeStyle = Color.mOnSurfaceVariant;
                            ctx.lineWidth = 1;
                            ctx.setLineDash([3, 3]);
                            ctx.beginPath();
                            ctx.moveTo(hx, _padY);
                            ctx.lineTo(hx, height - _padY);
                            ctx.stroke();
                            ctx.setLineDash([]);

                            // Dot
                            var dotColor = hPt.sgv < root.lowThreshold || hPt.sgv > root.highThreshold ? "#ef4444" : "#22c55e";
                            ctx.fillStyle = dotColor;
                            ctx.beginPath();
                            ctx.arc(hx, hy, 4 * Style.uiScaleRatio, 0, 2 * Math.PI);
                            ctx.fill();

                            hoveredX = hx;
                            hoveredY = hy;
                        }

                        // Time axis labels
                        ctx.fillStyle = Color.mOnSurfaceVariant;
                        ctx.textAlign = "center";
                        ctx.textBaseline = "top";
                        var timeSpan = _maxTime - _minTime;
                        if (timeSpan > 0) {
                            var hours = timeSpan / (1000 * 60 * 60);
                            var showDate = hours > 48;
                            var tickCount = showDate ? 4 : 5;
                            var step = Math.max(1, Math.round(hours / tickCount)) * 60 * 60 * 1000;
                            var firstTick = Math.ceil(_minTime / step) * step;
                            for (var t = firstTick; t <= _maxTime; t += step) {
                                var tx = chartGetX(t);
                                var d = new Date(t);
                                var tickLabel;
                                if (showDate) {
                                    tickLabel = (d.getMonth() + 1) + "/" + d.getDate();
                                } else {
                                    tickLabel = d.getHours().toString().padStart(2, '0') + ":" + d.getMinutes().toString().padStart(2, '0');
                                }
                                ctx.fillText(tickLabel, tx, height - _padY + 5);
                            }
                        }
                    }

                    MouseArea {
                        id: chartMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton

                        onPositionChanged: function(mouse) {
                            if (!main || !main.history || main.history.count === 0 || chart._chartW <= 0) {
                                chart.hoveredIndex = -1;
                                return;
                            }

                            var mx = mouse.x;
                            var count = main.history.count;
                            var bestIdx = -1;
                            var bestDist = Infinity;

                            for (var i = 0; i < count; i++) {
                                var pt = main.history.get(i);
                                var px = chart.chartGetX(new Date(pt.timestamp).getTime());
                                var dist = Math.abs(px - mx);
                                if (dist < bestDist) {
                                    bestDist = dist;
                                    bestIdx = i;
                                }
                            }

                            // Only show if within reasonable distance (30px)
                            if (bestDist > 30 * Style.uiScaleRatio) bestIdx = -1;

                            if (chart.hoveredIndex !== bestIdx) {
                                chart.hoveredIndex = bestIdx;
                                chart.requestPaint();
                            }
                        }

                        onExited: {
                            if (chart.hoveredIndex !== -1) {
                                chart.hoveredIndex = -1;
                                chart.requestPaint();
                            }
                        }
                    }

                    // Tooltip
                    Rectangle {
                        id: chartTooltip
                        visible: chart.hoveredIndex >= 0 && main && main.history && chart.hoveredIndex < main.history.count
                        width: tooltipContent.width + Style.marginM * 2
                        height: tooltipContent.height + Style.marginS * 2
                        radius: Style.radiusS
                        color: Color.mSurface
                        border.color: Color.mOutlineVariant
                        border.width: 1

                        // Position: above the dot, clamped to chart bounds
                        x: {
                            var cx = chart.hoveredX - width / 2;
                            if (cx < 0) cx = 0;
                            if (cx + width > chart.width) cx = chart.width - width;
                            return cx;
                        }
                        y: {
                            var cy = chart.hoveredY - height - 8 * Style.uiScaleRatio;
                            if (cy < 0) cy = chart.hoveredY + 8 * Style.uiScaleRatio;
                            return cy;
                        }

                        Column {
                            id: tooltipContent
                            anchors.centerIn: parent
                            spacing: 2

                            NText {
                                text: {
                                    if (chart.hoveredIndex < 0 || !main || !main.history || chart.hoveredIndex >= main.history.count) return "";
                                    var pt = main.history.get(chart.hoveredIndex);
                                    return root.formatBG(pt.sgv) + " " + root.units;
                                }
                                pointSize: Style.fontSizeM
                                font.weight: Font.Bold
                                color: {
                                    if (chart.hoveredIndex < 0 || !main || !main.history || chart.hoveredIndex >= main.history.count) return Color.mOnSurface;
                                    var sgv = main.history.get(chart.hoveredIndex).sgv;
                                    if (sgv < root.lowThreshold || sgv > root.highThreshold) return "#ef4444";
                                    return "#22c55e";
                                }
                                horizontalAlignment: Text.AlignHCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            NText {
                                text: {
                                    if (chart.hoveredIndex < 0 || !main || !main.history || chart.hoveredIndex >= main.history.count) return "";
                                    var pt = main.history.get(chart.hoveredIndex);
                                    var d = new Date(pt.timestamp);
                                    var graphHours = main.graphHours || 24;
                                    if (graphHours > 48) {
                                        return (d.getMonth() + 1) + "/" + d.getDate() + " " +
                                               d.getHours().toString().padStart(2, '0') + ":" +
                                               d.getMinutes().toString().padStart(2, '0');
                                    }
                                    return d.getHours().toString().padStart(2, '0') + ":" +
                                           d.getMinutes().toString().padStart(2, '0');
                                }
                                pointSize: Style.fontSizeS
                                color: Color.mOnSurfaceVariant
                                horizontalAlignment: Text.AlignHCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            // Error / empty states
            NText {
                visible: !!(main?.errorMessage) && !main?.connected
                text: main?.errorMessage ?? ""
                color: Color.mError
                Layout.alignment: Qt.AlignHCenter
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            NText {
                visible: !!(main?.connected) && (!main?.history || main.history.count === 0)
                text: "Waiting for data..."
                color: Color.mOnSurfaceVariant
                Layout.alignment: Qt.AlignHCenter
            }

            NText {
                visible: !pluginApi?.pluginSettings?.email
                text: "Configure in Settings"
                color: Color.mOnSurfaceVariant
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }
}
