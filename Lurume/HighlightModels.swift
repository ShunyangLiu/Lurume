import CoreGraphics
import Foundation

enum HighlightSchema {
    static let previousVersion = 1
    static let currentVersion = 2
}

struct HighlightRect: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(cgRect: CGRect) {
        let standardized = cgRect.standardized
        guard standardized.origin.x.isFinite,
              standardized.origin.y.isFinite,
              standardized.width.isFinite,
              standardized.height.isFinite,
              standardized.width > 0,
              standardized.height > 0 else {
            return nil
        }
        x = standardized.origin.x
        y = standardized.origin.y
        width = standardized.width
        height = standardized.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func approximatelyEquals(_ other: HighlightRect, tolerance: Double = 1) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let x = try values.decode(Double.self, forKey: .x)
        let y = try values.decode(Double.self, forKey: .y)
        let width = try values.decode(Double.self, forKey: .width)
        let height = try values.decode(Double.self, forKey: .height)
        guard let validated = HighlightRect(
            cgRect: CGRect(x: x, y: y, width: width, height: height)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: values,
                debugDescription: "高亮矩形包含非有限值或空尺寸。"
            )
        }
        self = validated
    }
}

struct HighlightPoint: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double

    init?(cgPoint: CGPoint) {
        guard cgPoint.x.isFinite, cgPoint.y.isFinite else { return nil }
        x = cgPoint.x
        y = cgPoint.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct HighlightSegment: Codable, Equatable, Hashable, Sendable {
    let pageIndex: Int
    let rects: [HighlightRect]

    init?(pageIndex: Int, rects: [HighlightRect]) {
        guard pageIndex >= 0, !rects.isEmpty else { return nil }
        self.pageIndex = pageIndex
        self.rects = rects
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pageIndex = try values.decode(Int.self, forKey: .pageIndex)
        let rects = try values.decode([HighlightRect].self, forKey: .rects)
        guard let validated = HighlightSegment(pageIndex: pageIndex, rects: rects) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rects,
                in: values,
                debugDescription: "高亮片段必须具有有效页码和至少一个矩形。"
            )
        }
        self = validated
    }
}

struct HighlightRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let paperID: UUID
    let rawText: String
    let createdAt: Date
    let segments: [HighlightSegment]
    let noteText: String?
    let noteModifiedAt: Date?
    let noteMarkerPosition: HighlightPoint?

    init?(
        id: UUID = UUID(),
        paperID: UUID,
        rawText: String,
        createdAt: Date = Date(),
        segments: [HighlightSegment],
        noteText: String? = nil,
        noteModifiedAt: Date? = nil,
        noteMarkerPosition: HighlightPoint? = nil
    ) {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !segments.isEmpty else {
            return nil
        }
        self.id = id
        self.paperID = paperID
        self.rawText = rawText
        self.createdAt = createdAt
        self.segments = segments
        let normalizedNote = Self.normalizedNote(noteText)
        self.noteText = normalizedNote
        self.noteModifiedAt = normalizedNote == nil ? nil : noteModifiedAt
        self.noteMarkerPosition = noteMarkerPosition
    }

    var startPageIndex: Int {
        segments.first?.pageIndex ?? 0
    }

    var endPageIndex: Int {
        segments.last?.pageIndex ?? startPageIndex
    }

    var pageLabel: String {
        if startPageIndex == endPageIndex {
            return "第 \(startPageIndex + 1) 页"
        }
        return "第 \(startPageIndex + 1)–\(endPageIndex + 1) 页"
    }

    var previewText: String {
        rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var hasNote: Bool {
        noteText != nil
    }

    func updatingNote(_ text: String?, modifiedAt: Date = Date()) -> HighlightRecord {
        // The current record has already passed validation, so reconstruction is safe.
        HighlightRecord(
            id: id,
            paperID: paperID,
            rawText: rawText,
            createdAt: createdAt,
            segments: segments,
            noteText: text,
            noteModifiedAt: modifiedAt,
            noteMarkerPosition: noteMarkerPosition
        )!
    }

    func updatingNoteMarkerPosition(_ position: HighlightPoint?) -> HighlightRecord {
        HighlightRecord(
            id: id,
            paperID: paperID,
            rawText: rawText,
            createdAt: createdAt,
            segments: segments,
            noteText: noteText,
            noteModifiedAt: noteModifiedAt,
            noteMarkerPosition: position
        )!
    }

    func approximatelyMatches(_ other: HighlightRecord, tolerance: Double = 1) -> Bool {
        guard paperID == other.paperID,
              segments.count == other.segments.count else {
            return false
        }
        return zip(segments, other.segments).allSatisfy { left, right in
            guard left.pageIndex == right.pageIndex,
                  left.rects.count == right.rects.count else {
                return false
            }
            return zip(left.rects, right.rects).allSatisfy {
                $0.approximatelyEquals($1, tolerance: tolerance)
            }
        }
    }

    func overlaps(_ other: HighlightRecord, minimumIntersection: Double = 0.5) -> Bool {
        guard paperID == other.paperID else { return false }
        for leftSegment in segments {
            for rightSegment in other.segments
            where leftSegment.pageIndex == rightSegment.pageIndex {
                for leftRect in leftSegment.rects {
                    for rightRect in rightSegment.rects {
                        let intersection = leftRect.cgRect.intersection(rightRect.cgRect)
                        if !intersection.isNull,
                           intersection.width > minimumIntersection,
                           intersection.height > minimumIntersection {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    static func documentOrdered(_ lhs: HighlightRecord, _ rhs: HighlightRecord) -> Bool {
        guard lhs.startPageIndex == rhs.startPageIndex else {
            return lhs.startPageIndex < rhs.startPageIndex
        }
        let leftRect = lhs.segments.first?.rects.first
        let rightRect = rhs.segments.first?.rects.first
        guard let leftRect, let rightRect else {
            return lhs.createdAt < rhs.createdAt
        }
        if abs(leftRect.y - rightRect.y) > 1 {
            return leftRect.y > rightRect.y
        }
        if abs(leftRect.x - rightRect.x) > 1 {
            return leftRect.x < rightRect.x
        }
        return lhs.createdAt < rhs.createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let paperID = try values.decode(UUID.self, forKey: .paperID)
        let rawText = try values.decode(String.self, forKey: .rawText)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let segments = try values.decode([HighlightSegment].self, forKey: .segments)
        let noteText = try values.decodeIfPresent(String.self, forKey: .noteText)
        let noteModifiedAt = try values.decodeIfPresent(Date.self, forKey: .noteModifiedAt)
        let noteMarkerPosition = try values.decodeIfPresent(
            HighlightPoint.self,
            forKey: .noteMarkerPosition
        )
        guard let validated = HighlightRecord(
            id: id,
            paperID: paperID,
            rawText: rawText,
            createdAt: createdAt,
            segments: segments,
            noteText: noteText,
            noteModifiedAt: noteModifiedAt,
            noteMarkerPosition: noteMarkerPosition
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .segments,
                in: values,
                debugDescription: "高亮必须包含原文和至少一个有效片段。"
            )
        }
        self = validated
    }

    private static func normalizedNote(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

struct HighlightSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var highlights: [HighlightRecord]

    static let empty = HighlightSnapshot(
        schemaVersion: HighlightSchema.currentVersion,
        highlights: []
    )
}
