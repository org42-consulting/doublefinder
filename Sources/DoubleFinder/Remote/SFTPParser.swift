import Foundation

enum SFTPParser {

    // MARK: - Progress

    /// Parse `Transferred: N bytes` lines and update `progress.completedUnitCount`.
    static func updateProgress(_ progress: Progress, from buffer: String) {
        // We look for the last full "Transferred: <n> bytes" line in the buffer.
        var lastBytes: Int64?
        for line in buffer.split(separator: "\n") {
            if let bytes = parseTransferredLine(String(line)) {
                lastBytes = bytes
            }
        }
        if let lastBytes {
            progress.completedUnitCount = lastBytes
        }
    }

    private static func parseTransferredLine(_ line: String) -> Int64? {
        // sftp progress text examples:
        // "Transferred: sent 1234, received 5678 bytes, in 1.0 seconds"
        // "Sink: open /remote/file -> /local/file"
        // We accept the most common variant first.
        if let r = line.range(of: #"Transferred:\s+sent\s+(\d+)"#, options: .regularExpression) {
            let s = line[r]
            let digits = s.split(separator: " ").last ?? ""
            return Int64(digits)
        }
        if let r = line.range(of: #"(\d+)\s+bytes\s+transferred"#, options: .regularExpression) {
            let s = String(line[r])
            let digits = s.split(separator: " ").first ?? ""
            return Int64(digits)
        }
        return nil
    }

    // MARK: - ls -l parsing

    /// One row from `ls -la` output (after skipping the `total` line and `.`/`..`).
    struct LSEntry {
        let isDirectory: Bool
        let isSymlink: Bool
        let permissions: String       // "rwxr-xr-x" (9 chars)
        let owner: String
        let group: String
        let size: Int64
        let modified: Date?
        let name: String
        let linkTarget: String?       // when isSymlink, the value after " -> "
    }

    /// Parse the output of `ls -la <dir>` into entries. Skips total/./.. lines.
    /// Filename component preserves spaces; entries with unrecognised mode chars are skipped.
    static func parseLSLong(_ output: String, referenceDate: Date = Date()) -> [LSEntry] {
        var entries: [LSEntry] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("total ") { continue }
            if line.isEmpty { continue }
            guard let e = parseLSLongLine(line, referenceDate: referenceDate) else { continue }
            if e.name == "." || e.name == ".." { continue }
            entries.append(e)
        }
        return entries
    }

    private static func parseLSLongLine(_ line: String, referenceDate: Date) -> LSEntry? {
        // Expected columns:
        //   mode links owner group size mon day {year|HH:MM} name [-> target]
        // Names may contain spaces; the date column has a stable layout (3 tokens).
        // Strategy: split into tokens, take first 5 then date (3 tokens), join the rest as name.

        // Some platforms add an ACL char ('+') or a colon at the end of perms. We just need char 0
        // for type and the rest for visible perms.
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }

        let mode = parts[0]
        guard let typeChar = mode.first else { return nil }
        let isDir = typeChar == "d"
        let isSym = typeChar == "l"
        let perms = String(mode.dropFirst().prefix(9))
        let owner = parts[2]
        let group = parts[3]
        let size = Int64(parts[4]) ?? 0
        let mon = parts[5]
        let day = parts[6]
        let yearOrTime = parts[7]
        // Take the name from the ORIGINAL line rather than re-joining tokens.
        // Splitting with `omittingEmptySubsequences: true` collapses runs of
        // spaces, so `joined(separator: " ")` turned "my  file.txt" into
        // "my file.txt" — a name that doesn't exist on the server, breaking
        // every subsequent operation on that row.
        guard let rest = remainderAfterTokens(8, in: line) else { return nil }

        // Split " -> " for symlinks
        var name = rest
        var linkTarget: String? = nil
        if isSym, let arrow = rest.range(of: " -> ") {
            name = String(rest[rest.startIndex..<arrow.lowerBound])
            linkTarget = String(rest[arrow.upperBound...])
        }

        let date = parseLSDate(mon: mon, day: day, yearOrTime: yearOrTime, referenceDate: referenceDate)

        return LSEntry(
            isDirectory: isDir,
            isSymlink: isSym,
            permissions: perms,
            owner: owner,
            group: group,
            size: size,
            modified: date,
            name: name,
            linkTarget: linkTarget
        )
    }

    /// Returns everything after the first `count` whitespace-separated tokens,
    /// preserving spacing *within* the remainder.
    ///
    /// `ls -l` right-aligns the size column and pads single-digit days
    /// ("Jan  1"), so the separator between fields can be several spaces — we
    /// skip all of them before the name starts. Spaces inside the name itself
    /// are then kept verbatim, which is the whole point of reading from the
    /// original line.
    private static func remainderAfterTokens(_ count: Int, in line: String) -> String? {
        var idx = line.startIndex
        var consumed = 0
        while consumed < count {
            while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
            guard idx < line.endIndex else { return nil }
            while idx < line.endIndex, line[idx] != " " { idx = line.index(after: idx) }
            consumed += 1
        }
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return nil }
        return String(line[idx...])
    }

    private static func parseLSDate(mon: String, day: String, yearOrTime: String, referenceDate: Date) -> Date? {
        let monNames = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard let monthIdx = monNames.firstIndex(of: mon) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.month = monthIdx + 1
        comps.day = Int(day)

        if yearOrTime.contains(":") {
            // HH:MM form — file is in current or previous year (sftp uses HH:MM for files newer than ~6 months).
            let timeParts = yearOrTime.split(separator: ":")
            guard timeParts.count == 2 else { return nil }
            comps.hour = Int(timeParts[0])
            comps.minute = Int(timeParts[1])
            let now = calendar.dateComponents([.year, .month], from: referenceDate)
            comps.year = now.year
            if let date = calendar.date(from: comps), date > referenceDate {
                // The date would be in the future — back up a year.
                comps.year = (now.year ?? 0) - 1
            }
        } else {
            comps.year = Int(yearOrTime)
        }

        return calendar.date(from: comps)
    }

    // MARK: - sftp argument quoting

    /// Shell-quote a path for use as an `sftp` interactive command argument.
    ///
    /// Uses single-quote wrapping because sftp's REPL treats `'...'` as a
    /// literal string with no escape processing, unlike double-quotes where
    /// backslash sequences are interpreted. A single-quote itself cannot be
    /// safely represented inside a single-quoted string, so paths containing
    /// `'`, NUL, CR, or LF are rejected outright.
    static func quoteArgument(_ path: String) throws -> String {
        // Single-quote strings have no escape mechanism — reject chars that
        // cannot be safely represented or that would corrupt the command stream.
        if path.contains("'") || path.contains("\0") || path.contains("\r") || path.contains("\n") {
            throw QuotingError.unsupportedCharacters
        }
        return "'\(path)'"
    }

    enum QuotingError: Error, LocalizedError {
        case unsupportedCharacters
        var errorDescription: String? { "File name contains characters unsupported over SFTP (single-quote, NUL, CR, or LF)." }
    }
}
