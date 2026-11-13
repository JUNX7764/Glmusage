import AppKit

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

switch CommandLine.arguments.dropFirst().first {
case "dailyCorners":
    let rect = NSRect(x: 0, y: 0, width: 6, height: 20)
    let path = GLMPanelVisuals.dailyPath(in: rect, isZero: false)
    check(path.bounds == rect, "rounding must preserve width, height and baseline")
    check(path.contains(NSPoint(x: 0.1, y: 0.1)), "bottom remains square")
    check(!path.contains(NSPoint(x: 0.1, y: 19.9)), "top corner is rounded")
    let zero = GLMPanelVisuals.dailyPath(in: NSRect(x: 0, y: 0, width: 6, height: 2), isZero: true)
    check(zero.contains(NSPoint(x: 0.1, y: 1.9)), "zero-day marker remains rectangular")
    for height in [0.2, 1.0, 3.0] {
        let tiny = GLMPanelVisuals.dailyPath(in: NSRect(x: 0, y: 0, width: 6, height: height), isZero: false)
        check(tiny.bounds.minY >= 0 && tiny.bounds.maxY <= height + 0.0001, "short bars stay in bounds")
    }
    print("PASS: dailyCorners")
default:
    fputs("FAIL: unknown visual fixture\n", stderr); exit(1)
}
