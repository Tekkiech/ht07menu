// HT07 CoreBluetooth probe. Scans, enumerates BLE peripherals, then (since the
// buds advertise no name) connects to nearby non-Apple peripherals and checks
// which exposes the QCY control characteristic 0x1001. On the match: dumps the
// GATT table, reads battery, listens for notifications, and optionally writes
// ONE control frame.
//
//   swiftc ht07probe.swift -o ht07probe -framework CoreBluetooth -framework Foundation
//   (run the .app bundle via: open -W ht07probe.app --args <logfile> [hexCmd])
//
// Frames (from the RE report): write 0x1001, notify 0x1002, battery 0x0008.
// ANC: FF 03 0C 01 <scene<<4|level>  (02=off, 63=ANC Noisy L3, A4=Transparency L4).

import Foundation
import CoreBluetooth

let WRITE_UUID = "1001", NOTIFY_UUID = "1002", BATT_UUID = "0008"

func shortUUID(_ u: CBUUID) -> String {
    let s = u.uuidString.uppercased()
    if s.count == 4 { return s }
    if s.hasPrefix("0000") && s.hasSuffix("-0000-1000-8000-00805F9B34FB") { return String(s.dropFirst(4).prefix(4)) }
    return s
}
extension Data { var hex: String { map { String(format: "%02X", $0) }.joined() } }
func hexToData(_ s: String) -> Data? {
    let c = s.filter { $0.isHexDigit }; guard c.count % 2 == 0, !c.isEmpty else { return nil }
    var d = Data(); var i = c.startIndex
    while i < c.endIndex { let j = c.index(i, offsetBy: 2); guard let b = UInt8(c[i..<j], radix: 16) else { return nil }; d.append(b); i = j }
    return d
}
var gLogFH: FileHandle?
func glog(_ s: String) { print(s); fflush(stdout); if let fh = gLogFH, let d = (s + "\n").data(using: .utf8) { fh.write(d) } }

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    let cmd: String?
    struct Cand { let p: CBPeripheral; let rssi: Int; let mfg: String; let name: String }
    var seen = Set<UUID>()
    var cands: [Cand] = []
    var scanning = true
    var queue: [Cand] = []
    var current: CBPeripheral?
    var found1001 = false
    var writeChar: CBCharacteristic?
    var pendingSvcs = 0
    var watchdog: DispatchWorkItem?

    init(cmd: String?) { self.cmd = cmd; super.init(); central = CBCentralManager(delegate: self, queue: nil) }
    func log(_ s: String) { glog(s) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            log("[*] Bluetooth on. Scanning 8s and enumerating…")
            c.scanForPeripherals(withServices: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.endScan() }
        case .unauthorized: log("[!] Bluetooth unauthorized."); exit(4)
        case .poweredOff:   log("[!] Bluetooth is OFF."); exit(3)
        default:            log("[*] central state = \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        var mfg = ""; if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data { mfg = m.hex }
        guard !seen.contains(p.identifier) else { return }
        seen.insert(p.identifier)
        var svcs = ""; if let u = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { svcs = u.map { shortUUID($0) }.joined(separator: ",") }
        log(String(format: "    · RSSI %4d  %-20@  svcs=[%@]  mfg=%@", RSSI.intValue, (name.isEmpty ? "(no name)" : name) as NSString, svcs, mfg.isEmpty ? "-" : mfg))
        cands.append(Cand(p: p, rssi: RSSI.intValue, mfg: mfg, name: name))
    }

    func endScan() {
        guard scanning else { return }
        scanning = false; central.stopScan()
        // Prefer a name match if any; else probe non-Apple peripherals, closest first.
        if let m = cands.first(where: { $0.name.uppercased().contains("QCY") || $0.name.uppercased().contains("ARCBUDS") }) {
            queue = [m]
        } else {
            queue = cands.filter { !$0.mfg.uppercased().hasPrefix("4C00") && $0.rssi >= -75 }.sorted { $0.rssi > $1.rssi }
        }
        log("[*] Scan done. Probing \(queue.count) candidate(s) for char 0x\(WRITE_UUID) (closest first)…")
        tryNext()
    }

    func tryNext() {
        guard !queue.isEmpty else {
            log("[!] No nearby peripheral exposed char 0x\(WRITE_UUID). The buds likely don't accept a BLE control link from the Mac right now.")
            log("    Try: disconnect the buds from BOTH the phone and the Mac (Bluetooth menu ▸ Disconnect), keep them awake out of the case, then re-run.")
            exit(2)
        }
        let c = queue.removeFirst()
        current = c.p; c.p.delegate = self; found1001 = false; writeChar = nil; pendingSvcs = 0
        log("[>] Connecting to RSSI \(c.rssi) \(c.name.isEmpty ? "(no name)" : c.name) \(c.mfg.isEmpty ? "" : "mfg=\(c.mfg.prefix(8))")…")
        let wd = DispatchWorkItem { [weak self] in
            guard let self = self, let p = self.current else { return }
            self.log("   [timeout] gave up on this one")
            self.central.cancelPeripheralConnection(p); self.current = nil; self.tryNext()
        }
        watchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: wd)
        central.connect(c.p, options: nil)
    }
    func advance() { watchdog?.cancel(); if let p = current { central.cancelPeripheralConnection(p) }; current = nil; tryNext() }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { log("   connected; discovering services…"); p.discoverServices(nil) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { log("   connect failed: \(error?.localizedDescription ?? "?")"); advance() }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {}

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services, !s.isEmpty else { advance(); return }
        pendingSvcs = s.count
        for svc in s { p.discoverCharacteristics(nil, for: svc) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where shortUUID(ch.uuid) == WRITE_UUID { found1001 = true; writeChar = ch }
        pendingSvcs -= 1
        if pendingSvcs <= 0 { finishPeripheral(p) }
    }

    func finishPeripheral(_ p: CBPeripheral) {
        if !found1001 { log("   (no 0x\(WRITE_UUID) here)"); advance(); return }
        watchdog?.cancel()
        log("[+] MATCH — HT07 control service found. id=\(p.identifier.uuidString)")
        log("[*] GATT table:")
        // Pin the command write to the CONTROL service: the one that also has battery 0008.
        writeChar = nil
        for svc in p.services ?? [] {
            log("  service \(shortUUID(svc.uuid))  (\(svc.uuid.uuidString))")
            let chars = svc.characteristics ?? []
            let isControl = chars.contains { shortUUID($0.uuid) == BATT_UUID }
            for ch in chars {
                log("      char \(shortUUID(ch.uuid))  [\(props(ch.properties))]\(isControl && shortUUID(ch.uuid) == WRITE_UUID ? "  ← control write" : "")")
                switch shortUUID(ch.uuid) {
                case NOTIFY_UUID: p.setNotifyValue(true, for: ch)
                case BATT_UUID:   p.readValue(for: ch)
                case WRITE_UUID:  if isControl { writeChar = ch }
                default: break
                }
            }
        }
        if let hex = cmd, let wc = writeChar, let d = hexToData(hex) {
            let t: CBCharacteristicWriteType = wc.properties.contains(.write) ? .withResponse : .withoutResponse
            log("[>] Writing \(hex) → 0x\(WRITE_UUID) (\(t == .withResponse ? "with response" : "no response"))")
            p.writeValue(d, for: wc, type: t)
        } else { log("[*] read-only — no command sent. Listening 8s for notifications…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            self.log("[*] Done. Direct-connect id for future runs: \(p.identifier.uuidString)"); exit(0)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("[!] read/notify err \(shortUUID(ch.uuid)): \(e.localizedDescription)"); return }
        if let d = ch.value { log("[<] \(shortUUID(ch.uuid)) = \(d.hex)") }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) { log("[=] write ack \(shortUUID(ch.uuid)): \(error?.localizedDescription ?? "OK")") }

    func props(_ p: CBCharacteristicProperties) -> String {
        var a = [String](); if p.contains(.read) { a.append("R") }; if p.contains(.write) { a.append("W") }
        if p.contains(.writeWithoutResponse) { a.append("Wnr") }; if p.contains(.notify) { a.append("N") }; if p.contains(.indicate) { a.append("Ind") }
        return a.joined(separator: ",")
    }
}

setbuf(stdout, nil)
var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, first.hasPrefix("/") {
    FileManager.default.createFile(atPath: first, contents: nil)
    gLogFH = FileHandle(forWritingAtPath: first)
    args.removeFirst()
}
let cmdArg = args.first
glog("[*] ht07probe start (cmd=\(cmdArg ?? "none"))")
let probe = Probe(cmd: cmdArg)
_ = probe
dispatchMain()
