import Foundation
import zlib

public enum GzipError: Error {
    case initializationFailed(Int32)
    case compressionFailed(Int32)
}

public struct Gzip {
    /// Compresses data into RFC 1952 Gzip format (magic bytes: 0x1F, 0x8B).
    /// Uses zlib deflateInit2 with windowBits = 31 (15 + 16).
    public static func compress(data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let windowBits: Int32 = 15 + 16 // 31 creates gzip stream with 1F 8B header
        let memLevel: Int32 = 8

        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            memLevel,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initStatus == Z_OK else {
            throw GzipError.initializationFailed(initStatus)
        }
        defer { deflateEnd(&stream) }

        var compressed = Data(capacity: data.count / 2 + 64)
        let bufferSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        data.withUnsafeBytes { rawIn in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawIn.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            var status = Z_OK
            while status != Z_STREAM_END {
                buffer.withUnsafeMutableBufferPointer { rawOut in
                    stream.next_out = rawOut.baseAddress
                    stream.avail_out = uInt(bufferSize)

                    status = deflate(&stream, Z_FINISH)
                    let bytesProduced = bufferSize - Int(stream.avail_out)

                    if bytesProduced > 0 {
                        compressed.append(rawOut.baseAddress!, count: bytesProduced)
                    }
                }
                if status != Z_OK && status != Z_STREAM_END {
                    break
                }
            }
        }

        return compressed
    }

    /// Verifies if data starts with Gzip magic bytes 0x1F, 0x8B
    public static func isGzip(data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0x1F && data[1] == 0x8B
    }
}

