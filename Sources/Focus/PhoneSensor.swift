import CoreBluetooth
import FocusCore
import Foundation

/// Whether the iPhone on the desk is in use, read from the Apple "Nearby Info" Bluetooth advert every iPhone broadcasts.
/// Undocumented but stable for years; see research/11-iphone-ble.md. Sees the phone even where the camera can't.
final class PhoneSensor: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    /// Activity codes for recent interaction, call, and the one seen while scrolling or watching video.
    /// Left out: 7 (screen on, also lit by notifications and StandBy) and 9 (Macs and Apple TVs nearby report it all day).
    private static let active: Set<UInt8> = [11, 14, 15]
    /// In hand or on the desk; measured -35…-60 dBm at the desk, other devices nearby -60 and below.
    private static let nearby = -62.0
    private let queue = DispatchQueue(label: "focus.phone")
    private let lock = NSLock()   // guards seen and mine
    private var seen: [UUID: (rssi: Double, active: Bool, at: Double)] = [:]
    private var mine: UUID?
    private var central: CBCentralManager?   // queue
    private var asker: CBCentralManager?   // queue
    private var scanning = false   // queue
    private var finding: (@Sendable ((id: UUID, name: String)?) -> Void)?   // queue
    private var findGeneration = 0   // queue

    static var authorized: Bool { CBCentralManager.authorization == .allowedAlways }
    static var undetermined: Bool { CBCentralManager.authorization == .notDetermined }

    /// The owner's iPhone. macOS keeps one identifier for one's own devices: it stayed the same for 41 minutes across five processes, while other devices' identifiers rotated.
    func remember(_ id: UUID?) { lock.withLock { mine = id } }

    /// The owner's iPhone, or any nearby one until it is found, reported active use in the last 6 s (one scan gap plus margin).
    /// Not heard for 10 min (left in another room, or its identifier changed), any nearby iPhone counts again.
    var inUse: Bool {
        let now = monotonic()
        return lock.withLock {
            let only = mine.flatMap { id in seen[id].flatMap { now - $0.at < 600 ? id : nil } }
            return seen.contains { (id, s) in (only == nil || id == only) && s.active && s.rssi >= Self.nearby && now - s.at < 6 }
        }
    }

    func start() { queue.async { self.setUp() } }
    func stop() { queue.async { self.central?.stopScan(); self.central = nil; self.scanning = false; self.lock.withLock { self.seen = [:] } } }
    /// Shows the Bluetooth permission prompt without scanning.
    func ask() { queue.async { self.asker = CBCentralManager(delegate: nil, queue: self.queue) } }

    /// Called every second. A scan costs ~0.4% CPU, so it runs only once the Mac has been idle 5 s (the phone rule needs 10 s),
    /// and then 2 s on, 2 s off; an iPhone in use advertises several times a second.
    func update(idle: Double) {
        let on = idle >= 5 && Int(monotonic() / 2) % 2 == 0
        queue.async {
            guard on != self.scanning else { return }
            self.scanning = on
            self.apply()
        }
    }

    /// Looks for 30 s for a device in use right next to the Mac (the owner unlocks the iPhone and holds it there).
    func find(_ done: @escaping @Sendable ((id: UUID, name: String)?) -> Void) {
        queue.async {
            self.findGeneration += 1
            let generation = self.findGeneration
            self.finding = done
            self.setUp()
            self.apply()
            // A timer from an earlier find() must not end this search.
            self.queue.asyncAfter(deadline: .now() + 30) { if self.findGeneration == generation { self.found(nil) } }
        }
    }

    private func found(_ phone: (id: UUID, name: String)?) {   // queue
        guard let done = finding else { return }
        finding = nil
        apply()
        done(phone)
    }

    private func setUp() {   // queue
        if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
    }

    private func apply() {   // queue
        guard let c = central, c.state == .poweredOn else { return }
        if scanning || finding != nil { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) } else { c.stopScan() }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) { apply() }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        // Apple manufacturer data is 4C 00 then type-length-value messages; in Nearby Info (0x10) the first byte's low nibble is the activity code.
        guard let data = ad[CBAdvertisementDataManufacturerDataKey] as? Data, rssi.intValue < 0 else { return }
        let m = [UInt8](data)
        guard m.count > 4, m[0] == 0x4C, m[1] == 0 else { return }
        var i = 2
        while i + 2 < m.count {
            if m[i] == 0x10, m[i + 1] >= 1 {
                let level = rssi.doubleValue, now = monotonic(), active = Self.active.contains(m[i + 2] & 0x0F)
                // In hand next to the Mac reads -29…-45 dBm; the next-strongest device nearby was -55.
                if active, level >= -50 { found((p.identifier, p.name ?? "iPhone")) }
                lock.withLock {
                    // Single adverts swing by ±10 dB; identifiers rotate every ~15 min, except one's own devices, so old ones are dropped.
                    seen[p.identifier] = ((seen[p.identifier]?.rssi ?? level) * 0.7 + level * 0.3, active, now)
                    if seen.count > 16 { seen = seen.filter { now - $0.value.at < 60 || $0.key == mine } }
                }
                return
            }
            i += 2 + Int(m[i + 1])
        }
    }
}
