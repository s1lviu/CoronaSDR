import Foundation
import SwiftData

/// Handles CSV/TSV import and export of Station data.
public struct CSVImportExport {
    /// CSV columns in order.
    private static let headers = ["name", "frequencyHz", "mode", "bandwidthHz", "stepHz", "squelch", "tags"]

    /// Export stations to CSV string.
    public static func exportCSV(stations: [Station], delimiter: Character = ",") -> String {
        var lines: [String] = []
        lines.append(headers.joined(separator: String(delimiter)))

        for station in stations {
            let tagNames = station.tags.map(\.name).joined(separator: ";")
            let fields = [
                escapeField(station.name, delimiter: delimiter),
                String(station.frequencyHz),
                station.modeRaw,
                String(station.bandwidthHz),
                String(station.stepHz),
                String(station.squelch),
                escapeField(tagNames, delimiter: delimiter),
            ]
            lines.append(fields.joined(separator: String(delimiter)))
        }

        return lines.joined(separator: "\n")
    }

    /// Parse CSV/TSV string into station data tuples. Does not create SwiftData objects.
    public static func parseCSV(_ content: String) -> [StationCSVRow] {
        let delimiter = detectDelimiter(content)
        let records = splitCSVRecords(content, delimiter: delimiter)
            .filter { record in
                record.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }

        guard !records.isEmpty else { return [] }
        let rowStartIndex = hasHeader(records[0]) ? 1 : 0
        guard rowStartIndex < records.count else { return [] }

        return records[rowStartIndex...].compactMap { fields in
            parseRow(fields)
        }
    }

    private static func detectDelimiter(_ content: String) -> Character {
        let firstLine = content.prefix(while: { $0 != "\n" && $0 != "\r" })
        if firstLine.contains("\t") { return "\t" }
        return ","
    }

    private static func parseRow(_ fields: [String]) -> StationCSVRow? {
        guard fields.count >= 3 else { return nil }

        let name = fields[0]
        guard let freq = Int(fields[1]) else { return nil }
        let mode = DemodMode(rawValue: fields[2]) ?? .nfm

        let bandwidth = fields.count > 3 ? Int(fields[3]) : nil
        let step = fields.count > 4 ? Int(fields[4]) : nil
        let squelch = fields.count > 5 ? Float(fields[5]) : nil
        let tagNames: [String] = fields.count > 6
            ? fields[6].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []

        return StationCSVRow(
            name: name,
            frequencyHz: freq,
            mode: mode,
            bandwidthHz: bandwidth ?? mode.defaultBandwidthHz,
            stepHz: step ?? mode.defaultStepHz,
            squelch: squelch ?? 0,
            tagNames: tagNames
        )
    }

    private static func hasHeader(_ fields: [String]) -> Bool {
        guard !fields.isEmpty else { return false }
        let normalized = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalized == headers.map { $0.lowercased() }
    }

    private static func splitCSVRecords(_ content: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var index = content.startIndex

        func appendField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }

        func appendRowIfNeeded() {
            if !row.isEmpty {
                records.append(row)
                row.removeAll(keepingCapacity: true)
            }
        }

        while index < content.endIndex {
            let char = content[index]

            if isInsideQuotes {
                if char == "\"" {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    field.append(char)
                }
                index = content.index(after: index)
                continue
            }

            if char == "\"" {
                isInsideQuotes = true
            } else if char == delimiter {
                appendField()
            } else if char == "\n" || char == "\r" {
                if char == "\r" {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "\n" {
                        index = next
                    }
                }
                appendField()
                appendRowIfNeeded()
            } else {
                field.append(char)
            }

            index = content.index(after: index)
        }

        appendField()
        appendRowIfNeeded()
        return records
    }

    private static func escapeField(_ value: String, delimiter: Character) -> String {
        if value.contains(delimiter) || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

/// Parsed CSV row before importing into SwiftData.
public struct StationCSVRow: Sendable {
    public let name: String
    public let frequencyHz: Int
    public let mode: DemodMode
    public let bandwidthHz: Int
    public let stepHz: Int
    public let squelch: Float
    public let tagNames: [String]
}
