import Darwin
import FocusCore
import Foundation

/// `Focus --probe`: live sensor readout plus own CPU% and memory footprint, for tuning and budget checks.
@MainActor enum Probe {
    static func run(seconds: Double) -> Bool {
        let args = CommandLine.arguments
        func flag(_ name: String) -> Double? { args.firstIndex(of: name).flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil } }
        let interval = flag("--interval") ?? 5
        let seconds = flag("--seconds") ?? seconds
        let camera = CameraSensor()
        camera.interval = interval
        let activity = ActivitySensor()
        let phone = PhoneSensor()
        camera.start()
        if Bundle.main.bundleIdentifier != nil { phone.start() }  // Bluetooth needs the app bundle's Info.plist usage string, so it is skipped under swift run.
        activity.start()
        let bluetooth = PhoneSensor.authorized ? "allowed" : PhoneSensor.undetermined ? "not asked" : "denied"
        print(String(format: "probe: interval=%.1fs window=%.0fs bluetooth=%@ (budget: CPU <= 3%%, footprint < 200 MB)", interval, seconds, bluetooth))

        let t0 = monotonic()
        var steady: (wall: Double, cpu: Double)?
        for sec in 1...max(1, Int(seconds)) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: t0 + Double(sec) - monotonic()))
            if sec == 5 { steady = (monotonic(), cpuSeconds()) }
            let r = camera.latest
            phone.update(idle: ActivitySensor.idleSeconds())
            let raw = r?.presence == .face ? (r?.pitchDown ?? 0) * CameraSensor.pitchSign : 0
            print(String(format: "%2ds presence=%@ rawPitch=%+6.1f pitchDown=%+6.1f phone=%.2f iphone=%@ mic=%@ app=%@ title=%@ url=%@ idle=%.0fs",
                         sec, r?.presence.rawValue ?? "nil", raw, r?.pitchDown ?? 0, r?.phone ?? 0, phone.inUse ? "in use" : "-",
                         Microphone.inUse() ? "in use" : "-", activity.appName ?? "-", activity.title ?? "-", activity.url ?? "-",
                         ActivitySensor.idleSeconds()))
        }
        let shot = camera.evidence(preferPhone: true).map { "evidence: image \($0.image.width)x\($0.image.height) px, face \($0.face != nil), phone \($0.phone != nil) (\(String(format: "%.2f", $0.phoneScore)))" } ?? "evidence: nil"
        camera.stop()
        phone.stop()

        let end = (wall: monotonic(), cpu: cpuSeconds())
        // The CPU reading needs at least 5 s after the 5 s warm-up to mean anything.
        guard let steady, end.wall - steady.wall >= 5 else {
            print("probe: use --seconds 10 or more for a CPU reading")
            print(shot)
            return false
        }
        let cpu = (end.cpu - steady.cpu) / (end.wall - steady.wall) * 100
        let mb = footprintMB()
        print(String(format: "steady CPU %.2f%% (5s to end), phys_footprint %.1f MB", cpu, mb))
        let passed = cpu <= 3 && mb < 200
        print(passed ? "PASS" : "FAIL: budget")
        print(shot)
        return passed
    }

    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
