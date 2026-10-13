import Foundation

nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("✗ \(file):\(line) \(message())") }
}

let clock = ContinuousClock.now
engineTests()
rulesTests()
storeTests()
progressionTests()
gardenTests()
print(failures == 0 ? "✓ \(checks) checks passed" : "✗ \(failures) of \(checks) checks failed", "in \(ContinuousClock.now - clock)")
exit(failures == 0 ? 0 : 1)
