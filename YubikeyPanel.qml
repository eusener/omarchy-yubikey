import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// YubiKey management for Omarchy.
//
// Four pages, one per question people actually have about a security key:
// what is this key (Device), how do I log into this machine with it (System),
// how do I log into my accounts with it (Accounts), and why is nothing working
// (Setup). Everything is drawn from qs.Ui, so the panel follows the active
// theme with no styling of its own.
//
// The panel holds no state it did not just read. Every page re-reads from
// `bin/omarchy-yubikey` on open and after every change, because the key is a
// physical object that can be pulled out mid-session and a cached view of it
// is a lie waiting to happen.
//
// Nothing that prompts for a PIN, a touch, or a password runs inside the shell
// process. Those go out to `omarchy-yubikey term <cmd>`, which opens a real
// terminal — the same thing `omarchy setup security fido2` does, and the only
// honest way to ask for a touch.
Item {
  id: root

  // ---- plugin lifecycle ---------------------------------------------------
  property bool closingFromHost: false
  property var shell: null
  property var manifest: null

  function open(payloadJson) {
    closingFromHost = false
    // `omarchy-shell shell toggle eusener.yubikey '{"tab":"setup"}'` opens on a page.
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && ["device", "system", "accounts", "setup"].indexOf(p.tab) >= 0) setTab(p.tab)
    } catch (e) {}
    window.visible = true
    reloadAll()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- theme --------------------------------------------------------------
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color dimmer: Qt.darker(foreground, 1.6)
  readonly property string fontFamily: Style.font.family

  // ---- language -----------------------------------------------------------
  //
  // The panel ships its own catalogs in i18n/ and picks between them with a
  // switch in the header, independent of the system language. The choice is
  // kept outside the plugin directory (which is a git checkout) so updates do
  // not trip over it; with no choice saved, it follows Setup > Language.
  readonly property var languages: [
    { value: "pt-BR", label: "PT-BR", tooltip: root.t("header.language") },
    { value: "en",    label: "EN-US", tooltip: root.t("header.language") }
  ]
  readonly property string langStateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-yubikey/language"
  property string langOverride: ""
  readonly property string savedLang: String(langFile.text() || "").trim()
  readonly property string lang: {
    var c = langOverride || savedLang
    if (c === "en" || c === "pt-BR") return c
    return String(I18n.language || "").indexOf("pt") === 0 ? "pt-BR" : "en"
  }

  function setLang(code) {
    if (code !== "en" && code !== "pt-BR") return
    langOverride = code
    Quickshell.execDetached(["/bin/sh", "-c", "mkdir -p \"$(dirname \"$0\")\" && printf '%s\\n' \"$1\" > \"$0\"",
                             langStateFile, code])
  }

  function cycleLang(dir) {
    var i = 0
    for (var n = 0; n < languages.length; n++) if (languages[n].value === lang) i = n
    setLang(languages[(i + (dir < 0 ? languages.length - 1 : 1)) % languages.length].value)
  }

  FileView { id: langFile; path: root.langStateFile; watchChanges: true; printErrors: false; blockLoading: true; onFileChanged: reload() }

  function catalogPath(code) { return String(Qt.resolvedUrl("i18n/" + code + ".json")).replace(/^file:\/\//, "") }
  FileView { id: enCatalog; path: root.catalogPath("en");    watchChanges: true; printErrors: false; blockLoading: true; onFileChanged: reload() }
  FileView { id: ptCatalog; path: root.catalogPath("pt-BR"); watchChanges: true; printErrors: false; blockLoading: true; onFileChanged: reload() }

  function parseCatalog(raw) {
    try { var p = JSON.parse(raw || "{}"); return (p && typeof p === "object" && !Array.isArray(p)) ? p : ({}) }
    catch (e) { return ({}) }
  }
  readonly property var enStrings: parseCatalog(enCatalog.text())
  readonly property var ptStrings: parseCatalog(ptCatalog.text())
  readonly property var strings: lang === "pt-BR" ? ptStrings : enStrings

  // Falls back to English, then to the given fallback, then to the key.
  function t(key, fallback) {
    var layers = [root.strings, root.enStrings]
    for (var i = 0; i < layers.length; i++) {
      var v = layers[i][key]
      if (v && typeof v === "object") v = v.other
      if (typeof v === "string" && v.length > 0) return v
    }
    return fallback !== undefined ? fallback : key
  }

  // Plural entries: English "one" is exactly 1; Brazilian Portuguese "one"
  // covers 0 and 1 (CLDR).
  function tn(key, count) {
    var n = Number(count)
    var layers = [[root.strings, root.lang], [root.enStrings, "en"]]
    for (var i = 0; i < layers.length; i++) {
      var v = layers[i][0][key]
      if (!v) continue
      if (typeof v === "string") return v
      var one = layers[i][1] === "pt-BR" ? (n === 0 || n === 1) : n === 1
      var form = one && v.one ? v.one : v.other
      if (typeof form === "string" && form.length > 0) return form
    }
    return key
  }

  // ---- backend ------------------------------------------------------------
  //
  // PluginRegistry stamps __sourceDir onto the manifest, which is how the QML
  // locates the script it ships with without knowing where plugins live.
  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "eusener.yubikey"
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  readonly property string helper: sourceDir ? sourceDir + "/bin/omarchy-yubikey" : ""

  property string errorText: ""
  property string busyText: ""

  // ---- data ---------------------------------------------------------------
  property var status: ({ present: false, devices: [], pins: {}, pivSlots: [], missingTool: true })
  property var deps: ({ deps: [], missing: 0, pcscdRunning: false })
  property var pam: ({ services: [], registered: false, keyCount: 0, authfile: "/etc/fido2/fido2" })
  property var ssh: ({ skKeys: [], pkcs11Module: "", gpgSshEnabled: false })
  property var sshKeys: ({ piv: { readable: false, keys: [] }, openpgp: { present: false }, fido: { residentSlotsRemaining: null } })
  property var luks: ({ devices: [], hasCryptenroll: false })
  property var oath: ({ locked: false, accounts: [], error: "" })
  property var providers: []

  readonly property var device: (status && status.devices && status.devices.length > 0) ? status.devices[0] : null
  readonly property bool toolingMissing: !!(status && status.missingTool)
  readonly property bool keyPresent: !!(status && status.present)

  // Applets the panel offers a switch for, in the order a person meets them.
  // Names match what `ykman info` prints; a key that lacks one simply has no
  // row, because the table it is read from has no row either.
  // Spelled exactly as `ykman info` prints them — the backend maps these to the
  // short keys `ykman config usb` wants, since the two vocabularies differ.
  readonly property var appletOrder: ["FIDO2", "FIDO U2F", "OATH", "PIV", "OpenPGP", "Yubico OTP", "YubiHSM Auth"]

  readonly property var applets: {
    var out = []
    if (!device || !device.applications) return out
    for (var i = 0; i < appletOrder.length; i++) {
      var name = appletOrder[i]
      var row = device.applications[name]
      if (!row) continue
      var usb = String(row.usb || "")
      if (usb.toLowerCase().indexOf("not available") >= 0) continue
      out.push({ name: name, enabled: usb.toLowerCase().indexOf("enabled") >= 0, nfc: String(row.nfc || "") })
    }
    return out
  }

  // ---- readers ------------------------------------------------------------
  //
  // One shape for every read: run the backend, parse JSON, hand it to a
  // callback. A read that produces no JSON leaves the previous value in place
  // and says so, rather than blanking the page.
  component JsonReader: Process {
    id: reader
    property var argv: []
    property var sink: null
    property string label: ""
    property bool parsedOk: false

    // Everything goes through sh so a missing backend still produces an exit
    // code instead of silently never running.
    command: ["/bin/sh", "-c", "exec \"$0\" \"$@\"", root.helper].concat(argv)
    onRunningChanged: if (running) parsedOk = false
    onExited: function(exitCode) {
      if (!parsedOk && exitCode !== 0)
        root.errorText = root.t("error.command").arg("omarchy-yubikey " + argv.join(" ")).arg(exitCode)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || ""))
          reader.parsedOk = true
          if (reader.sink) reader.sink(d)
        } catch (e) {
          // Left deliberately quiet: onExited reports the real failure, and a
          // parse error with exit 0 means an empty read, not a broken one.
        }
      }
    }
  }

  // A terminal command is holding the key (see TERM_LOCK in the backend). Keep
  // what is on screen and keep asking until it lets go, however long the PIN
  // prompt takes.
  function keyBusy(d) {
    if (!d || !d.busy) return false
    termRefresh.ticks = 0
    if (!termRefresh.running) termRefresh.restart()
    return true
  }

  JsonReader { id: statusReader;    argv: ["status"];      sink: function(d) { if (root.keyBusy(d)) return; root.status = d; root.errorText = "" } }
  JsonReader { id: depsReader;      argv: ["deps"];        sink: function(d) { root.deps = d } }
  JsonReader { id: pamReader;       argv: ["pam-status"];  sink: function(d) { root.pam = d } }
  JsonReader { id: sshReader;       argv: ["ssh-status"];  sink: function(d) { root.ssh = d } }
  JsonReader { id: sshKeysReader;   argv: ["ssh-keys"];    sink: function(d) { if (root.keyBusy(d)) return; root.sshKeys = d; root.clampCursor() } }
  JsonReader { id: luksReader;      argv: ["luks-status"]; sink: function(d) { root.luks = d } }
  JsonReader { id: oathReader;      argv: ["oath-list"];   sink: function(d) { if (root.keyBusy(d)) return; root.oath = d; root.clampCursor() } }
  JsonReader { id: providersReader; argv: ["providers"];   sink: function(d) { root.providers = d } }

  function reloadAll() {
    if (!helper) {
      errorText = root.t("error.noPluginDir")
      return
    }
    statusReader.running = true
    depsReader.running = true
    pamReader.running = true
    sshReader.running = true
    sshKeysReader.running = true
    luksReader.running = true
    oathReader.running = true
    if (!providers || providers.length === 0) providersReader.running = true
  }

  // ---- actions ------------------------------------------------------------
  //
  // Two kinds. `run` is a change the shell can make on its own; it refreshes
  // when it finishes. `runTerm` is a change that needs a human at a keyboard
  // (a PIN, a touch, a sudo password) and opens a terminal to get one.
  Process {
    id: actionProc
    property string describe: ""
    onExited: function(exitCode) {
      root.busyText = ""
      if (exitCode !== 0) root.errorText = root.t("error.action").arg(describe).arg(exitCode)
      else root.errorText = ""
      root.reloadAll()
    }
  }

  function run(argv, describe) {
    if (!helper || actionProc.running) return
    actionProc.describe = describe || argv.join(" ")
    busyText = describe || ""
    errorText = ""
    actionProc.command = ["/bin/sh", "-c", "exec \"$0\" \"$@\"", helper].concat(argv)
    actionProc.running = true
  }

  // The terminal owns the interaction from here, so the panel stops guessing
  // and re-reads once the window has had time to close.
  function runTerm(argv) {
    if (!helper) return
    Quickshell.execDetached(["/bin/sh", "-c", "exec \"$0\" term \"$@\"", helper].concat(argv))
    termRefresh.restart()
  }

  Timer { id: termRefresh; interval: 2500; repeat: true; triggeredOnStart: false
    property int ticks: 0
    onTriggered: { root.reloadAll(); ticks++; if (ticks > 8) { stop(); ticks = 0 } }
    onRunningChanged: if (running) ticks = 0
  }

  function openUrl(url) { Quickshell.execDetached(["xdg-open", url]) }

  // ---- security wizard ----------------------------------------------------
  //
  // A checklist computed from the same reads every page uses, so it re-grades
  // itself whenever the panel re-reads — including after a terminal closes.
  // Each step is one of: ok, todo, warn (done but needs attention), blocked
  // (waiting on an earlier step), or na (does not apply, so not shown).
  // Skips are remembered across sessions; nothing else about the wizard is.
  readonly property string wizardStateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-yubikey/wizard-skipped"
  FileView { id: wizardFile; path: root.wizardStateFile; watchChanges: true; printErrors: false; blockLoading: true; onFileChanged: reload() }
  property var skipOverride: null
  readonly property var skipped: {
    if (skipOverride) return skipOverride
    var out = ({})
    var lines = String(wizardFile.text() || "").split("\n")
    for (var i = 0; i < lines.length; i++) if (/^[a-z0-9-]+$/.test(lines[i].trim())) out[lines[i].trim()] = true
    return out
  }

  function toggleSkip(id) {
    var next = ({})
    for (var k in skipped) if (k !== id) next[k] = true
    if (!skipped[id]) next[id] = true
    skipOverride = next
    wizardSelected = ""
    Quickshell.execDetached(["/bin/sh", "-c", "mkdir -p \"$(dirname \"$0\")\" && printf '%s' \"$1\" > \"$0\"",
                             wizardStateFile, Object.keys(next).join("\n") + "\n"])
  }

  readonly property bool checking: statusReader.running || depsReader.running || pamReader.running
    || sshReader.running || sshKeysReader.running || luksReader.running

  readonly property var wizardSteps: {
    var out = []
    var pins = (status && status.pins) ? status.pins : ({})
    var fido = pins.fido || null
    var piv = pins.piv || null
    var key = keyPresent
    function add(o) { if (o.state !== "na") out.push(o) }

    // -- essential
    var depsOk = deps.missing === 0 && deps.pcscdRunning
    add({ id: "tools", level: "essential", icon: "󰏔",
          state: depsOk ? "ok" : "todo",
          title: t("wiz.tools"), why: t("wiz.tools.why"),
          detail: depsOk ? t("wiz.tools.ok") : (deps.missing > 0 ? t("setup.missingCount").arg(deps.missing) : t("wiz.tools.pcscd")),
          action: t("wiz.tools.do"), kind: "term", argv: ["install-deps"] })

    add({ id: "key", level: "essential", icon: "󰌆",
          state: key ? "ok" : "todo",
          title: t("wiz.key"), why: t("wiz.key.why"),
          detail: key ? t("wiz.key.ok").arg(device ? (device.name || "YubiKey") : "YubiKey") : t("wiz.key.todo"),
          action: t("wiz.key.do"), kind: "refresh" })

    var fidoRetries = fido && fido.retries ? Number(fido.retries) : 0
    add({ id: "fido-pin", level: "essential", icon: "󰯄",
          state: !key ? "blocked" : (!fido || !fido.set) ? "todo" : (fidoRetries > 0 && fidoRetries <= 3 ? "warn" : "ok"),
          title: t("wiz.fidoPin"), why: t("wiz.fidoPin.why"),
          detail: !key ? t("wiz.blocked.key")
                : (!fido || !fido.set) ? t("wiz.fidoPin.todo")
                : (fidoRetries > 0 && fidoRetries <= 3) ? t("wiz.fidoPin.warn").arg(fidoRetries)
                : (fidoRetries > 0 ? tn("pin.triesLeft", fidoRetries).arg(fidoRetries) : t("pin.set")),
          action: (fido && fido.set) ? t("wiz.changePin") : t("wiz.setPin"), kind: "term", argv: ["pin", "fido2"] })

    var pivHere = !!(piv && piv.present)
    add({ id: "piv-pin", level: "essential", icon: "󰄀",
          state: !key ? "blocked" : !pivHere ? "na" : (piv.defaultPin ? "todo" : "ok"),
          title: t("wiz.pivPin"), why: t("wiz.pivPin.why"),
          detail: !key ? t("wiz.blocked.key") : (pivHere && piv.defaultPin ? t("wiz.pivPin.todo") : t("wiz.notDefault")),
          action: t("wiz.changePin"), kind: "term", argv: ["pin", "piv"] })
    add({ id: "piv-puk", level: "essential", icon: "󰄀",
          state: !key ? "blocked" : !pivHere ? "na" : (piv.defaultPuk ? "todo" : "ok"),
          title: t("wiz.pivPuk"), why: t("wiz.pivPuk.why"),
          detail: !key ? t("wiz.blocked.key") : (pivHere && piv.defaultPuk ? t("wiz.pivPuk.todo") : t("wiz.notDefault")),
          action: t("wiz.pivPuk.do"), kind: "term", argv: ["pin", "piv-puk"] })
    add({ id: "piv-mgmt", level: "essential", icon: "󰄀",
          state: !key ? "blocked" : !pivHere ? "na" : (piv.defaultMgmt ? "todo" : "ok"),
          title: t("wiz.pivMgmt"), why: t("wiz.pivMgmt.why"),
          detail: !key ? t("wiz.blocked.key") : (pivHere && piv.defaultMgmt ? t("wiz.pivMgmt.todo") : t("wiz.pivMgmt.ok")),
          action: t("wiz.pivMgmt.do"), kind: "term", argv: ["pin", "piv-mgmt"] })

    // Only shown when the provider is on; broken when no PIV slot holds a key.
    var pivKeys = (sshKeys && sshKeys.piv && sshKeys.piv.keys) ? sshKeys.piv.keys.length : 0
    add({ id: "ssh-config", level: "essential", icon: "󰣀",
          state: !ssh.pkcs11InSshConfig ? "na" : (pivKeys > 0 ? "ok" : "warn"),
          title: t("wiz.sshConfig"), why: t("wiz.sshConfig.why"),
          detail: pivKeys > 0 ? t("wiz.sshConfig.ok") : t("wiz.sshConfig.warn"),
          action: t("wiz.sshConfig.do"), kind: "run", argv: ["ssh-piv", "off"], busy: t("wiz.sshConfig.busy") })

    // -- recommended
    var registered = !!pam.registered
    add({ id: "pam-register", level: "recommended", icon: "󰌆",
          state: registered ? "ok" : (!key ? "blocked" : "todo"),
          title: t("wiz.pam"), why: t("wiz.pam.why"),
          detail: registered ? tn("pam.registeredCount", pam.keyCount).arg(pam.keyCount) : (!key ? t("wiz.blocked.key") : t("wiz.pam.todo")),
          action: t("wiz.pam.do"), kind: "term", argv: ["pam-register"] })
    add({ id: "backup", level: "recommended", icon: "󰆓",
          state: pam.keyCount >= 2 ? "ok" : (!registered ? "blocked" : "todo"),
          title: t("wiz.backup"), why: t("wiz.backup.why"),
          detail: pam.keyCount >= 2 ? tn("pam.registeredCount", pam.keyCount).arg(pam.keyCount) : (!registered ? t("wiz.blocked.pam") : t("wiz.backup.todo")),
          action: t("wiz.backup.do"), kind: "term", argv: ["pam-register"] })
    var skCount = (ssh.skKeys || []).length
    var fidoReady = !!(fido && fido.set)
    add({ id: "ssh-key", level: "recommended", icon: "󰌘",
          state: skCount > 0 ? "ok" : (!key ? "blocked" : (!fidoReady ? "blocked" : "todo")),
          title: t("wiz.sshKey"), why: t("wiz.sshKey.why"),
          detail: skCount > 0 ? tn("ssh.onDisk", skCount).arg(skCount) : (!key ? t("wiz.blocked.key") : (!fidoReady ? t("wiz.blocked.fido") : t("wiz.sshKey.todo"))),
          action: t("wiz.sshKey.do"), kind: "term", argv: ["ssh-sk", "ed25519-sk", "resident"] })

    // -- optional
    var sudoSvc = pamService("sudo")
    add({ id: "sudo", level: "optional", icon: "󰆍",
          state: !sudoSvc ? "na" : (sudoSvc.enabled ? "ok" : (!registered ? "blocked" : "todo")),
          title: t("wiz.sudo"), why: t("wiz.sudo.why"),
          detail: sudoSvc && sudoSvc.enabled ? t("state.on") : (!registered ? t("wiz.blocked.pam") : t("state.off")),
          action: t("wiz.turnOn"), kind: "pam", argv: ["sudo"] })
    var otp = null
    for (var a = 0; a < applets.length; a++) if (applets[a].name === "Yubico OTP") otp = applets[a]
    add({ id: "otp", level: "optional", icon: "󰌌",
          state: !key ? "na" : (!otp ? "na" : (otp.enabled ? "todo" : "ok")),
          title: t("wiz.otp"), why: t("wiz.otp.why"),
          detail: otp && otp.enabled ? t("state.on") : t("state.off"),
          action: t("wiz.otp.do"), kind: "applet", argv: ["Yubico OTP"] })
    var disk = (luks.devices && luks.devices.length > 0) ? luks.devices[0] : null
    add({ id: "luks", level: "optional", icon: "󰋊",
          state: !disk || !luks.hasCryptenroll ? "na" : (disk.fido2Tokens > 0 ? "ok" : (!key ? "blocked" : (!fidoReady ? "blocked" : "todo"))),
          title: t("wiz.luks"), why: t("wiz.luks.why").arg(disk ? disk.device : ""),
          detail: disk && disk.fido2Tokens > 0 ? t("luks.enrolled") : (!key ? t("wiz.blocked.key") : (!fidoReady ? t("wiz.blocked.fido") : t("wiz.luks.todo"))),
          action: t("wiz.luks.do"), kind: "term", argv: ["luks-enroll"] })

    for (var n = 0; n < out.length; n++) out[n].skipped = !!skipped[out[n].id] && out[n].state !== "ok"
    return out
  }

  function wizardCount(level, doneOnly) {
    var c = 0
    for (var i = 0; i < wizardSteps.length; i++) {
      var s = wizardSteps[i]
      if (s.level !== level) continue
      if (!doneOnly || s.state === "ok") c++
    }
    return c
  }
  readonly property bool essentialsDone: wizardCount("essential", true) === wizardCount("essential", false)

  // The step on screen: the one the user picked, else the first that still
  // needs doing. A picked step that just turned ok lets go, so finishing a
  // step moves the wizard forward on its own.
  property string wizardSelected: ""
  property string wizardSelectedState: ""
  function wizardStep(id) {
    for (var i = 0; i < wizardSteps.length; i++) if (wizardSteps[i].id === id) return wizardSteps[i]
    return null
  }
  readonly property var wizardFirstPending: {
    for (var i = 0; i < wizardSteps.length; i++) {
      var s = wizardSteps[i]
      if ((s.state === "todo" || s.state === "warn") && !s.skipped) return s
    }
    return null
  }
  readonly property var wizardCurrent: (wizardSelected && wizardStep(wizardSelected)) || wizardFirstPending
  readonly property int wizardCurrentIndex: {
    if (!wizardCurrent) return -1
    for (var i = 0; i < wizardSteps.length; i++) if (wizardSteps[i].id === wizardCurrent.id) return i
    return -1
  }
  onWizardStepsChanged: {
    var s = wizardSelected ? wizardStep(wizardSelected) : null
    if (!s) { wizardSelected = ""; return }
    if (s.state === "ok" && wizardSelectedState !== "ok") wizardSelected = ""
    else wizardSelectedState = s.state
  }

  function selectStep(id) {
    var s = wizardStep(id)
    wizardSelected = id
    wizardSelectedState = s ? s.state : ""
  }

  function runWizardStep(s) {
    if (!s || s.state === "blocked" || s.state === "ok") return
    if (s.kind === "term") runTerm(s.argv)
    else if (s.kind === "run") run(s.argv, s.busy)
    else if (s.kind === "refresh") reloadAll()
    else if (s.kind === "pam") togglePam(s.argv[0])
    else if (s.kind === "applet") toggleApplet(s.argv[0])
  }

  function wizardStateLabel(s) {
    if (s.skipped) return t("wiz.state.skipped")
    return t("wiz.state." + s.state)
  }
  function wizardStateColor(s) {
    if (s.state === "ok") return root.accent
    if (s.skipped || s.state === "blocked") return root.dimmer
    if (s.state === "warn" || s.level === "essential") return root.urgent
    return root.dim
  }
  function wizardStateIcon(s) {
    if (s.state === "ok") return "󰄬"
    if (s.skipped) return "󰒭"
    if (s.state === "blocked") return "󰏤"
    if (s.state === "warn") return "󰀦"
    return "󰄱"
  }

  // ---- cursor model -------------------------------------------------------
  //
  // One flat list of targets per page, same as the gallery and the stock
  // panels, so j/k crosses section boundaries without special cases. Entries
  // that stand for a row of live data carry the row's id after a colon.
  property string tab: "device"
  property string focusSection: "tabs"

  readonly property var tabs: [
    { value: "device",   label: root.t("tab.device"),   icon: "󰌆" },
    { value: "system",   label: root.t("tab.system"),   icon: "󰌾" },
    { value: "accounts", label: root.t("tab.accounts"), icon: "󰇮" },
    { value: "setup",    label: root.t("tab.setup"),    icon: "󰒓" }
  ]

  readonly property var visibleSections: {
    var s = ["tabs", "lang", "refresh"]
    if (tab === "device") {
      if (keyPresent) {
        for (var i = 0; i < applets.length; i++) s.push("app:" + applets[i].name)
        s = s.concat(["pin:fido2", "pin:piv", "pin:openpgp",
                      "reset:fido2", "reset:piv", "reset:oath", "reset:openpgp"])
      }
    } else if (tab === "system") {
      s.push("pam-register")
      var svcs = (pam && pam.services) ? pam.services : []
      for (var j = 0; j < svcs.length; j++) s.push("pam:" + svcs[j].service)
      var onKey = cardSshKeys
      for (var n = 0; n < onKey.length; n++) s.push("sshkey:" + onKey[n].id)
      s = s.concat(["ssh-sk-list", "ssh-sk", "ssh-sk-plain", "ssh-recover", "ssh-piv", "gpg-ssh"])
      if (luks && luks.devices && luks.devices.length > 0) s.push("luks-enroll")
      s.push("pam-forget")
    } else if (tab === "accounts") {
      s = s.concat(["oath-scan", "oath-issuer", "oath-name", "oath-secret", "oath-touch", "oath-add"])
      var accts = (oath && oath.accounts) ? oath.accounts : []
      for (var k = 0; k < accts.length; k++) s.push("oath:" + accts[k].id)
      for (var m = 0; m < providers.length; m++) s.push("prov:" + providers[m].id)
    } else {
      s.push("wiz-run")
      if (wizardCurrent) s = s.concat(["wiz-do", "wiz-skip"])
      for (var w = 0; w < wizardSteps.length; w++) s.push("wiz-step:" + wizardSteps[w].id)
      s.push("install-deps")
    }
    return s
  }

  function moveCursor(dy) {
    var list = visibleSections
    var i = list.indexOf(focusSection)
    if (i < 0) i = 0
    focusSection = list[Math.max(0, Math.min(list.length - 1, i + (dy > 0 ? 1 : -1)))]
  }

  // h/l only means something on the tab row; elsewhere it stays a no-op rather
  // than jumping the cursor somewhere the user did not ask for.
  function moveCursorH(dx) {
    if (focusSection === "lang") { cycleLang(dx); return }
    if (focusSection !== "tabs") return
    var i = 0
    for (var t = 0; t < tabs.length; t++) if (tabs[t].value === tab) i = t
    setTab(tabs[Math.max(0, Math.min(tabs.length - 1, i + (dx > 0 ? 1 : -1)))].value)
  }

  function setTab(v) {
    if (tab === v) return
    tab = v
    focusSection = "tabs"
  }

  function clampCursor() {
    if (visibleSections.indexOf(focusSection) < 0) focusSection = "tabs"
  }
  onTabChanged: {
    clampCursor()
    // A new page starts at the top; otherwise the old page's scroll offset
    // carries over and the page opens somewhere in its middle.
    if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
  }

  // These pages are longer than the window, so walking the cursor with j/k has
  // to bring the view along with it. Same shape as the gallery's version.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(12)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function activateCursor() {
    var s = focusSection
    if (s === "refresh") { reloadAll(); return }
    if (s === "lang") { cycleLang(1); return }
    if (s === "pam-register") { runTerm(["pam-register"]); return }
    if (s === "pam-forget") { runTerm(["pam-forget"]); return }
    if (s === "ssh-sk") { runTerm(["ssh-sk", "ed25519-sk", "resident"]); return }
    if (s === "ssh-sk-plain") { runTerm(["ssh-sk", "ed25519-sk", "nonresident"]); return }
    if (s === "ssh-recover") { runTerm(["ssh-recover"]); return }
    if (s === "ssh-sk-list") { runTerm(["ssh-sk-list"]); return }
    if (s.indexOf("sshkey:") === 0) { copySshKey(s.substring(7)); return }
    if (s === "ssh-piv") { runTerm(["ssh-piv"]); return }
    if (s === "gpg-ssh") { run(["gpg-ssh", ssh.gpgSshEnabled ? "off" : "on"], root.t("busy.gpgSsh")); return }
    if (s === "luks-enroll") { runTerm(["luks-enroll"]); return }
    if (s === "install-deps") { runTerm(["install-deps"]); return }
    if (s === "wiz-run") { reloadAll(); return }
    if (s === "wiz-do") { runWizardStep(wizardCurrent); return }
    if (s === "wiz-skip") { if (wizardCurrent) toggleSkip(wizardCurrent.id); return }
    if (s.indexOf("wiz-step:") === 0) { selectStep(s.substring(9)); return }
    if (s === "oath-scan") { runTerm(["oath-scan"]); return }
    if (s === "oath-add") { submitAccount(); return }
    if (s === "oath-touch") { newTouch = !newTouch; return }
    if (s.indexOf("pam:") === 0) { togglePam(s.substring(4)); return }
    if (s.indexOf("app:") === 0) { toggleApplet(s.substring(4)); return }
    if (s.indexOf("pin:") === 0) { runTerm(["pin", s.substring(4)]); return }
    if (s.indexOf("reset:") === 0) { runTerm(["reset", s.substring(6)]); return }
    if (s.indexOf("oath:") === 0) { generateCode(s.substring(5)); return }
    if (s.indexOf("prov:") === 0) { openProvider(s.substring(5)); return }
  }

  // ---- page actions -------------------------------------------------------

  function pamService(name) {
    var svcs = (pam && pam.services) ? pam.services : []
    for (var i = 0; i < svcs.length; i++) if (svcs[i].service === name) return svcs[i]
    return null
  }

  function togglePam(name) {
    var svc = pamService(name)
    if (!svc) return
    // Turning a stack on with nothing registered would prompt for a touch from
    // a key that PAM has never been introduced to, and quietly fall through
    // forever. Send the user to registration instead of writing the line.
    if (!svc.enabled && !pam.registered) {
      errorText = root.t("error.pamNotRegistered").arg(pam.authfile)
      return
    }
    run([svc.enabled ? "pam-disable" : "pam-enable", name],
        (svc.enabled ? root.t("busy.pamRemove") : root.t("busy.pamAdd")).arg(name))
  }

  function toggleApplet(name) {
    var target = null
    for (var i = 0; i < applets.length; i++) if (applets[i].name === name) target = applets[i]
    if (!target) return
    if (target.enabled) {
      // Disabling is the destructive direction: an applet switched off over
      // USB takes every credential on it out of reach until it is switched
      // back on, and switching FIDO2 off can lock the key out of this session.
      confirm.message = root.t("confirm.disableApplet").arg(name)
      confirm.confirmText = root.t("confirm.disable")
      confirm.action = function() { root.run(["app", name, "off"], root.t("busy.disabling").arg(name)) }
      confirm.opened = true
    } else {
      run(["app", name, "on"], root.t("busy.enabling").arg(name))
    }
  }

  // ---- account entry ------------------------------------------------------
  property string newIssuer: ""
  property string newName: ""
  property string newSecret: ""
  property bool newTouch: false

  function submitAccount() {
    if (newName.length === 0 || newSecret.length === 0) {
      errorText = root.t("error.accountIncomplete")
      return
    }
    run(["oath-add", newIssuer, newName, newSecret, newTouch ? "touch" : "no"],
        root.t("busy.adding").arg((newIssuer ? newIssuer + ":" : "") + newName))
    newIssuer = ""; newName = ""; newSecret = ""; newTouch = false
  }

  // The code lands on the clipboard and in a notification; the panel only
  // reports that it is waiting, since a touch-protected account can sit here
  // for as long as it takes someone to reach the key.
  function generateCode(id) {
    run(["oath-code", id], root.t("busy.readingCode").arg(id))
  }

  function deleteAccount(id) {
    confirm.message = root.t("confirm.deleteAccount").arg(id)
    confirm.confirmText = root.t("confirm.delete")
    confirm.action = function() { root.run(["oath-delete", id], root.t("busy.deleting").arg(id)) }
    confirm.opened = true
  }

  // PIV and OpenPGP keys flattened into one list for the SSH section. Only the
  // public half is ever here — it is meant to be pasted into authorized_keys.
  readonly property var cardSshKeys: {
    var out = []
    var piv = (sshKeys && sshKeys.piv && sshKeys.piv.keys) ? sshKeys.piv.keys : []
    for (var i = 0; i < piv.length; i++)
      out.push({ id: "piv-" + piv[i].id, source: "PIV", title: piv[i].label,
                 detail: piv[i].type + "  " + piv[i].fingerprint, key: piv[i].key })
    var pgp = sshKeys ? sshKeys.openpgp : null
    if (pgp && pgp.present)
      out.push({ id: "openpgp-aut", source: "OpenPGP", title: root.t("ssh.openpgpSubkey"),
                 detail: (pgp.algorithm || "") + (pgp.fingerprint ? "  " + pgp.fingerprint : ""),
                 key: pgp.key || "" })
    return out
  }

  function copySshKey(id) {
    var k = null
    for (var i = 0; i < cardSshKeys.length; i++) if (cardSshKeys[i].id === id) k = cardSshKeys[i]
    if (!k) return
    if (!k.key) {
      errorText = root.t("error.noGpgPublic")
      return
    }
    // A public key in argv is harmless — it is the half meant to be shared.
    Quickshell.execDetached(["/bin/sh", "-c",
      "printf '%s\\n' \"$0\" | wl-copy && notify-send -a YubiKey \"$2\" \"$1\"",
      k.key, k.source + " · " + k.title, root.t("notify.sshCopied")])
  }

  function openProvider(id) {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].id === id) { openUrl(providers[i].url); return }
  }

  // ---- shared row ---------------------------------------------------------
  //
  // Almost every control on these pages is the same thing: an icon, a title, a
  // line of explanation, and some state on the right. Defining it once keeps
  // the three pages consistent and keeps the cursor plumbing in one place.
  component ActionRow: CursorSurface {
    id: rowRoot
    property string section: ""
    property string icon: ""
    property string title: ""
    property string description: ""
    property string trailing: ""
    property color trailingColor: root.dim
    property bool enabledLook: true
    signal activated()

    outline: true
    foreground: root.foreground
    accent: root.accent
    hasCursor: root.focusSection === rowRoot.section
    implicitHeight: rowBody.implicitHeight + Style.spacing.rowPaddingX * 2
    opacity: enabledLook ? 1.0 : 0.45

    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(rowRoot)

    HoverHandler { onHoveredChanged: if (hovered) root.focusSection = rowRoot.section }
    TapHandler {
      onTapped: {
        if (!rowRoot.enabledLook) return
        root.focusSection = rowRoot.section
        rowRoot.activated()
      }
    }

    Row {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      spacing: Style.space(12)

      Text {
        text: rowRoot.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        width: 22
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
        visible: rowRoot.icon.length > 0
      }

      Column {
        width: parent.width - (rowRoot.icon.length > 0 ? 34 : 0) - trailingText.width - Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          text: rowRoot.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          width: parent.width
          elide: Text.ElideRight
        }
        Text {
          text: rowRoot.description
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
          visible: rowRoot.description.length > 0
        }
      }

      Text {
        id: trailingText
        text: rowRoot.trailing
        color: rowRoot.trailingColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // A label/value line for the device facts, where the value is the point and
  // wrapping it would be worse than eliding it.
  component Fact: Row {
    property string label: ""
    property string value: ""
    spacing: Style.space(10)
    visible: value.length > 0

    Text {
      text: parent.label
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      width: 130
    }
    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ---- window -------------------------------------------------------------
  FloatingWindow {
    id: window
    title: "YubiKey"
    color: root.background
    implicitWidth: 660
    implicitHeight: 820
    minimumSize: Qt.size(520, 520)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: confirm.opened || issuerField.activeFocus || nameField.activeFocus || secretField.activeFocus
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveCursorH(dx)
        }
        onActivateRequested: root.activateCursor()
        onTabRequested: function(direction) { root.moveCursorH(direction) }
        onCloseRequested: root.requestClose()

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(18)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

          Column {
            width: scrollArea.availableWidth
            spacing: Style.space(18)

            // ---- header --------------------------------------------------
            Row {
              width: parent.width
              spacing: Style.space(14)

              Text {
                text: root.keyPresent ? "󰌆" : "󰌊"
                color: root.keyPresent ? root.accent : root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - 60 - langGroup.width - refreshButton.width - Style.space(42)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  text: root.device ? (root.device.name || "YubiKey") : "YubiKey"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  text: {
                    if (root.toolingMissing) return root.t("header.toolingMissing")
                    if (!root.keyPresent) return root.t("header.noKey")
                    var bits = []
                    if (root.device.serial) bits.push(root.t("header.serial").arg(root.device.serial))
                    if (root.device.version) bits.push(root.t("header.firmware").arg(root.device.version))
                    if (root.status.count > 1) bits.push(root.tn("header.keysConnected", root.status.count).arg(root.status.count))
                    return bits.join("  ·  ")
                  }
                  color: root.keyPresent ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              ButtonGroup {
                id: langGroup
                options: root.languages
                value: root.lang
                foreground: root.foreground
                background: root.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                spacing: Style.space(4)
                focusable: false
                cursorIndex: {
                  if (root.focusSection !== "lang") return -1
                  for (var i = 0; i < root.languages.length; i++) if (root.languages[i].value === root.lang) return i
                  return -1
                }
                anchors.verticalCenter: parent.verticalCenter
                onChanged: function(v) { root.focusSection = "lang"; root.setLang(v) }
                onHovered: function(index, isHovered) { if (isHovered) root.focusSection = "lang" }
              }

              Button {
                id: refreshButton
                text: root.t("header.refresh")
                iconText: "󰑙"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                hasCursor: root.focusSection === "refresh"
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(h) { if (h) root.focusSection = "refresh" }
                onClicked: { root.focusSection = "refresh"; root.reloadAll() }
              }
            }

            // ---- tabs ----------------------------------------------------
            ButtonGroup {
              width: parent.width
              options: root.tabs
              value: root.tab
              foreground: root.foreground
              background: root.background
              accent: root.accent
              fontFamily: root.fontFamily
              cursorIndex: -1
              onChanged: function(v) { root.focusSection = "tabs"; root.setTab(v) }
              onHovered: function(index, isHovered) { if (isHovered) root.focusSection = "tabs" }
            }

            // ---- messages ------------------------------------------------
            BorderSurface {
              width: parent.width
              visible: root.errorText.length > 0 || root.busyText.length > 0
              implicitHeight: msgCol.implicitHeight + Style.spacing.rowPaddingX * 2
              radius: Style.cornerRadius
              readonly property color tint: root.errorText.length > 0 ? root.urgent : root.accent
              color: Qt.rgba(tint.r, tint.g, tint.b, 0.10)
              borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, 0.45), 1)

              Column {
                id: msgCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(3)

                Text {
                  text: root.errorText.length > 0 ? root.t("msg.error") : root.t("msg.working")
                  color: root.errorText.length > 0 ? root.urgent : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  text: root.errorText.length > 0 ? root.errorText : root.busyText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ================================================== DEVICE ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "device"

              // Nothing plugged in, or nothing to read it with. Both are
              // ordinary states, not errors, so they get a plain explanation
              // rather than the red banner.
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: !root.keyPresent

                Text {
                  text: root.toolingMissing ? root.t("device.toolsMissingTitle") : root.t("device.noKeyTitle")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: root.toolingMissing
                    ? root.t("device.toolsMissingBody")
                    : root.t("device.noKeyBody")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              // ---- identity ----------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: root.t("device.thisKey"); foreground: root.foreground; fontFamily: root.fontFamily }

                BorderSurface {
                  width: parent.width
                  implicitHeight: factCol.implicitHeight + Style.spacing.rowPaddingX * 2
                  radius: Style.cornerRadius
                  color: Style.normalFill
                  borderSpec: Border.flat(Style.normalBorderColor, 1)

                  Column {
                    id: factCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(5)

                    Fact { label: root.t("fact.model");        value: root.device ? String(root.device.name || "") : "" }
                    Fact { label: root.t("fact.serial");       value: root.device ? String(root.device.serial || "") : "" }
                    Fact { label: root.t("fact.firmware");     value: root.device ? String(root.device.version || "") : "" }
                    Fact { label: root.t("fact.formFactor");  value: root.device ? String(root.device.formFactor || "") : "" }
                    Fact { label: root.t("fact.usb"); value: root.device ? String(root.device.interfaces || "") : "" }
                    Fact { label: "NFC";          value: root.device ? (root.device.nfc ? root.t("fact.enabled") : root.t("fact.notAvailable")) : "" }
                    Fact { label: "FIPS";         value: (root.device && root.device.fips) ? root.t("fact.yes") : "" }
                  }
                }
              }

              // ---- applets ------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: root.t("applets.title"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("applets.intro")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.applets
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "app:" + modelData.name
                    icon: {
                      switch (modelData.name) {
                        case "FIDO2": return "󰯄"
                        case "FIDO U2F": return "󰯄"
                        case "OATH": return "󰥔"
                        case "PIV": return "󰄀"
                        case "OpenPGP": return "󰌾"
                        case "Yubico OTP": return "󰌌"
                        default: return "󰘦"
                      }
                    }
                    title: modelData.name
                    description: {
                      switch (modelData.name) {
                        case "FIDO2": return root.t("applet.fido2")
                        case "FIDO U2F": return root.t("applet.u2f")
                        case "OATH": return root.t("applet.oath")
                        case "PIV": return root.t("applet.piv")
                        case "OpenPGP": return root.t("applet.openpgp")
                        case "YubiHSM Auth": return root.t("applet.hsm")
                        case "Yubico OTP": return root.t("applet.otp")
                        default: return ""
                      }
                    }
                    trailing: modelData.enabled ? root.t("state.enabled") : root.t("state.off")
                    trailingColor: modelData.enabled ? root.accent : root.dimmer
                    onActivated: root.toggleApplet(modelData.name)
                  }
                }
              }

              // ---- PINs ---------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: root.t("pins.title"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("pins.intro")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                ActionRow {
                  width: parent.width
                  section: "pin:fido2"
                  icon: "󰯄"
                  title: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set) ? root.t("pin.fido2Change") : root.t("pin.fido2Set")
                  description: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set)
                    ? root.t("pin.fido2SetDesc")
                    : root.t("pin.fido2UnsetDesc")
                  trailing: {
                    var f = root.status.pins ? root.status.pins.fido : null
                    if (!f) return ""
                    if (!f.set) return root.t("pin.notSet")
                    return f.retries ? root.tn("pin.triesLeft", f.retries).arg(f.retries) : root.t("pin.set")
                  }
                  trailingColor: (root.status.pins && root.status.pins.fido && root.status.pins.fido.set) ? root.dim : root.urgent
                  enabledLook: root.keyPresent
                  onActivated: root.runTerm(["pin", "fido2"])
                }

                ActionRow {
                  width: parent.width
                  section: "pin:piv"
                  icon: "󰄀"
                  title: root.t("pin.pivChange")
                  description: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    if (p && p.defaultPin)
                      return root.t("pin.pivDefault")
                    return root.t("pin.pivDesc")
                  }
                  trailing: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    return (p && p.retries) ? root.tn("pin.triesLeft", p.retries).arg(p.retries) : ""
                  }
                  enabledLook: !!(root.status.pins && root.status.pins.piv && root.status.pins.piv.present)
                  onActivated: root.runTerm(["pin", "piv"])
                }

                Text {
                  text: {
                    var p = root.status.pins ? root.status.pins.piv : null
                    if (!p) return ""
                    if (!p.defaultPuk && !p.defaultMgmt) return ""
                    if (p.defaultPuk && p.defaultMgmt) return root.t("pin.pivStaleBoth")
                    return root.t(p.defaultPuk ? "pin.pivStalePuk" : "pin.pivStaleMgmt")
                  }
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                  visible: text.length > 0
                }

                ActionRow {
                  width: parent.width
                  section: "pin:openpgp"
                  icon: "󰌾"
                  title: root.t("pin.openpgpChange")
                  description: root.t("pin.openpgpDesc")
                  trailing: {
                    var g = root.status.pins ? root.status.pins.openpgp : null
                    return (g && g.retries) ? root.tn("pin.triesLeft", g.retries).arg(g.retries) : ""
                  }
                  enabledLook: !!(root.status.pins && root.status.pins.openpgp && root.status.pins.openpgp.present)
                  onActivated: root.runTerm(["pin", "openpgp"])
                }
              }

              PanelSeparator { foreground: root.foreground; visible: root.keyPresent }

              // ---- resets --------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.keyPresent

                PanelSectionHeader { text: root.t("reset.title"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("reset.intro")
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Grid {
                  width: parent.width
                  columns: 2
                  spacing: Style.space(8)

                  Repeater {
                    model: [
                      { app: "fido2",   label: root.t("reset.fido2"),   note: root.t("reset.fido2.note") },
                      { app: "piv",     label: root.t("reset.piv"),     note: root.t("reset.piv.note") },
                      { app: "oath",    label: root.t("reset.oath"),    note: root.t("reset.oath.note") },
                      { app: "openpgp", label: root.t("reset.openpgp"), note: root.t("reset.openpgp.note") }
                    ]
                    delegate: ActionRow {
                      required property var modelData
                      width: (parent.width - Style.space(8)) / 2
                      section: "reset:" + modelData.app
                      icon: "󰦞"
                      title: modelData.label
                      description: modelData.note
                      trailingColor: root.urgent
                      onActivated: root.runTerm(["reset", modelData.app])
                    }
                  }
                }
              }
            }

            // ================================================== SYSTEM ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "system"

              // ---- PAM ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: root.t("pam.title"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("pam.intro").arg(root.pam.authfile)
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                ActionRow {
                  width: parent.width
                  section: "pam-register"
                  icon: "󰌆"
                  title: root.pam.registered ? root.t("pam.registerAnother") : root.t("pam.register")
                  description: root.pam.registered
                    ? root.t("pam.registerAnotherDesc")
                    : root.t("pam.registerDesc")
                  trailing: root.pam.keyCount > 0 ? root.tn("pam.registeredCount", root.pam.keyCount).arg(root.pam.keyCount) : root.t("pam.noneYet")
                  trailingColor: root.pam.registered ? root.accent : root.urgent
                  onActivated: root.runTerm(["pam-register"])
                }

                Repeater {
                  model: root.pam.services || []
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "pam:" + modelData.service
                    icon: {
                      switch (modelData.service) {
                        case "sudo": return "󰆍"
                        case "polkit": return "󰒘"
                        case "login": return "󰌾"
                        case "lock": return "󰍁"
                        default: return "󰘦"
                      }
                    }
                    title: {
                      switch (modelData.service) {
                        case "sudo": return "sudo"
                        case "polkit": return root.t("pam.polkit")
                        case "login": return root.t("pam.login")
                        case "lock": return root.t("pam.lock")
                        default: return modelData.service
                      }
                    }
                    description: {
                      switch (modelData.service) {
                        case "sudo": return root.t("pam.sudoDesc")
                        case "polkit": return root.t("pam.polkitDesc")
                        case "login": return root.t("pam.loginDesc")
                        case "lock": return root.t("pam.lockDesc")
                        default: return modelData.file
                      }
                    }
                    trailing: modelData.enabled ? root.t("state.on") : root.t("state.off")
                    trailingColor: modelData.enabled ? root.accent : root.dimmer
                    onActivated: root.togglePam(modelData.service)
                  }
                }
              }

              // ---- SSH ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: "SSH"; foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("ssh.intro")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Text {
                  text: root.t("common.onKey")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  topPadding: Style.space(4)
                }

                Text {
                  text: {
                    if (!root.keyPresent) return root.t("ssh.plugIn")
                    var parts = []
                    if (root.cardSshKeys.length === 0)
                      parts.push(root.sshKeys.piv && root.sshKeys.piv.readable
                        ? root.t("ssh.noCardKey")
                        : root.t("ssh.pivUnreadable"))
                    parts.push(root.t("ssh.residentNote"))
                    return parts.join(" ")
                  }
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.cardSshKeys
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "sshkey:" + modelData.id
                    icon: "󰌆"
                    title: modelData.source + " · " + modelData.title
                    description: modelData.detail
                    trailing: modelData.key ? root.t("ssh.copy") : root.t("ssh.noPublic")
                    trailingColor: modelData.key ? root.accent : root.dimmer
                    onActivated: root.copySshKey(modelData.id)
                  }
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-sk-list"
                  icon: "󰈙"
                  title: root.t("ssh.listResident")
                  description: root.t("ssh.listResidentDesc")
                  trailing: (root.sshKeys.fido && root.sshKeys.fido.residentSlotsRemaining !== null && root.sshKeys.fido.residentSlotsRemaining !== undefined)
                    ? root.tn("ssh.slotsFree", root.sshKeys.fido.residentSlotsRemaining).arg(root.sshKeys.fido.residentSlotsRemaining) : ""
                  enabledLook: root.keyPresent
                  onActivated: root.runTerm(["ssh-sk-list"])
                }

                Text {
                  text: root.t("ssh.addNew")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  topPadding: Style.space(4)
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-sk"
                  icon: "󰌘"
                  title: root.t("ssh.newResident")
                  description: root.t("ssh.newResidentDesc")
                  trailing: (root.ssh.skKeys && root.ssh.skKeys.length > 0) ? root.tn("ssh.onDisk", root.ssh.skKeys.length).arg(root.ssh.skKeys.length) : ""
                  onActivated: root.runTerm(["ssh-sk", "ed25519-sk", "resident"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-sk-plain"
                  icon: "󰌘"
                  title: root.t("ssh.newPlain")
                  description: root.t("ssh.newPlainDesc")
                  onActivated: root.runTerm(["ssh-sk", "ed25519-sk", "nonresident"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-recover"
                  icon: "󰃨"
                  title: root.t("ssh.recover")
                  description: root.t("ssh.recoverDesc")
                  onActivated: root.runTerm(["ssh-recover"])
                }

                ActionRow {
                  width: parent.width
                  section: "ssh-piv"
                  icon: "󰄀"
                  title: root.t("ssh.piv")
                  description: root.ssh.pkcs11Module.length > 0
                    ? root.t("ssh.pivDesc").arg(root.ssh.pkcs11Module)
                    : root.t("ssh.noModule")
                  trailing: root.ssh.pkcs11InSshConfig ? root.t("ssh.configured") : ""
                  trailingColor: root.accent
                  enabledLook: root.ssh.pkcs11Module.length > 0
                  onActivated: root.runTerm(["ssh-piv"])
                }

                ActionRow {
                  width: parent.width
                  section: "gpg-ssh"
                  icon: "󰌾"
                  title: root.t("ssh.gpg")
                  description: root.t("ssh.gpgDesc")
                  trailing: root.ssh.gpgSshEnabled ? root.t("state.on") : root.t("state.off")
                  trailingColor: root.ssh.gpgSshEnabled ? root.accent : root.dimmer
                  onActivated: root.run(["gpg-ssh", root.ssh.gpgSshEnabled ? "off" : "on"], root.t("busy.gpgSsh"))
                }
              }

              // ---- disk ---------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.luks.devices && root.luks.devices.length > 0

                PanelSectionHeader { text: root.t("luks.title"); foreground: root.foreground; fontFamily: root.fontFamily }

                ActionRow {
                  width: parent.width
                  section: "luks-enroll"
                  icon: "󰋊"
                  title: root.t("luks.enroll")
                  description: {
                    var d = (root.luks.devices && root.luks.devices.length > 0) ? root.luks.devices[0] : null
                    if (!d) return ""
                    return root.t("luks.desc").arg(d.device)
                  }
                  trailing: {
                    var d = (root.luks.devices && root.luks.devices.length > 0) ? root.luks.devices[0] : null
                    if (!d) return ""
                    return d.fido2Tokens > 0 ? root.t("luks.enrolled") : ""
                  }
                  trailingColor: root.accent
                  enabledLook: root.luks.hasCryptenroll
                  onActivated: root.runTerm(["luks-enroll"])
                }
              }

              PanelSeparator { foreground: root.foreground }

              ActionRow {
                width: parent.width
                section: "pam-forget"
                icon: "󰩹"
                title: root.t("forget.title")
                description: root.t("forget.desc")
                trailingColor: root.urgent
                onActivated: root.runTerm(["pam-forget"])
              }
            }

            // ================================================ ACCOUNTS ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "accounts"

              Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: root.t("accounts.title")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: root.t("accounts.intro")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              // ---- add ----------------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: root.t("oath.addTitle"); foreground: root.foreground; fontFamily: root.fontFamily }

                ActionRow {
                  width: parent.width
                  section: "oath-scan"
                  icon: "󰐮"
                  title: root.t("oath.scan")
                  description: root.t("oath.scanDesc")
                  enabledLook: !root.oath.locked
                  onActivated: root.runTerm(["oath-scan"])
                }

                Text {
                  text: root.t("oath.typeIt")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  TextField {
                    id: issuerField
                    width: (parent.width - Style.space(8)) * 0.4
                    placeholderText: root.t("oath.issuer")
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    text: root.newIssuer
                    hasCursor: root.focusSection === "oath-issuer"
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                    onTextChanged: root.newIssuer = text
                    onHoveredChanged: if (hovered) root.focusSection = "oath-issuer"
                  }
                  TextField {
                    id: nameField
                    width: (parent.width - Style.space(8)) * 0.6
                    placeholderText: root.t("oath.account")
                    foreground: root.foreground
                    accent: root.accent
                    font.family: root.fontFamily
                    text: root.newName
                    hasCursor: root.focusSection === "oath-name"
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                    onTextChanged: root.newName = text
                    onHoveredChanged: if (hovered) root.focusSection = "oath-name"
                  }
                }

                TextField {
                  id: secretField
                  width: parent.width
                  placeholderText: root.t("oath.secret")
                  password: true
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  text: root.newSecret
                  hasCursor: root.focusSection === "oath-secret"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onTextChanged: root.newSecret = text
                  onHoveredChanged: if (hovered) root.focusSection = "oath-secret"
                  onAccepted: root.submitAccount()
                }

                Toggle {
                  width: parent.width
                  label: root.t("oath.touch")
                  description: root.t("oath.touchDesc")
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  checked: root.newTouch
                  hasCursor: root.focusSection === "oath-touch"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onHovered: function(h) { if (h) root.focusSection = "oath-touch" }
                  onClicked: { root.focusSection = "oath-touch"; root.newTouch = !root.newTouch }
                }

                Button {
                  text: root.t("oath.add")
                  iconText: "󰐕"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  hasCursor: root.focusSection === "oath-add"
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onHovered: function(h) { if (h) root.focusSection = "oath-add" }
                  onClicked: { root.focusSection = "oath-add"; root.submitAccount() }
                }
              }

              // ---- stored accounts ----------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: root.t("common.onKey"); foreground: root.foreground; fontFamily: root.fontFamily }

                Text {
                  text: root.oath.locked
                    ? root.t("oath.locked")
                    : ((root.oath.accounts && root.oath.accounts.length > 0)
                        ? root.t("oath.pick")
                        : root.t("oath.none"))
                  color: root.oath.locked ? root.urgent : root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.oath.accounts || []
                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(8)

                    ActionRow {
                      width: parent.width - deleteButton.width - Style.space(8)
                      section: "oath:" + modelData.id
                      icon: "󰥔"
                      title: modelData.name
                      description: modelData.issuer.length > 0 ? modelData.issuer : ""
                      trailing: root.t("oath.copyCode")
                      onActivated: root.generateCode(modelData.id)
                    }

                    Button {
                      id: deleteButton
                      iconText: "󰩹"
                      bordered: true
                      foreground: root.urgent
                      accent: root.urgent
                      fontFamily: root.fontFamily
                      tooltipText: root.t("oath.deleteTip")
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.deleteAccount(modelData.id)
                    }
                  }
                }
              }

              // ---- providers ----------------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader { text: root.t("prov.title"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("prov.intro")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.providers
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "prov:" + modelData.id
                    icon: modelData.icon
                    title: modelData.name
                    description: root.t("provider." + modelData.id, modelData.note)
                    trailing: root.t("prov.open")
                    onActivated: root.openUrl(modelData.url)
                  }
                }
              }
            }

            // =================================================== SETUP ====
            Column {
              width: parent.width
              spacing: Style.space(20)
              visible: root.tab === "setup"

              // ---- security wizard ----------------------------------------
              Column {
                width: parent.width
                spacing: Style.space(10)

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  Column {
                    width: parent.width - wizRunButton.width - Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)

                    Text {
                      text: root.t("wiz.title")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                    }
                    Text {
                      text: root.t("wiz.progress")
                        .arg(root.wizardCount("essential", true)).arg(root.wizardCount("essential", false))
                        .arg(root.wizardCount("recommended", true)).arg(root.wizardCount("recommended", false))
                        .arg(root.wizardCount("optional", true)).arg(root.wizardCount("optional", false))
                      color: root.essentialsDone ? root.accent : root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      width: parent.width
                      wrapMode: Text.WordWrap
                    }
                  }

                  Button {
                    id: wizRunButton
                    text: root.checking ? root.t("wiz.checking") : root.t("wiz.run")
                    iconText: "󰄵"
                    bordered: true
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    hasCursor: root.focusSection === "wiz-run"
                    anchors.verticalCenter: parent.verticalCenter
                    onHovered: function(h) { if (h) root.focusSection = "wiz-run" }
                    onClicked: { root.focusSection = "wiz-run"; root.reloadAll() }
                  }
                }

                Text {
                  text: root.t("wiz.intro")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }

                // Progress across every step that applies.
                Rectangle {
                  width: parent.width
                  height: 6
                  radius: 3
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  Rectangle {
                    readonly property int total: root.wizardSteps.length
                    readonly property int done: {
                      var c = 0
                      for (var i = 0; i < root.wizardSteps.length; i++) if (root.wizardSteps[i].state === "ok") c++
                      return c
                    }
                    width: total > 0 ? parent.width * done / total : 0
                    height: parent.height
                    radius: parent.radius
                    color: root.essentialsDone ? root.accent : root.urgent
                    Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
                  }
                }

                // ---- current step --------------------------------------
                BorderSurface {
                  width: parent.width
                  implicitHeight: stepCol.implicitHeight + Style.spacing.rowPaddingX * 2
                  radius: Style.cornerRadius
                  readonly property var step: root.wizardCurrent
                  readonly property color tint: !step ? root.accent : root.wizardStateColor(step)
                  color: Qt.rgba(tint.r, tint.g, tint.b, 0.08)
                  borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, 0.45), 1)

                  Column {
                    id: stepCol
                    readonly property var step: parent.step
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(16)
                    anchors.rightMargin: Style.space(16)
                    spacing: Style.space(8)

                    Text {
                      text: stepCol.step
                        ? root.t("wiz.step").arg(root.wizardCurrentIndex + 1).arg(root.wizardSteps.length)
                          + "  ·  " + root.t("wiz." + stepCol.step.level) + "  ·  " + root.wizardStateLabel(stepCol.step)
                        : root.t("wiz.state.ok")
                      color: stepCol.step ? root.wizardStateColor(stepCol.step) : root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Text {
                      text: stepCol.step ? stepCol.step.icon + "  " + stepCol.step.title : "󰄬  " + root.t("wiz.allDoneTitle")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                      width: parent.width
                      wrapMode: Text.WordWrap
                    }
                    Text {
                      text: stepCol.step ? stepCol.step.why : root.t("wiz.allDoneBody")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      width: parent.width
                      wrapMode: Text.WordWrap
                    }
                    Text {
                      text: stepCol.step ? stepCol.step.detail : ""
                      visible: text.length > 0
                      color: root.wizardStateColor(stepCol.step || { state: "ok" })
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      width: parent.width
                      wrapMode: Text.WordWrap
                    }
                    Text {
                      text: root.t("wiz.terminalNote")
                      visible: !!stepCol.step && stepCol.step.kind === "term" && stepCol.step.state !== "ok" && stepCol.step.state !== "blocked"
                      color: root.dimmer
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      width: parent.width
                      wrapMode: Text.WordWrap
                    }

                    Row {
                      spacing: Style.space(8)
                      visible: !!stepCol.step
                      topPadding: Style.space(4)

                      Button {
                        text: stepCol.step ? stepCol.step.action : ""
                        iconText: "󰐊"
                        bordered: true
                        visible: !!stepCol.step && stepCol.step.state !== "ok"
                        opacity: stepCol.step && stepCol.step.state === "blocked" ? 0.45 : 1.0
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        hasCursor: root.focusSection === "wiz-do"
                        onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                        onHovered: function(h) { if (h) root.focusSection = "wiz-do" }
                        onClicked: { root.focusSection = "wiz-do"; root.runWizardStep(stepCol.step) }
                      }
                      Button {
                        text: stepCol.step && stepCol.step.skipped ? root.t("wiz.unskip") : root.t("wiz.skip")
                        iconText: "󰒭"
                        bordered: true
                        visible: !!stepCol.step && stepCol.step.state !== "ok"
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        hasCursor: root.focusSection === "wiz-skip"
                        onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                        onHovered: function(h) { if (h) root.focusSection = "wiz-skip" }
                        onClicked: { root.focusSection = "wiz-skip"; root.toggleSkip(stepCol.step.id) }
                      }
                    }
                  }
                }

                // ---- checklist ----------------------------------------
                Repeater {
                  model: root.wizardSteps
                  delegate: ActionRow {
                    required property var modelData
                    width: parent.width
                    section: "wiz-step:" + modelData.id
                    icon: root.wizardStateIcon(modelData)
                    title: modelData.title
                    description: modelData.detail
                    trailing: root.t("wiz." + modelData.level) + " · " + root.wizardStateLabel(modelData)
                    trailingColor: root.wizardStateColor(modelData)
                    enabledLook: !modelData.skipped
                    onActivated: root.selectStep(modelData.id)
                    // Skipped rows stay clickable so a skip can be undone.
                    TapHandler { enabled: modelData.skipped; onTapped: { root.focusSection = "wiz-step:" + modelData.id; root.selectStep(modelData.id) } }
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: root.deps.missing > 0
                    ? root.t("setup.missing").arg(root.deps.missing).arg(root.deps.deps ? root.deps.deps.length : 0)
                    : root.t("setup.allInstalled")
                  color: root.deps.missing > 0 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: root.t("setup.intro")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              ActionRow {
                width: parent.width
                section: "install-deps"
                icon: "󰏔"
                title: root.deps.missing > 0 ? root.t("setup.install") : root.t("setup.repair")
                description: root.t("setup.installDesc")
                trailing: root.deps.missing > 0 ? root.t("setup.missingCount").arg(root.deps.missing) : root.t("setup.allPresent")
                trailingColor: root.deps.missing > 0 ? root.urgent : root.accent
                onActivated: root.runTerm(["install-deps"])
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader { text: root.t("setup.packages"); foreground: root.foreground; fontFamily: root.fontFamily }

                Repeater {
                  model: root.deps.deps || []
                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(10)

                    Text {
                      text: modelData.present ? "󰄬" : "󰅖"
                      color: modelData.present ? root.accent : root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      width: 18
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Column {
                      width: parent.width - 28
                      spacing: Style.space(1)

                      Text {
                        text: modelData.pkg
                        color: modelData.present ? root.foreground : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        text: root.t("dep." + modelData.pkg, modelData.why)
                        color: root.dimmer
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              Column {
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader { text: root.t("setup.pcscd"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.deps.pcscdRunning
                    ? root.t("setup.pcscdOn")
                    : root.t("setup.pcscdOff")
                  color: root.deps.pcscdRunning ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader { text: root.t("setup.terminal"); foreground: root.foreground; fontFamily: root.fontFamily }
                Text {
                  text: root.t("setup.terminalDesc")
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  wrapMode: Text.WordWrap
                }
              }
            }

            // Bottom breathing room so the last row is not flush with the edge.
            Item { width: parent.width; height: Style.space(8) }
          }
        }
      }

      // ---- confirmation ----------------------------------------------------
      //
      // Only the two directions that destroy something reach this: switching an
      // applet off, and deleting a stored account. Everything more dangerous
      // than that is a terminal prompt instead.
      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        property var action: null
        cancelText: root.t("confirm.cancel")
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onConfirmed: {
          opened = false
          if (action) { action(); action = null }
        }
        onCanceled: { opened = false; action = null }
      }
    }
  }
}
