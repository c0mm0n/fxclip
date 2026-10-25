import Foundation
import XCTest
@testable import FxTelegram

final class MP4VideoGeometryTests: XCTestCase {
    private enum BoxSize { case standard, extended, toEnd }
    private let identity: [Int32] = [65536, 0, 0, 0, 65536, 0, 0, 0, 0x40000000]

    func testReadsGenericLandscapePortraitAndSquareDimensions() {
        for (width, height) in [(1920, 1080), (640, 360), (1080, 1920), (1024, 768), (1000, 1000)] {
            assertGeometry(movie(track(width: width, height: height)), width: width, height: height)
        }
    }

    func testRoundsPixelAspectCorrectedDisplayDimensions() {
        // A coded 854 x 480 sample with SAR 1280:1281 has this tkhd display width.
        let header = trackHeader(width: 0x03555555, height: 480 << 16)
        let data = movie(track(header: header))
        assertGeometry(data, width: 853, height: 480)
        let geometry = MP4VideoGeometry.read(data)!
        XCTAssertLessThan(abs(Double(geometry.width) / Double(geometry.height) / (16.0 / 9.0) - 1), 0.001)
        assertGeometry(movie(track(header: trackHeader(width: (853 << 16) + 0x8000, height: 480 << 16))),
                       width: 854, height: 480)
    }

    func testSupportsBothTrackHeaderVersions() {
        for version: UInt8 in [0, 1] {
            assertGeometry(movie(track(width: 1280, height: 720, version: version)), width: 1280, height: 720)
        }
    }

    func testFindsVideoBeforeOrAfterAudio() {
        let audio = track(header: trackHeader(width: 0, height: 0), handler: "soun")
        let video = track(width: 720, height: 1280)
        assertGeometry(movie(audio + video), width: 720, height: 1280)
        assertGeometry(movie(video + audio), width: 720, height: 1280)
        XCTAssertNil(MP4VideoGeometry.read(movie(audio)))
    }

    func testRequiresVideoHandlerRatherThanTrackOrderOrDimensions() {
        let audio = track(width: 1920, height: 1080, handler: "soun")
        XCTAssertNil(MP4VideoGeometry.read(movie(audio)))
        assertGeometry(movie(audio + track(width: 640, height: 480)), width: 640, height: 480)
        for handler in ["hint", "meta", "text", "Vide"] {
            XCTAssertNil(MP4VideoGeometry.read(movie(track(width: 640, height: 480, handler: handler))))
        }
    }

    func testOrthogonalRotationsAndTranslation() {
        let rotations: [([Int32], Bool)] = [
            (identity, false),
            ([0, 65536, 0, -65536, 0, 0, 1080 << 16, 0, 0x40000000], true),
            ([-65536, 0, 0, 0, -65536, 0, 1920 << 16, 1080 << 16, 0x40000000], false),
            ([0, -65536, 0, 65536, 0, 0, 0, 1920 << 16, 0x40000000], true),
        ]
        for version: UInt8 in [0, 1] {
            for (matrix, swap) in rotations {
                let data = movie(track(width: 1920, height: 1080, version: version, matrix: matrix))
                assertGeometry(data, width: swap ? 1080 : 1920, height: swap ? 1920 : 1080)
            }
        }
    }

    func testRejectsScaleShearReflectionAndPerspective() {
        for (index, value): (Int, Int32) in [
            (0, 32768), (0, 131072), (0, -65536), (0, 65535), (1, 1), (3, 65536),
            (2, 1), (5, 1), (8, 0), (8, 65536), (8, 0x3fffffff),
        ] {
            var matrix = identity
            matrix[index] = value
            XCTAssertNil(MP4VideoGeometry.read(movie(track(width: 640, height: 480, matrix: matrix))),
                         "matrix field \(index) = \(value)")
        }
        XCTAssertNil(MP4VideoGeometry.read(movie(track(width: 640, height: 480, matrix: Array(repeating: 0, count: 9)))))
    }

    func testStandardExtendedAndParentEndSizesAtEveryContainerLevel() {
        for size in [BoxSize.standard, .extended, .toEnd] {
            let header = trackHeader(width: 1280 << 16, height: 720 << 16)
            let video = track(header: header, size: size)
            assertGeometry(movie(video, size: size), width: 1280, height: 720)
        }
        // A size-zero tkhd must be last in its track; it ends at that parent, not the file end.
        let headerLast = atom("mdia", handler()) + atom("tkhd", trackHeader(width: 320 << 16, height: 240 << 16), size: .toEnd)
        assertGeometry(movie(atom("trak", headerLast)) + atom("free", Data()), width: 320, height: 240)
    }

    func testSkipsMediaAndUnknownPayloadsWithoutScanningForHeaders() {
        let fakeMovie = movie(track(width: 1, height: 1))
        let opaque = atom("mdat", fakeMovie + Data(repeating: 0xff, count: 256))
        let actual = movie(track(width: 800, height: 600))
        assertGeometry(opaque + atom("free", fakeMovie) + actual + opaque, width: 800, height: 600)
        XCTAssertNil(MP4VideoGeometry.read(opaque))
        XCTAssertNil(MP4VideoGeometry.read(atom("free", fakeMovie)))
    }

    func testIgnoresSampleDescriptionsAndUsesTrackDisplayDimensions() {
        let codedGeometry = atom("minf", atom("stbl", atom("stsd", Data(repeating: 0xff, count: 64))))
        let media = atom("mdia", handler() + codedGeometry)
        let data = movie(atom("trak", atom("tkhd", trackHeader(width: 0x03555555, height: 480 << 16)) + media))
        assertGeometry(data, width: 853, height: 480)
    }

    func testAcceptsDataSliceWithNonzeroStartIndex() {
        let video = movie(track(width: 1080, height: 1920))
        let storage = Data([0xff, 0xfe, 0xfd]) + video + Data([0xfc])
        let slice = storage[3..<(3 + video.count)]
        XCTAssertEqual(slice.startIndex, 3)
        assertGeometry(slice, width: 1080, height: 1920)
    }

    func testRejectsMissingAndDuplicateMoviesOrVideoTracks() {
        let video = track(width: 640, height: 480)
        for data in [Data(), atom("ftyp", Data("isom".utf8)), movie(Data()), video,
                     movie(video + video), movie(video) + movie(video), movie(video) + movie(Data())] {
            XCTAssertNil(MP4VideoGeometry.read(data))
        }
    }

    func testRejectsMissingOrDuplicateRequiredTrackBoxes() {
        let header = atom("tkhd", trackHeader(width: 640 << 16, height: 480 << 16))
        let media = atom("mdia", handler())
        for contents in [header, media, header + header + media, header + media + media,
                         header + atom("mdia", Data()), header + atom("mdia", handler() + handler())] {
            XCTAssertNil(MP4VideoGeometry.read(movie(atom("trak", contents))))
        }
    }

    func testRejectsUnsupportedAndTruncatedTrackHeaders() {
        for version: UInt8 in [0, 1] {
            let full = trackHeader(width: 640 << 16, height: 480 << 16, version: version)
            for count in 0..<full.count {
                XCTAssertNil(MP4VideoGeometry.read(movie(track(header: Data(full.prefix(count))))),
                             "version \(version), length \(count)")
            }
        }
        var unsupported = trackHeader(width: 640 << 16, height: 480 << 16)
        unsupported[0] = 2
        XCTAssertNil(MP4VideoGeometry.read(movie(track(header: unsupported))))
    }

    func testRejectsUnsupportedAndTruncatedHandlers() {
        let header = atom("tkhd", trackHeader(width: 640 << 16, height: 480 << 16))
        let full = handlerPayload()
        for count in 0..<full.count {
            let data = movie(atom("trak", header + atom("mdia", atom("hdlr", Data(full.prefix(count))))))
            XCTAssertNil(MP4VideoGeometry.read(data))
        }
        var unsupported = full
        unsupported[0] = 1
        XCTAssertNil(MP4VideoGeometry.read(movie(atom("trak", header + atom("mdia", atom("hdlr", unsupported))))))
    }

    func testRejectsZeroAndOutOfRangeDimensions() {
        for value: UInt32 in [0, 1, 0x7fff, UInt32.max] {
            XCTAssertNil(MP4VideoGeometry.read(movie(track(header: trackHeader(width: value, height: 480 << 16)))))
            XCTAssertNil(MP4VideoGeometry.read(movie(track(header: trackHeader(width: 640 << 16, height: value)))))
        }
        assertGeometry(movie(track(width: 1, height: 65535)), width: 1, height: 65535)
    }

    func testRejectsEveryTruncatedFilePrefix() {
        for size in [BoxSize.standard, .extended] {
            let data = movie(track(header: trackHeader(width: 640 << 16, height: 480 << 16), size: size), size: size)
            for count in 0..<data.count {
                XCTAssertNil(MP4VideoGeometry.read(Data(data.prefix(count))), "length \(count)")
            }
        }
    }

    func testRejectsHugeSizesBeforeConvertingOrAdding() {
        let valid = movie(track(width: 640, height: 480))
        for size: UInt64 in [16, 1024, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max] {
            let oversized = be32(1) + Data("free".utf8) + be64(size)
            // A 16-byte extended box is valid, but every larger declaration is truncated.
            if size == 16 {
                assertGeometry(oversized + valid, width: 640, height: 480)
            } else {
                XCTAssertNil(MP4VideoGeometry.read(oversized + valid))
            }
        }
        XCTAssertNil(MP4VideoGeometry.read(be32(UInt32.max) + Data("moov".utf8) + valid))
    }

    func testRejectsUndersizedBoxesAndPartialBoxHeaders() {
        let valid = movie(track(width: 640, height: 480))
        for size: UInt32 in 2..<8 {
            XCTAssertNil(MP4VideoGeometry.read(be32(size) + Data("free".utf8) + valid))
        }
        for size: UInt64 in 0..<16 {
            XCTAssertNil(MP4VideoGeometry.read(be32(1) + Data("free".utf8) + be64(size) + valid))
        }
        for length in 1..<8 {
            XCTAssertNil(MP4VideoGeometry.read(valid + Data(repeating: 0, count: length)))
        }
    }

    func testChildSizesCannotEscapeTheirParent() {
        let video = track(width: 640, height: 480)
        let escaping = be32(UInt32(video.count + 16)) + Data("trak".utf8) + video
        XCTAssertNil(MP4VideoGeometry.read(movie(escaping) + atom("free", Data(repeating: 0, count: 16))))
        let header = atom("tkhd", trackHeader(width: 640 << 16, height: 480 << 16))
        for contents in [video + Data([1]), atom("trak", header + atom("mdia", handler() + Data([1]))),
                         atom("trak", header + atom("mdia", handler()) + Data([1]))] {
            XCTAssertNil(MP4VideoGeometry.read(movie(contents)))
        }
    }

    func testBoundsTotalVisitedBoxesAcrossContainers() {
        let video = movie(track(width: 640, height: 480)) // Five visited boxes.
        let empty = atom("free", Data())
        var data = Data()
        for _ in 0..<4091 { data.append(empty) }
        assertGeometry(data + video, width: 640, height: 480)
        XCTAssertNil(MP4VideoGeometry.read(data + empty + video))
        // The same budget applies to children, not only top-level boxes.
        XCTAssertNil(MP4VideoGeometry.read(movie(data + empty + track(width: 640, height: 480))))
    }

    func testBoundsInputSizeWhileSkippingOpaqueMedia() {
        let video = movie(track(width: 640, height: 480))
        let limit = 20 * 1024 * 1024
        let data = video + atom("mdat", Data(repeating: 0, count: limit - video.count - 8))
        XCTAssertEqual(data.count, limit)
        assertGeometry(data, width: 640, height: 480)
        XCTAssertNil(MP4VideoGeometry.read(data + Data([0])))
    }

    func testDoesNotRecurseIntoUnexpectedContainers() {
        var nested = track(width: 640, height: 480)
        for _ in 0..<100 { nested = movie(nested) }
        XCTAssertNil(MP4VideoGeometry.read(nested))
    }

    private func assertGeometry(_ data: Data, width: Int, height: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(MP4VideoGeometry.read(data), MP4VideoGeometry(width: width, height: height), file: file, line: line)
    }

    private func movie(_ tracks: Data, size: BoxSize = .standard) -> Data {
        atom("moov", tracks, size: size)
    }

    private func track(width: Int, height: Int, version: UInt8 = 0, matrix: [Int32]? = nil,
                       handler: String = "vide") -> Data {
        track(header: trackHeader(width: UInt32(width) << 16, height: UInt32(height) << 16,
                                  version: version, matrix: matrix), handler: handler)
    }

    private func track(header: Data, handler type: String = "vide", size: BoxSize = .standard) -> Data {
        atom("trak", atom("tkhd", header, size: size == .extended ? .extended : .standard)
             + atom("mdia", handler(type, size: size), size: size), size: size)
    }

    private func trackHeader(width: UInt32, height: UInt32, version: UInt8 = 0, matrix: [Int32]? = nil) -> Data {
        var data = Data(repeating: 0, count: version == 1 ? 52 : 40)
        data[0] = version
        data[3] = 3 // Enabled and in the movie.
        for value in matrix ?? identity { data.append(be32(UInt32(bitPattern: value))) }
        data.append(be32(width))
        data.append(be32(height))
        return data
    }

    private func handler(_ type: String = "vide", size: BoxSize = .standard) -> Data {
        atom("hdlr", handlerPayload(type), size: size)
    }

    private func handlerPayload(_ type: String = "vide") -> Data {
        Data(repeating: 0, count: 8) + Data(type.utf8) + Data(repeating: 0, count: 12)
    }

    private func atom(_ type: String, _ payload: Data, size: BoxSize = .standard) -> Data {
        switch size {
        case .standard: return be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
        case .extended: return be32(1) + Data(type.utf8) + be64(UInt64(payload.count + 16)) + payload
        case .toEnd: return be32(0) + Data(type.utf8) + payload
        }
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private func be64(_ value: UInt64) -> Data {
        be32(UInt32(truncatingIfNeeded: value >> 32)) + be32(UInt32(truncatingIfNeeded: value))
    }
}
