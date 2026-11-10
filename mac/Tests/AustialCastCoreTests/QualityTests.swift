import XCTest
@testable import AustialCastCore

final class QualityTests: XCTestCase {
    func testOutputSizeNeverUpscalesAndKeepsAspect() {
        let p = QualityPreset.fullHD30
        XCTAssertTrue(p.outputSize(sourceWidth: 1280, sourceHeight: 720, receiverMaxWidth: 3840, receiverMaxHeight: 2160) == (1280, 720))
        let big = p.outputSize(sourceWidth: 3024, sourceHeight: 1964, receiverMaxWidth: 3840, receiverMaxHeight: 2160)
        XCTAssertLessThanOrEqual(big.width, 1920)
        XCTAssertLessThanOrEqual(big.height, 1080)
        XCTAssertEqual(Double(big.width) / Double(big.height), 3024.0 / 1964.0, accuracy: 0.01)
    }

    func testOutputSizeIsEven() {
        for (w, h) in [(1441, 901), (999, 333), (3023, 1963), (2, 2), (1, 1)] {
            let s = QualityPreset.uhd30.outputSize(sourceWidth: w, sourceHeight: h, receiverMaxWidth: 3840, receiverMaxHeight: 2160)
            XCTAssertEqual(s.width % 2, 0, "\(w)x\(h)")
            XCTAssertEqual(s.height % 2, 0, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(s.width, 2)
        }
    }

    func testReceiverLimitsWin() {
        let s = QualityPreset.uhd30.outputSize(sourceWidth: 3840, sourceHeight: 2160, receiverMaxWidth: 1920, receiverMaxHeight: 1080)
        XCTAssertTrue(s == (1920, 1080))
        XCTAssertEqual(QualityPreset.fullHD60.effectiveFps(receiverMax: 30), 30)
        XCTAssertEqual(QualityPreset.fullHD30.effectiveFps(receiverMax: 60), 30)
    }

    func testPortraitSourceFitsInsideBox() {
        let s = QualityPreset.fullHD30.outputSize(sourceWidth: 1000, sourceHeight: 2000, receiverMaxWidth: 3840, receiverMaxHeight: 2160)
        XCTAssertEqual(s.height, 1080)
        XCTAssertEqual(s.width, 540)
    }

    func testInvalidSourceFallsBackToPresetBox() {
        let s = QualityPreset.hd720p30.outputSize(sourceWidth: 0, sourceHeight: 0, receiverMaxWidth: 3840, receiverMaxHeight: 2160)
        XCTAssertTrue(s == (1280, 720))
    }

    func testBitrateScalesWithPixels() {
        let p = QualityPreset.fullHD60
        XCTAssertEqual(p.bitrate(forWidth: 1920, height: 1080), p.bitrate)
        XCTAssertLessThan(p.bitrate(forWidth: 960, height: 540), p.bitrate)
        XCTAssertGreaterThanOrEqual(p.bitrate(forWidth: 16, height: 16), 800_000)
        XCTAssertEqual(p.bitrate(forWidth: 3840, height: 2160), p.bitrate, "never exceeds the preset")
    }

    func testPresetLookup() {
        XCTAssertEqual(QualityPreset.byId("1080p60"), .fullHD60)
        XCTAssertNil(QualityPreset.byId("nope"))
        XCTAssertEqual(Set(QualityPreset.all.map(\.id)).count, QualityPreset.all.count)
    }

    func testAdaptiveBitrateBacksOffWithCooldown() {
        var a = AdaptiveBitrate(initial: 10_000_000, maximum: 10_000_000)
        XCTAssertEqual(a.onCongestion(now: 100), 7_000_000)
        XCTAssertNil(a.onCongestion(now: 100.5), "cooldown prevents a death spiral")
        XCTAssertEqual(a.onCongestion(now: 103), 4_900_000)
    }

    func testAdaptiveBitrateFloorsAtMinimum() {
        var a = AdaptiveBitrate(initial: 1_000_000, minimum: 800_000, maximum: 10_000_000)
        _ = a.onCongestion(now: 0)
        _ = a.onCongestion(now: 10)
        XCTAssertEqual(a.current, 800_000)
        XCTAssertNil(a.onCongestion(now: 20))
    }

    func testAdaptiveBitrateRecoversSlowlyAndCapsAtMaximum() {
        var a = AdaptiveBitrate(initial: 10_000_000, maximum: 10_000_000)
        _ = a.onCongestion(now: 0)
        XCTAssertNil(a.onTick(now: 4), "no recovery right after congestion")
        let up = a.onTick(now: 20)
        XCTAssertNotNil(up)
        XCTAssertGreaterThan(up!, 7_000_000)
        var now = 20.0
        for _ in 0..<50 { now += 10; _ = a.onTick(now: now) }
        XCTAssertEqual(a.current, 10_000_000)
        XCTAssertNil(a.onTick(now: now + 100))
    }

    func testReceiverRequestedBitrateIsClamped() {
        var a = AdaptiveBitrate(initial: 5_000_000, minimum: 1_000_000, maximum: 8_000_000)
        XCTAssertEqual(a.request(20_000_000, now: 0), 8_000_000)
        XCTAssertEqual(a.request(10, now: 1), 1_000_000)
        XCTAssertNil(a.onTick(now: 2), "recovery waits after an explicit request")
    }

    func testSendGatePassesFramesWhenNetworkIsFine() {
        var g = SendGate(maxPendingBytes: 1000)
        XCTAssertEqual(g.decide(isKeyframe: false, pendingBytes: 100), .init(send: true, requestKeyframe: false, congested: false))
        XCTAssertEqual(g.decide(isKeyframe: true, pendingBytes: 1000).send, true)
    }

    func testSendGateDropsUntilKeyframeAfterCongestion() {
        var g = SendGate(maxPendingBytes: 1000)
        let first = g.decide(isKeyframe: false, pendingBytes: 5000)
        XCTAssertEqual(first, .init(send: false, requestKeyframe: false, congested: true))
        // Still backed up: keep dropping, no keyframe request yet.
        XCTAssertEqual(g.decide(isKeyframe: false, pendingBytes: 4000), .init(send: false, requestKeyframe: false, congested: false))
        // Buffer drained: ask for a keyframe exactly once; P-frames are still dropped.
        XCTAssertEqual(g.decide(isKeyframe: false, pendingBytes: 100), .init(send: false, requestKeyframe: true, congested: false))
        XCTAssertEqual(g.decide(isKeyframe: false, pendingBytes: 100), .init(send: false, requestKeyframe: false, congested: false))
        // The keyframe ends the drop phase.
        XCTAssertEqual(g.decide(isKeyframe: true, pendingBytes: 100), .init(send: true, requestKeyframe: false, congested: false))
        XCTAssertFalse(g.isDropping)
        XCTAssertTrue(g.decide(isKeyframe: false, pendingBytes: 100).send)
    }

    func testSendGateIgnoresKeyframeWhileStillCongested() {
        var g = SendGate(maxPendingBytes: 1000)
        _ = g.decide(isKeyframe: false, pendingBytes: 5000)
        XCTAssertFalse(g.decide(isKeyframe: true, pendingBytes: 900).send, "keyframe into a full buffer would just add latency")
        XCTAssertTrue(g.decide(isKeyframe: true, pendingBytes: 100).send)
    }
}
