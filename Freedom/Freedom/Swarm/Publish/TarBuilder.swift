import Foundation

/// USTAR tar archive encoder for `swarm_publishFiles`. Bee accepts the
/// archive at `POST /bzz` with `Content-Type: application/x-tar` and
/// `Swarm-Collection: true`. Format matches bee-js's `utils/tar.js`
/// (`TarStream`) so iOS-uploaded collections are byte-identical to
/// desktop's for the same input + `mtime`.
///
/// Hard limits (USTAR; no PAX extensions): path ≤ 100 chars, file size
/// ≤ 8 GB. The SWIP draft says paths up to 256 chars, but desktop also
/// caps at 100 — matching keeps iOS-published collections readable on
/// desktop and vice versa. Tracked as a SWIP-vs-impl divergence in the
/// roadmap doc §11.
enum TarBuilder {
    enum Error: Swift.Error, Equatable {
        /// `path` exceeded the USTAR 100-char limit. The bridge maps this
        /// to `-32602` so the dapp can fix the input.
        case pathTooLong(path: String)
    }

    struct Entry: Equatable {
        let path: String
        let bytes: Data
    }

    /// `mtime` defaults to the current wall-clock time so production
    /// uploads have a sensible timestamp; tests pin a fixed value
    /// (e.g. `Date(timeIntervalSince1970: 0)`) for deterministic
    /// golden-vector output.
    static func build(entries: [Entry], mtime: Date = Date()) throws -> Data {
        // Pre-size to the exact final length (header + padded data per
        // entry, plus the 1024-byte terminator). Saves the CoW reallocs
        // that `Data.append` would otherwise do for a 50 MB collection.
        var capacity = 1024
        for entry in entries {
            capacity += 512 + entry.bytes.count
            if !entry.bytes.count.isMultiple(of: 512) {
                capacity += 512 - (entry.bytes.count % 512)
            }
        }
        var output = Data()
        output.reserveCapacity(capacity)
        let mtimeSeconds = Int(mtime.timeIntervalSince1970)
        for entry in entries {
            output.append(try header(
                path: entry.path, size: entry.bytes.count, mtime: mtimeSeconds
            ))
            output.append(entry.bytes)
            // Pad data to the next 512-byte boundary.
            let pad = entry.bytes.count.isMultiple(of: 512)
                ? 0 : 512 - (entry.bytes.count % 512)
            if pad > 0 { output.append(Data(repeating: 0, count: pad)) }
        }
        // End-of-archive: two empty 512-byte blocks per the USTAR spec.
        output.append(Data(repeating: 0, count: 1024))
        return output
    }

    /// 512-byte USTAR header. Field offsets / lengths per the spec —
    /// the magic constants here are dictated by the format and not
    /// design choices we get to revisit.
    private static func header(
        path: String, size: Int, mtime: Int
    ) throws -> Data {
        // USTAR's 100 is a UTF-8 *byte* limit; reject before silently
        // truncating a multi-byte path. The bridge's `validateVirtualPath`
        // also gates on `path.utf8.count > 100` — this is the
        // defense-in-depth check.
        guard path.utf8.count <= 100 else { throw Error.pathTooLong(path: path) }
        var header = Data(repeating: 0, count: 512)

        // path (0..100, null-padded if shorter)
        let pathBytes = Array(path.utf8)
        header.replaceSubrange(0..<pathBytes.count, with: pathBytes)

        // mode 0o0777 + null (100..108)
        writeOctal(value: 0o0777, length: 7, into: &header, at: 100)
        // uid 0o1750 + null (108..116)
        writeOctal(value: 0o1750, length: 7, into: &header, at: 108)
        // gid 0o1750 + null (116..124)
        writeOctal(value: 0o1750, length: 7, into: &header, at: 116)
        // size, 11 octal digits + null (124..136)
        writeOctal(value: size, length: 11, into: &header, at: 124)
        // mtime, 11 octal digits + null (136..148)
        writeOctal(value: mtime, length: 11, into: &header, at: 136)

        // Checksum placeholder: 8 spaces (148..156) — included in the
        // sum we compute next.
        for i in 0..<8 { header[148 + i] = 0x20 }

        // typeflag '0' (regular file) at 156.
        header[156] = 0x30

        // USTAR magic "ustar" at 257..262. Bytes 262..265 stay zero —
        // matches bee-js's `'ustar\0\0'` write (pre-POSIX shape; bee
        // accepts either).
        let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72]
        header.replaceSubrange(257..<262, with: magic)

        // Header checksum: sum of all bytes (with the spaces
        // placeholder), written as 6 octal digits + null + space at
        // 148..156.
        let checksum = header.reduce(0) { $0 + Int($1) }
        writeOctal(value: checksum, length: 6, into: &header, at: 148)
        header[155] = 0x20  // trailing space (writeOctal already wrote
                            // the null at offset 154)
        return header
    }

    /// Writes `value` as zero-padded octal of `length` chars followed
    /// by a single null byte, total `length + 1` bytes at `offset`.
    private static func writeOctal(
        value: Int, length: Int, into data: inout Data, at offset: Int
    ) {
        let octal = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - octal.count)) + octal
        let truncated = padded.suffix(length)
        let bytes = Array(truncated.utf8)
        data.replaceSubrange(offset..<offset + length, with: bytes)
        data[offset + length] = 0
    }
}
