import AppKit

let args = CommandLine.arguments
// The garden renderer's child process (GardenModel.draw): `--render-garden <steps> <dir>`.
if let i = args.firstIndex(of: "--render-garden"), i + 2 < args.count, let steps = Int(args[i + 1]) {
    exit(GardenModel.render(steps, to: URL(fileURLWithPath: args[i + 2])) ? 0 : 1)
}
if let i = args.firstIndex(of: "--snapshots") {
    MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : ".build/snapshots")) }
    exit(0)
}
if args.contains("--probe") {
    let passed = MainActor.assumeIsolated { Probe.run(seconds: 20) }
    exit(passed ? 0 : 1)
}
// `Focus --garden-demo [seconds]`: the Focus window replaying the garden's reveal and life, for measuring their cost (default 60 s).
if let i = args.firstIndex(of: "--garden-demo") {
    let seconds = i + 1 < args.count ? Double(args[i + 1]) ?? 60 : 60
    MainActor.assumeIsolated { AppModel.gardenDemo = seconds }
}
// `Focus --garden-preview`: the garden alone in the Focus window with a level slider, to see it grow level by level (nothing is saved).
if args.contains("--garden-preview") {
    MainActor.assumeIsolated { AppModel.gardenPreview = true }
}
// `Focus --start "<task>" [minutes]`: starts a session on launch if none is running, for automated checks (see README).
if let i = args.firstIndex(of: "--start"), i + 1 < args.count {
    let minutes = i + 2 < args.count ? Int(args[i + 2]) ?? 25 : 25
    MainActor.assumeIsolated { AppModel.launchStart = (task: args[i + 1], minutes: minutes) }
}
FocusApp.main()
