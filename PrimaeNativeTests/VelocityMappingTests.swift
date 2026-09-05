import Testing
import CoreGraphics
@testable import PrimaeNative

struct VelocityMappingTests {

    @Test func zeroVelocity_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(0) == 0.5)
    }

    @Test func lowBoundary_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(50) == 0.5)
    }

    @Test func highBoundary_returnsMaxRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(800) == 2.0)
    }

    @Test func aboveHigh_clampsToMaxRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(5000) == 2.0)
        #expect(TouchDispatcher.mapVelocityToSpeed(.greatestFiniteMagnitude) == 2.0)
    }

    @Test func belowLow_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(30)  == 0.5)
        #expect(TouchDispatcher.mapVelocityToSpeed(49)  == 0.5)
    }

    @Test func midpoint_returnsLinearInterpolation() {
        let mid: CGFloat = (50 + 800) / 2.0
        let expected: Float = 0.5 + (1.5 * 0.5)
        #expect(abs(TouchDispatcher.mapVelocityToSpeed(mid) - expected) < 1e-5)
    }

    @Test func monotonicallyNonDecreasing() {
        var prev: Float = 0.5
        for v in stride(from: CGFloat(0), through: 2000, by: 10) {
            let speed = TouchDispatcher.mapVelocityToSpeed(v)
            #expect(speed >= prev - 1e-6,
                "Speed must be non-decreasing: v=\(v) gave \(speed) < prev \(prev)")
            prev = speed
        }
    }

    @Test func result_alwaysInRange() {
        var rng = SeededRNGLocal()
        for _ in 0..<10_000 {
            let v = CGFloat(Double.random(in: 0...5000, using: &rng))
            let speed = TouchDispatcher.mapVelocityToSpeed(v)
            #expect(speed >= 0.5)
            #expect(speed <= 2.0)
            #expect(!speed.isNaN)
            #expect(!speed.isInfinite)
        }
    }

    @Test func negativeVelocity_treatedLikeZero() {
        #expect(TouchDispatcher.mapVelocityToSpeed(-100) == 0.5)
    }

    @Test func returnType_isFloat() {
        let result = TouchDispatcher.mapVelocityToSpeed(500)
        #expect(type(of: result) == Float.self)
    }
}

private struct SeededRNGLocal: RandomNumberGenerator {
    private var state: UInt64 = 0xfeedface_deadc0de
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
