// HT07Menu — a macOS menu-bar controller for the QCY Arcbuds HT07, talking the
// QCY BLE house protocol directly (no QCY app). Reverse-engineered & verified in
// QCY-HT07-protocol-report.md. Control service 0xA001: write 0x1001 (no-resp),
// notify 0x1002, battery 0x0008, version 0x0007, key map 0x000D, EQ 0x000B.
// Frame: FF LEN <cmd> <len> <payload...>.  ANC byte = (scene<<4)|level.
//
// Build:  see build.sh  (swiftc + bundle; no Xcode project needed)

import SwiftUI
import CoreBluetooth
import ServiceManagement

// Start-at-login via the modern login-item API (macOS 13+). Registers the running
// app bundle itself, so it relaunches at login. Works best from /Applications.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("HT07Menu login item error: \(error.localizedDescription)") }
    }
}

// MARK: - Protocol constants
let SVC_CONTROL = CBUUID(string: "A001")
let CH_WRITE    = CBUUID(string: "1001")   // command, write-without-response
let CH_NOTIFY   = CBUUID(string: "1002")   // read/notify
let CH_BATT     = CBUUID(string: "0008")   // battery R/N  [L,R,box] low7=%, bit7=charging
let CH_VER      = CBUUID(string: "0007")   // version R
let CH_VER2     = CBUUID(string: "0009")   // model/serial R/W
let CH_KEY      = CBUUID(string: "000D")   // touch key map: raw [keyId,funId] pairs
let ADV_NAME    = "QCY-APP"

enum Cmd: UInt8 { case noiseMode = 0x0C, noiseLevel = 0x07, light = 0x05, game = 0x09,
                       balance = 0x16, request = 0xFE, multiEq = 0x20, keyFun = 0x2B }

// ANC scene hi-nibble
enum ANCScene: Int, CaseIterable, Identifiable {
    case indoor = 4, commuting = 5, noisy = 6, antiwind = 7
    var id: Int { rawValue }
    var name: String { ["Indoor","Commuting","Noisy","Anti-wind"][rawValue-4] }
    var maxLevel: Int { self == .antiwind ? 1 : 3 }
}

// Touch gestures (KEYID) and functions (FUNID) from the RE report.
let FUNIDS: [(Int,String)] = [(0,"None"),(1,"Play/Pause"),(2,"Previous"),(3,"Next"),
    (4,"Assistant"),(5,"Volume +"),(6,"Volume −"),(7,"Game mode"),(8,"Answer"),
    (9,"Reject"),(10,"Hold"),(11,"Redial")]
let KEYIDS: [(Int,String)] = [(1,"L single"),(2,"R single"),(3,"L double"),(4,"R double"),
    (5,"L triple"),(6,"R triple"),(7,"L ×4"),(8,"R ×4"),(9,"L long"),(10,"R long")]
func funName(_ v: Int) -> String { FUNIDS.first{ $0.0==v }?.1 ?? "fn\(v)" }
func keyName(_ v: Int) -> String { KEYIDS.first{ $0.0==v }?.1 ?? "key\(v)" }

// EQ "sound effect" presets — full cmd-0x20 frames captured from the QCY app
// (byte[4] = preset id: 01 Default, 02 Pop, 03 HeavyBass, 04 Rock, 05 Soft, 06 Classic).
let EQ_PRESETS: [(String, String)] = [
    ("Default",    "FF7D207B0100001400D4FE6400D200E0FC4600C409F40150008813D4FEC800581B5802C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
    ("Pop",        "FF7D207B020000230044FD3200D20018FC3C00C409F40150008813D4FEC800581B5802C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
    ("Heavy Bass", "FF7D207B03000023002C013200D2000CFE4600C40964005000881344FDC800581BC800C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
    ("Rock",       "FF7D207B040CFE23002C013200D20018FC7800C409BC02500088139CFFC800581B2003C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
    ("Soft",       "FF7D207B050000230044FD3200D20044FD3C00C4092C0150008813A8FDC800581B2C01C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
    ("Classic",    "FF7D207B06000023002C013200D200D4FE7800C409F40150008813D4FEC800581B5802C800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
]

extension Data { var hexs: String { map { String(format:"%02X",$0) }.joined() } }
func hexToBytes(_ s: String) -> [UInt8]? {
    let c = s.filter { $0.isHexDigit }; guard c.count % 2 == 0, !c.isEmpty else { return nil }
    var out=[UInt8](); var i=c.startIndex
    while i<c.endIndex { let j=c.index(i,offsetBy:2); guard let b=UInt8(c[i..<j],radix:16) else {return nil}; out.append(b); i=j }
    return out
}

// MARK: - BLE manager
final class BLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Starting…"
    @Published var connected = false
    @Published var pinned = false        // "Stay connected": hold the BLE link even when the panel is closed
    @Published var battL = -1
    @Published var battR = -1
    @Published var battBox = -1
    @Published var chgL = false
    @Published var chgR = false
    @Published var chgBox = false
    @Published var mode = "—"            // Off / ANC / Transparency / unknown
    @Published var ancScene: ANCScene = .noisy
    @Published var ancLevel = 3
    @Published var transLevel = 4
    @Published var version = "—"
    @Published var keyMap: [(Int,Int)] = []
    @Published var eqHex = "—"
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var dev: CBPeripheral?
    private var writeCh: CBCharacteristic?
    private var wantAutoConnect = true
    private var closeWork: DispatchWorkItem?

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }

    func note(_ s: String) { log.insert("\(ts()) \(s)", at: 0); if log.count>120 { log.removeLast() } }
    private func ts() -> String { let f=DateFormatter(); f.dateFormat="HH:mm:ss"; return f.string(from:Date()) }

    // ---- lifecycle ----
    func rescan() {
        guard central.state == .poweredOn else { status="Bluetooth off"; return }
        if let d = dev { central.cancelPeripheralConnection(d); dev=nil }
        wantAutoConnect = true
        connected = false; writeCh = nil
        status = "Scanning for \(ADV_NAME)…"
        central.scanForPeripherals(withServices: nil)
    }
    func disconnect() {
        pinned = false; wantAutoConnect = false
        closeWork?.cancel(); closeWork = nil
        if let d = dev { central.cancelPeripheralConnection(d) }
        central.stopScan()
        status = "Disconnected — free for phone"; connected = false
    }

    // Open the BLE link while the panel is visible; release it shortly after it
    // closes (unless pinned). Holding the link continuously interferes with the
    // buds' TWS role-switch when one is docked, so on-demand is the default.
    func openSession() {
        closeWork?.cancel(); closeWork = nil
        wantAutoConnect = true
        guard central.state == .poweredOn else { return }
        if !connected { rescan() }
    }
    func scheduleClose() {
        guard !pinned else { return }
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pauseLink() }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }
    private func pauseLink() {
        wantAutoConnect = false
        central.stopScan()
        if let d = dev { central.cancelPeripheralConnection(d) }
        connected = false
        status = "Idle — open to control"
    }
    func setPinned(_ on: Bool) { pinned = on; if on { openSession() } else { scheduleClose() } }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: rescan()
        case .unauthorized: status = "Bluetooth not allowed — enable in System Settings ▸ Privacy ▸ Bluetooth"
        case .poweredOff: status = "Bluetooth is OFF"
        default: status = "Bluetooth state \(c.state.rawValue)"
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String:Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mfg = (ad[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexs.uppercased() ?? ""
        // Match by advertised name, or by the QCY/Realtek manufacturer signature.
        guard name.uppercased().contains("QCY") || mfg.hasPrefix("1C524D43") else { return }
        c.stopScan()
        dev = p; p.delegate = self
        status = "Connecting to \(name.isEmpty ? "HT07" : name)…"
        note("found \(name.isEmpty ? "(no name)" : name) rssi=\(rssi)")
        c.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering…"; p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connect failed"; note("connect failed: \(error?.localizedDescription ?? "?")")
        if wantAutoConnect { rescan() }
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false; writeCh = nil
        if wantAutoConnect { status = "Reconnecting…"; rescan() } else { status = "Disconnected" }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let isControl = (s.characteristics ?? []).contains { $0.uuid == CH_BATT }
        for ch in s.characteristics ?? [] {
            if ch.uuid == CH_WRITE && isControl { writeCh = ch }
            if ch.uuid == CH_NOTIFY { p.setNotifyValue(true, for: ch) }
            if ch.uuid == CH_BATT   { p.setNotifyValue(true, for: ch); p.readValue(for: ch) }
            if ch.uuid == CH_VER || ch.uuid == CH_VER2 || ch.uuid == CH_KEY { p.readValue(for: ch) }
        }
        if writeCh != nil && !connected {
            connected = true; status = "Connected"
            note("connected; control ready")
            // pull current state
            request(.noiseMode); request(.balance)
        }
    }

    // ---- send helpers ----
    private func frame(_ inner: [UInt8]) -> Data { Data([0xFF, UInt8(inner.count)] + inner) }
    private func inner(_ cmd: Cmd, _ data: [UInt8]) -> [UInt8] { [cmd.rawValue, UInt8(data.count)] + data }
    private func send(_ cmd: Cmd, _ data: [UInt8]) {
        guard let p = dev, let w = writeCh else { note("not connected"); return }
        let f = frame(inner(cmd, data))
        p.writeValue(f, for: w, type: .withoutResponse)
        note("» \(f.hexs)")
    }
    func sendRaw(_ hex: String) {
        guard let p = dev, let w = writeCh, let b = hexToBytes(hex) else { note("bad hex / not connected"); return }
        let maxLen = p.maximumWriteValueLength(for: .withoutResponse)
        if b.count > maxLen { note("⚠︎ \(b.count)B > MTU max \(maxLen)B — may be truncated") }
        p.writeValue(Data(b), for: w, type: .withoutResponse); note("» \(Data(b).hexs) (raw)")
    }
    func request(_ what: Cmd) { send(.request, [what.rawValue]) }
    func requestRaw(_ id: UInt8) { send(.request, [id]) }

    // ---- feature commands ----
    func setOff()                 { send(.noiseMode, [0x02]); mode="Off" }
    func setANC(_ s: ANCScene, _ lvl: Int) { let l=max(1,min(s.maxLevel,lvl)); send(.noiseMode, [UInt8((s.rawValue<<4)|l)]); mode="ANC"; ancScene=s; ancLevel=l }
    func setTransparency(_ lvl: Int)    { let l=max(1,min(6,lvl)); send(.noiseMode, [UInt8(0xA0 | l)]); mode="Transparency"; transLevel=l }
    func ring(_ on: Bool)         { send(.light, [on ? 1 : 0]) }
    func game(_ on: Bool)         { send(.game, [on ? 1 : 0]) }
    func setBalance(_ v: Int)     { send(.balance, [UInt8(max(0,min(100,v)))]) }
    func setKey(_ key: Int, _ fun: Int) { // HT07 writes the key map as raw [keyId,funId] on char 0x000D (no framing)
        guard let p = dev else { return }
        // find key char
        for s in p.services ?? [] { for ch in s.characteristics ?? [] where ch.uuid == CH_KEY {
            p.writeValue(Data([UInt8(key),UInt8(fun)]), for: ch, type: .withoutResponse)
            note("» key \(keyName(key)) → \(funName(fun)) on 000D"); p.readValue(for: ch); return } }
    }
    func readEQ() { request(.multiEq) }

    // ---- incoming ----
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let b = [UInt8](d)
        switch ch.uuid {
        case CH_BATT:
            if b.count >= 3 {
                // byte = bit7 charging | low7 percent. A "0% while charging" frame is a
                // placeholder the buds emit when just docked — keep the last known value.
                chgL = b[0] & 0x80 != 0; let pL = Int(b[0] & 0x7F); if !(pL == 0 && chgL && battL > 0) { battL = pL }
                chgR = b[1] & 0x80 != 0; let pR = Int(b[1] & 0x7F); if !(pR == 0 && chgR && battR > 0) { battR = pR }
                chgBox = b[2] & 0x80 != 0; let pB = Int(b[2] & 0x7F); if !(pB == 0 && chgBox && battBox > 0) { battBox = pB }
            }
        case CH_VER, CH_VER2:
            let s = String(bytes: b.prefix(while: { $0 != 0 && $0 >= 0x20 }), encoding: .utf8) ?? d.hexs
            if ch.uuid == CH_VER { version = s }
        case CH_KEY:
            var m=[(Int,Int)](); var i=0; while i+1 < b.count { if b[i] != 0 { m.append((Int(b[i]),Int(b[i+1]))) }; i+=2 }
            keyMap = m
        case CH_NOTIFY:
            note("« \(d.hexs)")
            parseFrame(b)
        default: break
        }
    }

    private func parseFrame(_ b: [UInt8]) {
        guard b.count >= 4, b[0]==0xFF, Int(b[1])+2==b.count else { return }
        var i = 2
        while i+1 < b.count {
            let cmd = b[i]; let len = Int(b[i+1]); i += 2
            let payload = Array(b[i..<min(b.count, i+len)]); i += len
            switch cmd {
            case 0x0C, 0x07:
                if let v = payload.first { applyNoiseByte(v) }
            default: break
            }
        }
    }
    private func applyNoiseByte(_ v: UInt8) {
        if v == 0x02 { mode = "Off"; return }
        let hi = Int(v >> 4), lo = Int(v & 0x0F)
        if (4...7).contains(hi) { mode = "ANC"; ancScene = ANCScene(rawValue: hi) ?? .noisy; ancLevel = max(1,lo) }
        else if hi == 0xA { mode = "Transparency"; transLevel = lo }
        else { mode = "mode 0x\(String(v,radix:16))" }
    }
}

// MARK: - UI
struct Row<V: View>: View { let label: String; let content: V
    init(_ l: String, @ViewBuilder _ c: ()->V){label=l;content=c()}
    var body: some View { HStack { Text(label).frame(width:92,alignment:.leading).foregroundStyle(.secondary); content; Spacer() } }
}

struct ContentView: View {
    @ObservedObject var ble: BLE
    @State private var balance = 50.0
    @State private var rawHex = "FF030C0163"
    @State private var selKey = 1
    @State private var selFun = 1
    @State private var showLog = false
    @State private var eqSel = 0

    func batt(_ v:Int,_ chg:Bool)->String { v<0 ? "—" : "\(v)%\(chg ? " ⚡︎" : "")" }

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).padding(.top, 2)
    }
    private var modeBinding: Binding<String> {
        Binding(get: { ["Off","ANC","Transparency"].contains(ble.mode) ? ble.mode : "Off" },
                set: { m in switch m { case "ANC": ble.setANC(ble.ancScene, ble.ancLevel)
                                       case "Transparency": ble.setTransparency(ble.transLevel)
                                       default: ble.setOff() } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack(spacing: 10) {
                Image(systemName: ble.connected ? "headphones" : "headphones.slash")
                    .font(.title3).foregroundStyle(ble.connected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("QCY HT07").font(.headline)
                    Text(ble.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if ble.connected { Button("Disconnect") { ble.disconnect() } }
                else { Button("Scan") { ble.rescan() }.buttonStyle(.borderedProminent) }
            }

            Toggle(isOn: Binding(get: { ble.pinned }, set: { ble.setPinned($0) })) {
                Text("Stay connected (may disrupt earbud case‑swaps)").font(.caption).foregroundStyle(.secondary)
            }.toggleStyle(.checkbox)

            // Battery (case % isn't obtainable over BLE — the buds only report it
            // while docked, which drops the link — so only L/R are shown)
            HStack(spacing: 18) {
                batteryPill("Left", ble.battL, ble.chgL)
                batteryPill("Right", ble.battR, ble.chgR)
            }

            Divider()

            // Noise control
            Group {
                header("Noise control")
                Picker("", selection: modeBinding) {
                    Text("Off").tag("Off"); Text("ANC").tag("ANC"); Text("Transparency").tag("Transparency")
                }.pickerStyle(.segmented).labelsHidden()

                if ble.mode == "ANC" {
                    Picker("", selection: Binding(get: { ble.ancScene }, set: { ble.setANC($0, ble.ancLevel) })) {
                        ForEach(ANCScene.allCases) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    HStack {
                        Text("Level").foregroundStyle(.secondary)
                        Stepper("\(ble.ancLevel) / \(ble.ancScene.maxLevel)",
                                value: Binding(get: { ble.ancLevel }, set: { ble.setANC(ble.ancScene, $0) }),
                                in: 1...ble.ancScene.maxLevel)
                    }
                } else if ble.mode == "Transparency" {
                    HStack {
                        Text("Level").foregroundStyle(.secondary)
                        Stepper("\(ble.transLevel) / 6",
                                value: Binding(get: { ble.transLevel }, set: { ble.setTransparency($0) }), in: 1...6)
                    }
                }
            }.disabled(!ble.connected)

            Divider()

            // Quick actions
            Group {
                header("Quick")
                HStack {
                    Button { ble.game(true) } label: { Label("Game on", systemImage: "gamecontroller.fill") }
                    Button { ble.game(false) } label: { Label("Game off", systemImage: "gamecontroller") }
                    // Note: find-my-earbud ("Ring") goes over the Classic SPP channel on
                    // this Realtek-based model, not BLE — it can't be sent from here.
                }
                HStack {
                    Text("Balance").foregroundStyle(.secondary)
                    Text("L").font(.caption)
                    Slider(value: $balance, in: 0...100, step: 1)
                        .onChange(of: balance) { _, v in ble.setBalance(Int(v)) }
                    Text("R").font(.caption)
                    Text("\(Int(balance))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }.disabled(!ble.connected)

            Divider()

            // Equalizer
            Group {
                header("Equalizer")
                Picker("", selection: $eqSel) {
                    ForEach(0..<EQ_PRESETS.count, id: \.self) { Text(EQ_PRESETS[$0].0).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
                    .onChange(of: eqSel) { _, i in ble.sendRaw(EQ_PRESETS[i].1) }
            }.disabled(!ble.connected)

            Divider()

            // Touch gestures
            DisclosureGroup("Touch gestures") {
                VStack(alignment: .leading, spacing: 6) {
                    if ble.keyMap.isEmpty { Text("(reading…)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(ble.keyMap, id: \.0) { pair in
                        Text("• \(keyName(pair.0)) → \(funName(pair.1))").font(.caption)
                    }
                    HStack {
                        Picker("", selection: $selKey) { ForEach(KEYIDS, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 110)
                        Image(systemName: "arrow.right").font(.caption2)
                        Picker("", selection: $selFun) { ForEach(FUNIDS, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 120)
                        Button("Set") { ble.setKey(selKey, selFun) }
                    }.disabled(!ble.connected)
                }.padding(.top, 4)
            }

            // EQ + advanced
            DisclosureGroup("EQ & advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Button("Read EQ") { ble.readEQ() }; Text("custom bands not exposed; presets above work").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        TextField("raw hex frame", text: $rawHex).textFieldStyle(.roundedBorder)
                        Button("Send") { ble.sendRaw(rawHex) }.disabled(!ble.connected)
                    }
                    Text("Firmware: \(ble.version)").font(.caption).foregroundStyle(.secondary)
                    Toggle("Show log", isOn: $showLog)
                    if showLog {
                        ScrollView { VStack(alignment: .leading, spacing: 1) {
                            ForEach(ble.log.indices, id: \.self) { Text(ble.log[$0]).font(.system(size: 10, design: .monospaced)) }
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
                    }
                }.padding(.top, 4)
            }

            Divider()
            HStack {
                Toggle("Start at login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.set($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 380)
        .onAppear { ble.openSession() }
        .onDisappear { ble.scheduleClose() }
    }

    private func batteryPill(_ label: String, _ v: Int, _ chg: Bool) -> some View {
        // v<0 unknown ("—"); v==0 ⇒ docked/charging → green bolt only; v>0 ⇒ "%" (+ bolt if charging).
        let charging = chg || v == 0
        let text: String = v < 0 ? "—" : (v == 0 ? "" : "\(v)%")
        return VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                if !text.isEmpty { Text(text).font(.system(.body, design: .rounded)).fontWeight(.medium) }
                if charging && v >= 0 { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
            }
        }
    }
}

@main
struct HT07MenuApp: App {
    @StateObject var ble = BLE()
    var body: some Scene {
        MenuBarExtra("HT07", systemImage: ble.connected ? "headphones" : "headphones.slash") {
            ContentView(ble: ble)
        }
        .menuBarExtraStyle(.window)
    }
}
