/// Step-wise auto-scroll for an overflowing panel: pause at the top, step down, pause at the bottom, jump to the top.
/// Steps (not continuous motion) keep rendering cheap: one small animation per tick.
public struct AutoScroll {
    let step: Double, holdTicks: Int
    public private(set) var y: Double = 0
    var hold: Int

    public init(step: Double = 70, holdTicks: Int = 2) { self.step = step; self.holdTicks = holdTicks; hold = holdTicks }

    public mutating func reset() { y = 0; hold = holdTicks }

    /// New offset to show, or nil when nothing should move this tick.
    public mutating func next(maxY: Double) -> Double? {
        guard maxY > 1 else { if y != 0 { reset(); return 0 }; return nil }
        if hold > 0 { hold -= 1; return nil }
        if y >= maxY { reset(); return 0 }
        y = min(maxY, y + step)
        if y >= maxY { hold = holdTicks }
        return y
    }
}
