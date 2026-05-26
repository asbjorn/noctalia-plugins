import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Widgets

ColumnLayout {
    id: root
    property var pluginApi: null

    property string editEmail: pluginApi?.pluginSettings?.email ?? ""
    property string editPassword: ""
    property string selectedRegion: pluginApi?.pluginSettings?.region ?? "EU"
    property string selectedUnits: pluginApi?.pluginSettings?.units ?? "mmol/L"
    property string editLowThreshold: String(pluginApi?.pluginSettings?.lowThreshold ?? 70)
    property string editHighThreshold: String(pluginApi?.pluginSettings?.highThreshold ?? 180)
    property string editStaleMinutes: String(pluginApi?.pluginSettings?.staleMinutes ?? 15)

    property bool _passwordLoaded: false

    spacing: Style.marginL

    Component.onCompleted: {
        loadPasswordProc.command = ["secret-tool", "lookup", "application", "librelink-cgm", "type", "password"];
        loadPasswordProc.running = true;
    }

    Process {
        id: loadPasswordProc
        stdout: SplitParser {
            onRead: data => {
                var pw = data.trim();
                if (pw.length > 0) {
                    root.editPassword = pw;
                    root._passwordLoaded = true;
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            root._passwordLoaded = true;
        }
    }

    Process {
        id: storePasswordProc
        property string pendingPassword: ""

        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                Logger.i("CGM", "Password stored in keyring");
            } else {
                Logger.e("CGM", "Failed to store password in keyring, exit code: " + exitCode);
            }
        }
    }

    // Email
    NTextInput {
        id: emailInput
        Layout.fillWidth: true
        label: "Email"
        placeholderText: "your@email.com"
        text: root.editEmail
        onTextChanged: root.editEmail = text
    }

    // Password
    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.marginXS

        NText {
            text: "Password"
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Math.max(40 * Style.uiScaleRatio, emailInput.height)
            color: Color.mSurfaceVariant
            radius: Style.radiusS
            border.color: passwordInput.activeFocus ? Color.mPrimary : Color.mOutline
            border.width: Style.borderS

            TextInput {
                id: passwordInput
                anchors {
                    fill: parent
                    leftMargin: Style.marginM
                    rightMargin: Style.marginM
                }
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                color: Color.mOnSurface
                font.pointSize: Style.fontSizeM
                clip: true
                text: root.editPassword
                onTextChanged: root.editPassword = text

                NText {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !passwordInput.text && !passwordInput.activeFocus
                    text: root._passwordLoaded ? "••••••••" : "Loading from keyring..."
                    color: Color.mOnSurfaceVariant
                    pointSize: Style.fontSizeM
                }
            }
        }
    }

    // Region
    NComboBox {
        Layout.fillWidth: true
        label: "Region"
        model: [
            { "key": "EU", "name": "Europe (EU)" },
            { "key": "US", "name": "United States (US)" },
            { "key": "DE", "name": "Germany (DE)" },
            { "key": "FR", "name": "France (FR)" },
            { "key": "JP", "name": "Japan (JP)" },
            { "key": "AP", "name": "Asia Pacific (AP)" },
            { "key": "AU", "name": "Australia (AU)" }
        ]
        currentKey: root.selectedRegion
        onSelected: key => root.selectedRegion = key
        defaultValue: "EU"
    }

    // Units
    NComboBox {
        Layout.fillWidth: true
        label: "Units"
        model: [
            { "key": "mmol/L", "name": "mmol/L" },
            { "key": "mg/dL", "name": "mg/dL" }
        ]
        currentKey: root.selectedUnits
        onSelected: key => root.selectedUnits = key
        defaultValue: "mmol/L"
    }

    // Low threshold
    NTextInput {
        Layout.fillWidth: true
        label: "Low Threshold (mg/dL)"
        placeholderText: "70"
        text: root.editLowThreshold
        onTextChanged: root.editLowThreshold = text
    }

    // High threshold
    NTextInput {
        Layout.fillWidth: true
        label: "High Threshold (mg/dL)"
        placeholderText: "180"
        text: root.editHighThreshold
        onTextChanged: root.editHighThreshold = text
    }

    // Stale minutes
    NTextInput {
        Layout.fillWidth: true
        label: "Stale After (minutes)"
        placeholderText: "15"
        text: root.editStaleMinutes
        onTextChanged: root.editStaleMinutes = text
    }

    Item {
        Layout.fillHeight: true
    }

    function saveSettings() {
        if (!pluginApi)
            return;

        pluginApi.pluginSettings.email = root.editEmail;
        pluginApi.pluginSettings.region = root.selectedRegion;
        pluginApi.pluginSettings.units = root.selectedUnits;
        pluginApi.pluginSettings.lowThreshold = parseInt(root.editLowThreshold) || 70;
        pluginApi.pluginSettings.highThreshold = parseInt(root.editHighThreshold) || 180;
        pluginApi.pluginSettings.staleMinutes = parseInt(root.editStaleMinutes) || 15;
        pluginApi.saveSettings();

        // Store password in keyring if changed
        if (root.editPassword.length > 0) {
            storePasswordProc.pendingPassword = root.editPassword;
            storePasswordProc.command = [
                "sh", "-c",
                "printf '%s' \"$1\" | secret-tool store --label \"LibreLink CGM\" application librelink-cgm type password",
                "sh",
                root.editPassword
            ];
            storePasswordProc.running = true;
        }

        pluginApi.mainInstance?.reloadSettings();
    }
}
