import AppKit

enum GLMPanelVisuals {
    static let dailySymbol = "chart.bar"
    static let historySymbol = "clock.arrow.circlepath"
    static let dailyCornerRadius: CGFloat = 1.5

    static func topRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return NSBezierPath(rect: rect) }
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                       radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                       radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.close()
        return path
    }

    static func dailyPath(in rect: NSRect, isZero: Bool) -> NSBezierPath {
        isZero ? NSBezierPath(rect: rect)
               : topRoundedPath(in: rect, radius: dailyCornerRadius)
    }
    static func historyBar(in column: NSRect, baseline: CGFloat, usedPercent: Double)
        -> (track: NSRect, fill: NSRect?) {
        let width = min(CGFloat(12), max(0, column.width - 4))
        let height = max(0, column.height - baseline - 4)
        let track = NSRect(x: column.midX - width / 2, y: baseline,
                           width: width, height: height)
        guard usedPercent.isFinite, usedPercent > 0, !track.isEmpty else {
            return (track, nil)
        }
        let fraction = CGFloat(min(100, max(0, usedPercent)) / 100)
        let fill = NSRect(x: track.minX, y: track.minY,
                          width: track.width, height: track.height * fraction)
        return (track, fill)
    }
}
