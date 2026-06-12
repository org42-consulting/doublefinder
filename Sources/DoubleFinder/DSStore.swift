import Foundation
import CoreGraphics

/// Minimal read-only parser for Finder `.DS_Store` files (the "Bud1" buddy
/// allocator + B-tree format). Only the record types needed to reproduce a
/// disk image's Finder layout are surfaced: `Iloc` (icon positions), `icvp`
/// (icon view properties plist) and `bwsp` (window properties plist).
///
/// The file comes from inside a mounted image, i.e. it is untrusted input —
/// every read is bounds-checked and traversal is capped, so a malformed or
/// hostile file degrades to `nil`/`throw` instead of crashing.
enum DSStore {

    struct Record {
        let name: String      // file name the record describes ("." rows use the icvp/bwsp plists)
        let structId: String  // four-char code: "Iloc", "icvp", "bwsp", ...
        let blob: Data?       // payload for 'blob' typed records; nil for scalar types
    }

    enum ParseError: Error {
        case truncated
        case badMagic
        case malformed
    }

    // Hard caps so a crafted file can't make us allocate or loop unboundedly.
    private static let maxRecords = 20_000
    private static let maxNodes = 10_000
    private static let maxNameLength = 1_024
    private static let maxBlobLength = 16 * 1024 * 1024

    static func parse(_ data: Data) throws -> [Record] {
        var r = Reader(data: data)
        guard try r.u32() == 1 else { throw ParseError.badMagic }
        guard try r.fourCC() == "Bud1" else { throw ParseError.badMagic }
        let allocatorOffset = Int(try r.u32())

        // Buddy allocator header: block-address table, then a name → block-id
        // table of contents. All block offsets in the file are relative to
        // byte 4 (past the leading 0x00000001).
        try r.seek(allocatorOffset + 4)
        let blockCount = Int(try r.u32())
        guard blockCount >= 0, blockCount <= maxNodes else { throw ParseError.malformed }
        _ = try r.u32() // unknown
        var addresses: [UInt32] = []
        addresses.reserveCapacity(blockCount)
        for _ in 0..<blockCount { addresses.append(try r.u32()) }
        // The address table is padded with zeros to a multiple of 256 entries.
        let padEntries = (256 - blockCount % 256) % 256
        try r.skip(padEntries * 4)

        let tocCount = Int(try r.u32())
        guard tocCount >= 0, tocCount <= 256 else { throw ParseError.malformed }
        var dsdbBlock: Int? = nil
        for _ in 0..<tocCount {
            let nameLen = Int(try r.u8())
            let name = String(decoding: try r.bytes(nameLen), as: UTF8.self)
            let value = Int(try r.u32())
            if name == "DSDB" { dsdbBlock = value }
        }
        guard let dsdb = dsdbBlock else { throw ParseError.malformed }

        func blockOffset(_ id: Int) throws -> Int {
            guard id >= 0, id < addresses.count else { throw ParseError.malformed }
            let addr = addresses[id]
            return Int(addr & ~0x1F) + 4
        }

        // Master block: root node id + tree metadata.
        try r.seek(try blockOffset(dsdb))
        let rootNode = Int(try r.u32())

        var records: [Record] = []
        var visited: Set<Int> = []

        func walk(_ nodeId: Int) throws {
            guard visited.count < maxNodes, records.count < maxRecords else { return }
            guard visited.insert(nodeId).inserted else { throw ParseError.malformed } // cycle
            var n = Reader(data: data)
            try n.seek(try blockOffset(nodeId))
            let p = Int(try n.u32())
            let count = Int(try n.u32())
            guard count >= 0, count <= maxRecords else { throw ParseError.malformed }
            var children: [Int] = []
            for _ in 0..<count {
                if p != 0 { children.append(Int(try n.u32())) }
                if let rec = try readRecord(&n), records.count < maxRecords {
                    records.append(rec)
                }
            }
            if p != 0 { children.append(p) }
            for child in children { try walk(child) }
        }

        try walk(rootNode)
        return records
    }

    /// Reads one record; returns nil for record types we don't keep (after
    /// consuming the correct number of bytes so the stream stays aligned).
    private static func readRecord(_ r: inout Reader) throws -> Record? {
        let nameLen = Int(try r.u32())
        guard nameLen >= 0, nameLen <= maxNameLength else { throw ParseError.malformed }
        let nameData = try r.bytes(nameLen * 2)
        let name = String(data: nameData, encoding: .utf16BigEndian) ?? ""
        let structId = try r.fourCC()
        let dataType = try r.fourCC()

        var blob: Data? = nil
        switch dataType {
        case "long", "shor", "type": try r.skip(4)
        case "bool":                 try r.skip(1)
        case "comp", "dutc":         try r.skip(8)
        case "ustr":
            let len = Int(try r.u32())
            guard len >= 0, len <= maxBlobLength / 2 else { throw ParseError.malformed }
            try r.skip(len * 2)
        case "blob":
            let len = Int(try r.u32())
            guard len >= 0, len <= maxBlobLength else { throw ParseError.malformed }
            blob = try r.bytes(len)
        default:
            throw ParseError.malformed
        }
        return Record(name: name, structId: structId, blob: blob)
    }

    /// `Iloc` payload: icon centre as two big-endian UInt32s (x, y), followed
    /// by 8 reserved bytes.
    static func iconPosition(fromIloc blob: Data) -> CGPoint? {
        guard blob.count >= 8 else { return nil }
        var r = Reader(data: blob)
        guard let x = try? r.u32(), let y = try? r.u32() else { return nil }
        // Finder occasionally writes sentinel positions for unplaced items.
        guard x < 100_000, y < 100_000 else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    /// Extracts the POSIX path stored in a classic alias record (tag 18 of
    /// the variable-length section). Used to locate `icvp`'s
    /// `backgroundImageAlias` without the long-deprecated Alias Manager.
    static func posixPath(fromAlias alias: Data) -> String? {
        let data = Data(alias) // re-base indices in case we got a slice
        guard data.count > 150 else { return nil }
        let version = Int(data[6]) << 8 | Int(data[7])
        guard version == 2 else { return nil }
        var off = 150
        while off + 4 <= data.count {
            let tag = Int16(bitPattern: UInt16(data[off]) << 8 | UInt16(data[off + 1]))
            let len = Int(data[off + 2]) << 8 | Int(data[off + 3])
            off += 4
            if tag == -1 { return nil }
            guard len >= 0, off + len <= data.count else { return nil }
            if tag == 18 { // POSIX path of target
                return String(data: data[off..<(off + len)], encoding: .utf8)
            }
            off += len + (len & 1) // entries are 2-byte aligned
        }
        return nil
    }

    /// Bounds-checked big-endian cursor over the raw file bytes.
    private struct Reader {
        let data: Data
        private(set) var offset: Int = 0

        init(data: Data) { self.data = Data(data) }

        mutating func seek(_ to: Int) throws {
            guard to >= 0, to <= data.count else { throw ParseError.truncated }
            offset = to
        }

        mutating func skip(_ n: Int) throws { try seek(offset + n) }

        mutating func u8() throws -> UInt8 {
            guard offset + 1 <= data.count else { throw ParseError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw ParseError.truncated }
            defer { offset += 4 }
            return (UInt32(data[offset]) << 24)
                 | (UInt32(data[offset + 1]) << 16)
                 | (UInt32(data[offset + 2]) << 8)
                 |  UInt32(data[offset + 3])
        }

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.count else { throw ParseError.truncated }
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }

        mutating func fourCC() throws -> String {
            String(decoding: try bytes(4), as: UTF8.self)
        }
    }
}
