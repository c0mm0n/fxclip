import Foundation

/// Display dimensions from the MP4 video track, including its pixel aspect ratio and rotation.
public struct MP4VideoGeometry: Equatable {
    public let width: Int
    public let height: Int

    /// Reads metadata only. Unsupported or ambiguous geometry is deliberately left unspecified.
    public static func read(_ data: Data) -> MP4VideoGeometry? {
        guard data.count <= 20 * 1024 * 1024 else { return nil }
        return data.withUnsafeBytes { bytes in
            var parser = Parser(bytes: bytes)
            return try? parser.read()
        }
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        var boxCount = 0

        private struct Box {
            let type: UInt32
            let payload: Range<Int>
        }

        private enum Invalid: Error { case metadata }

        mutating func read() throws -> MP4VideoGeometry {
            let movies = try boxes(in: 0..<bytes.count).filter { $0.type == 0x6d6f6f76 } // moov
            guard movies.count == 1 else { throw Invalid.metadata }
            var result: MP4VideoGeometry?
            // Only these four container levels are visited; media payloads remain opaque.
            for track in try boxes(in: movies[0].payload) where track.type == 0x7472616b { // trak
                if let geometry = try videoGeometry(in: track.payload) {
                    guard result == nil else { throw Invalid.metadata }
                    result = geometry
                }
            }
            guard let result else { throw Invalid.metadata }
            return result
        }

        private mutating func videoGeometry(in range: Range<Int>) throws -> MP4VideoGeometry? {
            let children = try boxes(in: range)
            let headers = children.filter { $0.type == 0x746b6864 } // tkhd
            let media = children.filter { $0.type == 0x6d646961 } // mdia
            guard headers.count == 1, media.count == 1 else { throw Invalid.metadata }
            let handlers = try boxes(in: media[0].payload).filter { $0.type == 0x68646c72 } // hdlr
            guard handlers.count == 1 else { throw Invalid.metadata }
            let handler = handlers[0].payload
            guard handler.count >= 24, bytes[handler.lowerBound] == 0 else { throw Invalid.metadata }

            let header = headers[0].payload
            guard !header.isEmpty else { throw Invalid.metadata }
            let matrixOffset: Int
            switch bytes[header.lowerBound] {
            case 0: matrixOffset = 40
            case 1: matrixOffset = 52
            default: throw Invalid.metadata
            }
            guard header.count >= matrixOffset + 44 else { throw Invalid.metadata }
            guard uint32(at: handler.lowerBound + 8) == 0x76696465 else { return nil } // vide

            let matrix = header.lowerBound + matrixOffset
            // Perspective must be identity. Translation changes the origin, not the dimensions.
            guard uint32(at: matrix + 8) == 0, uint32(at: matrix + 20) == 0,
                  uint32(at: matrix + 32) == 0x40000000 else { throw Invalid.metadata }
            let a = Int32(bitPattern: uint32(at: matrix))
            let b = Int32(bitPattern: uint32(at: matrix + 4))
            let c = Int32(bitPattern: uint32(at: matrix + 12))
            let d = Int32(bitPattern: uint32(at: matrix + 16))
            let swapsAxes: Bool
            switch (a, b, c, d) {
            case (65536, 0, 0, 65536), (-65536, 0, 0, -65536): swapsAxes = false
            case (0, 65536, -65536, 0), (0, -65536, 65536, 0): swapsAxes = true
            default: throw Invalid.metadata
            }

            // tkhd already carries display 16.16 dimensions, rather than coded sample dimensions.
            let width = Int((UInt64(uint32(at: matrix + 36)) + 0x8000) >> 16)
            let height = Int((UInt64(uint32(at: matrix + 40)) + 0x8000) >> 16)
            guard (1...65535).contains(width), (1...65535).contains(height) else {
                throw Invalid.metadata
            }
            return MP4VideoGeometry(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
        }

        private mutating func boxes(in range: Range<Int>) throws -> [Box] {
            var result: [Box] = []
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                guard boxCount < 4096 else { throw Invalid.metadata }
                boxCount += 1
                let remaining = range.upperBound - cursor
                guard remaining >= 8 else { throw Invalid.metadata }
                let shortSize = uint32(at: cursor)
                let headerSize: Int
                let size: UInt64
                switch shortSize {
                case 0:
                    headerSize = 8
                    size = UInt64(remaining)
                case 1:
                    guard remaining >= 16 else { throw Invalid.metadata }
                    headerSize = 16
                    size = UInt64(uint32(at: cursor + 8)) << 32 | UInt64(uint32(at: cursor + 12))
                default:
                    headerSize = 8
                    size = UInt64(shortSize)
                }
                // Compare before converting or adding an untrusted size, including extended sizes.
                guard size >= UInt64(headerSize), size <= UInt64(remaining) else { throw Invalid.metadata }
                let end = cursor + Int(size)
                result.append(Box(type: uint32(at: cursor + 4), payload: (cursor + headerSize)..<end))
                cursor = end
            }
            return result
        }

        /// Callers check the containing box's bounds before reading any fixed-width fields.
        private func uint32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
    }
}
