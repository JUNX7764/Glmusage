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
case "tokenTransition":
    var s = GLMTokenTransition()
    s.set(100, at: 0, animated: true)
    check(s.display == 100 && !s.isAnimating, "first display snaps")
    s.set(200, at: 10, animated: true)
    check(s.isAnimating, "interaction animates")
    check(s.advance(at: 10) == 100, "starts at current value")
    let middle = s.advance(at: 10.160)!
    check(abs(middle - 187.5) < 0.001, "320ms cubic ease-out midpoint")
    s.set(50, at: 10.160, animated: true)
    check(abs(s.display! - middle) < 0.001, "retarget without zero or jump")
    check(s.advance(at: 10.481) == 50 && !s.isAnimating, "latest target wins")
    s.set(nil, at: 11, animated: true)
    check(s.display == nil && s.target == nil && !s.isAnimating, "missing cancels")
    s.set(0, at: 12, animated: true)
    check(s.display == 0 && !s.isAnimating, "recovery and zero are real values")
    s.set(1_000_000, at: 13, animated: false)
    check(s.display == 1_000_000 && !s.isAnimating, "reduce motion snaps")
    s.set(.nan, at: 14, animated: true)
    check(s.target == nil && !s.isAnimating, "nonfinite values do not animate")
    print("PASS: tokenTransition")
default:
    fputs("FAIL: unknown visual fixture\n", stderr); exit(1)
}
