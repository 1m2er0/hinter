import Testing
@testable import HinterCore

@Test func scrollsDownInStepsThenWrapsToTop() {
    var s = AutoScroll(step: 70, holdTicks: 2)
    #expect(s.next(maxY: 0) == nil)                 // fits: nothing to do
    var ys: [Double] = []
    for _ in 0..<11 { if let y = s.next(maxY: 150) { ys.append(y) } }
    // H H 70 140 150 H H 0 H H 70 — pauses at top and bottom so both ends can be read
    #expect(ys == [70, 140, 150, 0, 70])
}

@Test func newContentRestartsFromTop() {
    var s = AutoScroll(step: 70, holdTicks: 1)
    _ = s.next(maxY: 300); _ = s.next(maxY: 300)
    s.reset()
    #expect(s.y == 0)
}
