import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
    id: root
    visible: false

    property var pluginApi: null

    property int currentBG: 0
    property string trendArrow: "→"
    readonly property string bgStatus: currentBG <= 0 ? "normal" : (currentBG < lowThreshold ? "low" : (currentBG > highThreshold ? "high" : "normal"))
    property string delta: "--"
    property string lastUpdated: ""
    readonly property bool isStale: {
        if (!lastUpdated) {
            return true
        }

        var parsed = Date.parse(lastUpdated)
        if (isNaN(parsed)) {
            return true
        }

        return (Date.now() - parsed) > (staleMinutes * 60 * 1000)
    }
    property bool connected: false
    property string errorMessage: ""
    property alias history: historyModel
    property string units: "mmol/L"
    readonly property string displayBG: currentBG > 0 ? formatBG(currentBG) : "--"

    property string email: ""
    property string region: "EU"
    property int lowThreshold: 70
    property int highThreshold: 180
    property int staleMinutes: 15
    property string patientId: ""

    property string authToken: ""
    property string accountId: ""
    property string tokenExpires: ""

    property string _password: ""
    property bool _requestInFlight: false
    property bool _storeInProgress: false
    property string _rawAccountId: ""
    property bool _hashInProgress: false
    property bool _lookupInProgress: false

    // DB + chart window
    property int graphHours: 24
    property string _dbPath: ""
    property bool _dbReady: false
    property double _lastAlertTime: 0
    readonly property int _alertCooldownMs: 300000 // 5 min cooldown
    property int historyRevision: 0

    readonly property var _regionUrls: ({
        "EU": "https://api-eu.libreview.io",
        "US": "https://api.libreview.io",
        "DE": "https://api-de.libreview.io",
        "FR": "https://api-fr.libreview.io",
        "JP": "https://api-jp.libreview.io",
        "AP": "https://api-ap.libreview.io",
        "AU": "https://api-au.libreview.io"
    })

    function settingValue(name, fallback) {
        var settings = pluginApi && pluginApi.pluginSettings ? pluginApi.pluginSettings : null
        if (!settings || settings[name] === undefined || settings[name] === null || settings[name] === "") {
            return fallback
        }

        return settings[name]
    }

    function persistSetting(name, value) {
        if (!pluginApi)
            return

        pluginApi.pluginSettings[name] = value
        pluginApi.saveSettings()
    }

    function apiBaseUrl() {
        var key = (region || "EU").toString().toUpperCase()
        return _regionUrls[key] || _regionUrls.EU
    }

    function normalizeIso(timestamp) {
        if (!timestamp) {
            return ""
        }

        // Try native parse first
        var parsed = new Date(timestamp)
        if (!isNaN(parsed.getTime())) {
            return parsed.toISOString()
        }

        // Parse LibreLink format: "M/D/YYYY h:mm:ss AM/PM"
        var match = timestamp.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)$/i)
        if (match) {
            var month = parseInt(match[1], 10)
            var day = parseInt(match[2], 10)
            var year = parseInt(match[3], 10)
            var hours = parseInt(match[4], 10)
            var minutes = parseInt(match[5], 10)
            var seconds = parseInt(match[6], 10)
            var ampm = match[7].toUpperCase()

            if (ampm === "PM" && hours < 12) hours += 12
            if (ampm === "AM" && hours === 12) hours = 0

            var d = new Date(year, month - 1, day, hours, minutes, seconds)
            if (!isNaN(d.getTime())) {
                return d.toISOString()
            }
        }

        return timestamp.toString()
    }

    function formatBG(mgdl) {
        if (mgdl === undefined || mgdl === null || mgdl <= 0) {
            return "--"
        }

        if (units === "mg/dL") {
            return Math.round(mgdl).toString()
        }

        return (mgdl / 18.0).toFixed(1)
    }

    function formatDeltaValue(changeMgdl) {
        var sign = changeMgdl > 0 ? "+" : ""
        if (units === "mg/dL") {
            return sign + Math.round(changeMgdl).toString()
        }

        return sign + (changeMgdl / 18.0).toFixed(1)
    }

    function trendArrowFromValue(value) {
        if (value === undefined || value === null) {
            return "→"
        }

        if (typeof value === "string") {
            switch (value) {
            case "DoubleUp":
                return "↗↗"
            case "SingleUp":
            case "FortyFiveUp":
                return "↗"
            case "Flat":
                return "→"
            case "SingleDown":
            case "FortyFiveDown":
                return "↘"
            case "DoubleDown":
                return "↘↘"
            case "Down":
                return "↓"
            default:
                break
            }
        }

        var numeric = Number(value)
        switch (numeric) {
        case 1:
            return "↘↘"
        case 2:
            return "↓"
        case 3:
            return "→"
        case 4:
            return "↗"
        case 5:
            return "↗↗"
        default:
            return "→"
        }
    }

    function applyCommonHeaders(xhr, withAuth) {
        xhr.setRequestHeader("User-Agent", "Mozilla/5.0 (iPhone; CPU OS 17_4.1 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/17.4.1 Mobile/10A5355d Safari/8536.25")
        xhr.setRequestHeader("accept-encoding", "gzip")
        xhr.setRequestHeader("cache-control", "no-cache")
        xhr.setRequestHeader("connection", "Keep-Alive")
        xhr.setRequestHeader("content-type", "application/json")
        xhr.setRequestHeader("product", "llu.ios")
        xhr.setRequestHeader("version", "4.16.0")

        if (withAuth && authToken) {
            xhr.setRequestHeader("Authorization", "Bearer " + authToken)
        }

        if (withAuth && accountId) {
            xhr.setRequestHeader("account-id", accountId)
        }
    }

    function parseEnvelope(xhr, actionName) {
        var body = null

        try {
            body = JSON.parse(xhr.responseText)
        } catch (error) {
            throw new Error(actionName + " returned invalid JSON")
        }

        if (!body || body.status !== 0) {
            throw new Error(actionName + " failed")
        }

        return body.data
    }

    function setError(message) {
        errorMessage = message
        connected = false
        Logger.e("CGM", message)
    }

    function clearError() {
        errorMessage = ""
    }

    function runRequest(method, path, payload, withAuth, onSuccess, onFailure) {
        var xhr = new XMLHttpRequest()
        xhr.open(method, apiBaseUrl() + path)
        applyCommonHeaders(xhr, withAuth)

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) {
                return
            }

            if (xhr.status < 200 || xhr.status >= 300) {
                if (onFailure) {
                    onFailure(xhr)
                }
                return
            }

            try {
                var data = parseEnvelope(xhr, method + " " + path)
                if (onSuccess) {
                    onSuccess(data)
                }
            } catch (error) {
                if (onFailure) {
                    onFailure(xhr, error)
                }
            }
        }

        if (payload !== undefined && payload !== null) {
            xhr.send(JSON.stringify(payload))
        } else {
            xhr.send()
        }
    }

    function authenticate() {
        if (!email) {
            setError("LibreLink email is not configured")
            return
        }

        if (!_password) {
            setError("LibreLink password not found in keyring")
            return
        }

        Logger.i("CGM", "Authenticating with LibreLink")
        runRequest("POST", "/llu/auth/login", {
            email: email,
            password: _password
        }, false, function(data) {
            var ticket = data && data.authTicket ? data.authTicket : null
            var user = data && data.user ? data.user : null

            authToken = ticket && ticket.token ? ticket.token.toString() : ""
            tokenExpires = ticket && ticket.expires ? ticket.expires.toString() : ""
            var rawId = user && user.id !== undefined && user.id !== null ? user.id.toString() : ""
            clearError()
            Logger.i("CGM", "LibreLink authentication succeeded")

            if (!rawId) {
                setError("LibreLink login response missing user ID")
                return
            }

            // Hash the account ID with SHA256 (required by LibreLink API)
            _rawAccountId = rawId
            _hashInProgress = true
            hashAccountIdProcess.buffer = ""
            hashAccountIdProcess.command = [
                "sh", "-c",
                "printf '%s' \"$1\" | sha256sum | cut -d' ' -f1",
                "sh",
                rawId
            ]
            hashAccountIdProcess.running = true
        }, function(xhr, error) {
            authToken = ""
            accountId = ""
            tokenExpires = ""
            setError(error ? error.message : ("LibreLink login failed (HTTP " + xhr.status + ")"))
        })
    }

    function fetchConnections() {
        if (!authToken || !accountId) {
            authenticate()
            return
        }

        Logger.i("CGM", "Fetching LibreLink connections")
        runRequest("GET", "/llu/connections", null, true, function(data) {
            var connections = Array.isArray(data) ? data : []
            if (!connections.length) {
                setError("No LibreLink connections available")
                return
            }

            var selected = connections[0]
            patientId = selected && selected.patientId ? selected.patientId.toString() : ""

            if (!patientId) {
                setError("LibreLink connection missing patientId")
                return
            }

            persistSetting("patientId", patientId)
            Logger.i("CGM", "Selected LibreLink patient " + patientId)
            clearError()
            fetchGraphData()
        }, function(xhr, error) {
            if (xhr && (xhr.status === 401 || xhr.status === 403)) {
                Logger.w("CGM", "Connections request unauthorized, re-authenticating")
                authToken = ""
                accountId = ""
                authenticate()
                return
            }

            setError(error ? error.message : ("LibreLink connections failed (HTTP " + xhr.status + ")"))
        })
    }

    function updateFromGraphPayload(data) {
        var connection = data && data.connection ? data.connection : null
        var measurement = connection && connection.glucoseMeasurement ? connection.glucoseMeasurement : null
        var graphData = data && Array.isArray(data.graphData) ? data.graphData : []
        var entries = []
        var i = 0

        for (i = 0; i < graphData.length; ++i) {
            if (!graphData[i] || graphData[i].ValueInMgPerDl === undefined || !graphData[i].Timestamp) {
                continue
            }

            entries.push({
                sgv: Math.round(Number(graphData[i].ValueInMgPerDl)),
                timestamp: normalizeIso(graphData[i].Timestamp)
            })
        }

        if (measurement && measurement.ValueInMgPerDl !== undefined && measurement.Timestamp) {
            var measurementTimestamp = normalizeIso(measurement.Timestamp)
            var found = false
            for (i = 0; i < entries.length; ++i) {
                if (entries[i].timestamp === measurementTimestamp) {
                    entries[i].sgv = Math.round(Number(measurement.ValueInMgPerDl))
                    found = true
                    break
                }
            }

            if (!found) {
                entries.push({
                    sgv: Math.round(Number(measurement.ValueInMgPerDl)),
                    timestamp: measurementTimestamp
                })
            }
        }

        entries.sort(function(a, b) {
            return Date.parse(a.timestamp) - Date.parse(b.timestamp)
        })

        historyModel.clear()
        for (i = 0; i < entries.length; ++i) {
            historyModel.append(entries[i])
        }

        var latest = measurement && measurement.ValueInMgPerDl !== undefined ? {
            sgv: Math.round(Number(measurement.ValueInMgPerDl)),
            timestamp: normalizeIso(measurement.Timestamp),
            trend: measurement.TrendArrow
        } : (entries.length ? {
            sgv: entries[entries.length - 1].sgv,
            timestamp: entries[entries.length - 1].timestamp,
            trend: null
        } : null)

        if (!latest) {
            setError("LibreLink graph did not contain glucose data")
            return
        }

        currentBG = latest.sgv
        trendArrow = trendArrowFromValue(latest.trend)
        lastUpdated = latest.timestamp

        var previous = null
        for (i = entries.length - 1; i >= 0; --i) {
            if (entries[i].timestamp !== latest.timestamp) {
                previous = entries[i]
                break
            }
        }

        if (previous) {
            var minutes = Math.max(1, Math.round((Date.parse(latest.timestamp) - Date.parse(previous.timestamp)) / 60000))
            delta = formatDeltaValue(latest.sgv - previous.sgv) + " (" + minutes + "min)"
        } else {
            delta = "--"
        }

        connected = true
        clearError()
        Logger.i("CGM", "Updated glucose reading: " + currentBG + " mg/dL")

        // Insert into DB and check threshold
        insertReadingsToDb(entries)
        checkThresholdAlert()
    }

    function fetchGraphData() {
        if (_requestInFlight || _storeInProgress || _hashInProgress) {
            return
        }

        if (!email) {
            setError("LibreLink email is not configured")
            return
        }

        if (!patientId) {
            fetchConnections()
            return
        }

        if (!authToken || !accountId) {
            authenticate()
            return
        }

        _requestInFlight = true
        Logger.i("CGM", "Polling LibreLink glucose graph")
        runRequest("GET", "/llu/connections/" + encodeURIComponent(patientId) + "/graph", null, true, function(data) {
            _requestInFlight = false
            updateFromGraphPayload(data)
        }, function(xhr, error) {
            _requestInFlight = false

            if (xhr && (xhr.status === 401 || xhr.status === 403)) {
                Logger.w("CGM", "Graph request unauthorized, re-authenticating")
                authToken = ""
                accountId = ""
                authenticate()
                return
            }

            setError(error ? error.message : ("LibreLink graph failed (HTTP " + xhr.status + ")"))
        })
    }

    function setGraphWindow(hours) {
        graphHours = hours
        loadHistoryFromDb()
    }

    function loadHistoryFromDb() {
        if (!_dbReady) return
        var sinceMs = Date.now() - graphHours * 60 * 60 * 1000
        var sinceISO = new Date(sinceMs).toISOString()
        queryProcess.pendingSinceISO = sinceISO
        queryProcess.buffer = ""
        queryProcess.command = [
            "sqlite3", "-csv", _dbPath,
            "SELECT timestamp, sgv FROM readings WHERE timestamp >= '" + sinceISO + "' ORDER BY timestamp ASC;"
        ]
        queryProcess.running = true
    }

    function insertReadingsToDb(entries) {
        if (!_dbReady || !entries || entries.length === 0) return
        var sql = "BEGIN TRANSACTION;\n"
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (!e.timestamp || !e.sgv || e.sgv <= 0) continue
            sql += "INSERT OR IGNORE INTO readings (timestamp, sgv) VALUES ('" + e.timestamp + "', " + Math.round(e.sgv) + ");\n"
        }
        sql += "COMMIT;\n"
        insertProcess.pendingSql = sql
        insertProcess.buffer = ""
        insertProcess.errorBuffer = ""
        insertProcess.command = ["sqlite3", _dbPath, sql]
        insertProcess.running = true
    }

    function checkThresholdAlert() {
        if (currentBG <= 0) return
        if (bgStatus !== "high" && bgStatus !== "low") return
        var now = Date.now()
        if (now - _lastAlertTime < _alertCooldownMs) return
        _lastAlertTime = now

        var label = bgStatus === "high" ? "High" : "Low"
        var msg = label + " glucose: " + displayBG + " " + units
        ToastService.showWarning("CGM Alert", msg, "activity")
        Logger.w("CGM", "Threshold alert: " + msg)
    }

    function reloadSettings() {
        email = settingValue("email", "")
        region = settingValue("region", "EU")
        units = settingValue("units", "mmol/L")
        lowThreshold = Number(settingValue("lowThreshold", 70))
        highThreshold = Number(settingValue("highThreshold", 180))
        staleMinutes = Number(settingValue("staleMinutes", 15))
        patientId = settingValue("patientId", "")

        Logger.i("CGM", "Reloaded LibreLink settings")

        if (_password) {
            authenticate()
        } else {
            lookupPassword()
        }
    }

    function lookupPassword() {
        _lookupInProgress = true
        lookupPasswordProcess.buffer = ""
        lookupPasswordProcess.errorBuffer = ""
        lookupPasswordProcess.command = ["secret-tool", "lookup", "application", "librelink-cgm", "type", "password"]
        lookupPasswordProcess.running = true
    }

    function storePassword(password) {
        if (password === undefined || password === null || password === "") {
            setError("Cannot store an empty LibreLink password")
            return
        }

        _storeInProgress = true
        storePasswordProcess.pendingPassword = password.toString()
        storePasswordProcess.buffer = ""
        storePasswordProcess.errorBuffer = ""
        storePasswordProcess.command = [
            "sh",
            "-lc",
            "printf '%s' \"$1\" | secret-tool store --label \"LibreLink CGM\" application librelink-cgm type password",
            "sh",
            storePasswordProcess.pendingPassword
        ]
        storePasswordProcess.running = true
    }

    Timer {
        id: pollTimer
        interval: 60000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: root.fetchGraphData()
    }

    ListModel {
        id: historyModel
    }

    Process {
        id: hashAccountIdProcess

        property string buffer: ""

        stdout: SplitParser {
            onRead: data => hashAccountIdProcess.buffer += data
        }

        onRunningChanged: {
            if (running)
                return

            _hashInProgress = false
            var hash = buffer.trim()
            buffer = ""

            if (hash) {
                accountId = hash
                Logger.i("CGM", "Account ID hashed successfully")

                if (!patientId) {
                    fetchConnections()
                } else {
                    fetchGraphData()
                }
            } else {
                setError("Failed to hash LibreLink account ID")
            }
        }
    }

    Process {
        id: lookupPasswordProcess

        property string buffer: ""
        property string errorBuffer: ""

        stdout: SplitParser {
            onRead: data => lookupPasswordProcess.buffer += data
        }

        stderr: SplitParser {
            onRead: data => lookupPasswordProcess.errorBuffer += data
        }

        onRunningChanged: {
            if (running) {
                return
            }

            _lookupInProgress = false

            var password = buffer.trim()
            var stderrText = errorBuffer.trim()
            buffer = ""
            errorBuffer = ""

            if (password) {
                _password = password
                clearError()
                Logger.i("CGM", "Loaded LibreLink password from keyring")
                if (email) {
                    authenticate()
                }
                return
            }

            Logger.w("CGM", "LibreLink password not found in keyring" + (stderrText ? ": " + stderrText : ""))
            if (email) {
                setError("LibreLink password not found in keyring")
            }
        }
    }

    Process {
        id: storePasswordProcess

        property string buffer: ""
        property string errorBuffer: ""
        property string pendingPassword: ""

        stdout: SplitParser {
            onRead: data => storePasswordProcess.buffer += data
        }

        stderr: SplitParser {
            onRead: data => storePasswordProcess.errorBuffer += data
        }

        onRunningChanged: {
            if (running) {
                return
            }

            _storeInProgress = false

            var stderrText = errorBuffer.trim()
            var savedPassword = pendingPassword
            pendingPassword = ""
            buffer = ""
            errorBuffer = ""

            if (stderrText) {
                Logger.w("CGM", "secret-tool store stderr: " + stderrText)
            }

            _password = savedPassword
            clearError()
            Logger.i("CGM", "Stored LibreLink password in keyring")
            authenticate()
        }
    }

    // --- SQLite DB Processes ---

    Process {
        id: initDbPathProcess

        property string buffer: ""

        stdout: SplitParser {
            onRead: data => initDbPathProcess.buffer += data
        }

        onRunningChanged: {
            if (running) return
            var home = buffer.trim()
            buffer = ""
            if (!home) home = "/tmp"
            _dbPath = home + "/.cache/noctalia/plugins/librelink-cgm/readings.db"
            var dbDir = home + "/.cache/noctalia/plugins/librelink-cgm"
            ensureDbDirProcess.buffer = ""
            ensureDbDirProcess.command = ["mkdir", "-p", dbDir]
            ensureDbDirProcess.running = true
        }
    }

    Process {
        id: initDbProcess

        property string buffer: ""
        property string errorBuffer: ""

        stdout: SplitParser {
            onRead: data => initDbProcess.buffer += data
        }

        stderr: SplitParser {
            onRead: data => initDbProcess.errorBuffer += data
        }

        onRunningChanged: {
            if (running) return
            var err = errorBuffer.trim()
            buffer = ""
            errorBuffer = ""

            if (err) {
                Logger.e("CGM", "DB init error: " + err)
                return
            }

            _dbReady = true
            Logger.i("CGM", "SQLite database ready")

            // Delete non-ISO timestamps (legacy data from before fix) and prune >30d
            var cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
            pruneProcess.buffer = ""
            pruneProcess.errorBuffer = ""
            pruneProcess.command = ["sqlite3", _dbPath,
                "DELETE FROM readings WHERE timestamp NOT LIKE '____-__-__T%'; DELETE FROM readings WHERE timestamp < '" + cutoff + "';"]
            pruneProcess.running = true
        }
    }

    Process {
        id: insertProcess

        property string buffer: ""
        property string errorBuffer: ""
        property string pendingSql: ""

        stdout: SplitParser {
            onRead: data => insertProcess.buffer += data
        }

        stderr: SplitParser {
            onRead: data => insertProcess.errorBuffer += data
        }

        onRunningChanged: {
            if (running) return
            var err = errorBuffer.trim()
            buffer = ""
            errorBuffer = ""
            pendingSql = ""

            if (err) {
                Logger.w("CGM", "DB insert error: " + err)
                return
            }

            // Reload chart from DB after insert
            loadHistoryFromDb()
        }
    }

    Process {
        id: queryProcess

        property string buffer: ""
        property string pendingSinceISO: ""

        stdout: SplitParser {
            onRead: data => queryProcess.buffer += data + "\n"
        }

        onRunningChanged: {
            if (running) return
            var raw = buffer.trim()
            buffer = ""
            pendingSinceISO = ""

            historyModel.clear()
            if (!raw) return

            var lines = raw.split("\n")
            for (var i = 0; i < lines.length; ++i) {
                var parts = lines[i].split(",")
                if (parts.length < 2) continue
                var ts = parts[0]
                var sgv = parseInt(parts[1], 10)
                if (isNaN(sgv) || sgv <= 0) continue
                historyModel.append({ timestamp: ts, sgv: sgv })
            }

            Logger.i("CGM", "Loaded " + historyModel.count + " readings from DB (" + graphHours + "h window)")
            historyRevision++
        }
    }

    Process {
        id: pruneProcess

        property string buffer: ""
        property string errorBuffer: ""

        stdout: SplitParser {
            onRead: data => pruneProcess.buffer += data
        }

        stderr: SplitParser {
            onRead: data => pruneProcess.errorBuffer += data
        }

        onRunningChanged: {
            if (running) return
            var err = errorBuffer.trim()
            buffer = ""
            errorBuffer = ""
            if (err) {
                Logger.w("CGM", "DB prune error: " + err)
            } else {
                Logger.i("CGM", "Pruned readings older than 30 days")
            }

            // Load initial chart data
            loadHistoryFromDb()
        }
    }

    Process {
        id: ensureDbDirProcess

        property string buffer: ""

        stdout: SplitParser {
            onRead: data => ensureDbDirProcess.buffer += data
        }

        onRunningChanged: {
            if (running) return
            buffer = ""

            // Now init the schema
            var sql = "CREATE TABLE IF NOT EXISTS readings (timestamp TEXT PRIMARY KEY, sgv INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS idx_readings_timestamp ON readings(timestamp);"
            initDbProcess.buffer = ""
            initDbProcess.errorBuffer = ""
            initDbProcess.command = ["sqlite3", _dbPath, sql]
            initDbProcess.running = true
        }
    }

    Component.onCompleted: {
        Logger.i("CGM", "Starting LibreLink CGM plugin")

        // Initialize SQLite DB
        initDbPathProcess.buffer = ""
        initDbPathProcess.command = ["sh", "-c", "echo $HOME"]
        initDbPathProcess.running = true

        reloadSettings()
    }
}
