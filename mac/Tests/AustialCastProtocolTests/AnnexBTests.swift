import XCTest
@testable import AustialCastProtocol

final class AnnexBTests: XCTestCase {
    func testAVCCToAnnexB() throws {
        var avcc = Data()
        avcc.append(contentsOf: [0, 0, 0, 3, 0x67, 1, 2])
        avcc.append(contentsOf: [0, 0, 0, 2, 0x65, 9])
        let out = try XCTUnwrap(AnnexB.fromAVCC(avcc))
        XCTAssertEqual(out, Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x65, 9]))
    }

    func testAVCCRejectsTruncatedOrZeroLength() {
        XCTAssertNil(AnnexB.fromAVCC(Data([0, 0, 0, 9, 1, 2])))
        XCTAssertNil(AnnexB.fromAVCC(Data([0, 0, 0])))
        XCTAssertNil(AnnexB.fromAVCC(Data([0, 0, 0, 0])))
        XCTAssertEqual(AnnexB.fromAVCC(Data()), Data())
    }

    func testAVCCTwoByteLengths() {
        XCTAssertEqual(AnnexB.fromAVCC(Data([0, 2, 0x41, 7]), nalLengthSize: 2), Data([0, 0, 0, 1, 0x41, 7]))
    }

    func testSplitAndIDR() {
        let au = Data([0, 0, 0, 1, 0x09, 0x10, 0, 0, 1, 0x65, 1, 2])
        let nals = AnnexB.splitNalUnits(au)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(AnnexB.nalType(nals[1]), 5)
        XCTAssertTrue(AnnexB.containsIDR(au))
        XCTAssertFalse(AnnexB.containsIDR(Data([0, 0, 0, 1, 0x41, 1])))
        XCTAssertTrue(AnnexB.splitNalUnits(Data()).isEmpty)
    }

    func testBuildConfig() {
        let cfg = AnnexB.buildConfig(sps: Data([0x67, 1]), pps: Data([0x68, 2]))
        XCTAssertEqual(cfg, Data([0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2]))
        XCTAssertEqual(AnnexB.splitNalUnits(cfg).map(AnnexB.nalType), [7, 8])
    }

    func testAudioSpecificConfig() {
        XCTAssertEqual(AACConfig.audioSpecificConfigHex(sampleRate: 48000, channels: 2), "1190")
        XCTAssertEqual(AACConfig.audioSpecificConfigHex(sampleRate: 44100, channels: 2), "1210")
        XCTAssertEqual(AACConfig.audioSpecificConfigHex(sampleRate: 48000, channels: 1), "1188")
        XCTAssertNil(AACConfig.audioSpecificConfigHex(sampleRate: 12345, channels: 2))
        XCTAssertNil(AACConfig.audioSpecificConfigHex(sampleRate: 48000, channels: 0))
    }
}
