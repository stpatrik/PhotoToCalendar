//
//  ScheduleModels.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import CoreLocation
import CoreGraphics

// Строка OCR с позицией (rect в нормализованных координатах Vision: (0,0)-(1,1))
struct OCRLine: Hashable {
    var text: String
    var rect: CGRect
}

enum ScheduleKind: String, Codable, CaseIterable {
    case singleDay
    case weekly
}

enum WeekParity: String, Codable, CaseIterable {
    case none
    case even
    case odd
}

enum Subgroup: String, Codable, CaseIterable {
    case ask
    case one
    case two
    case both
}

enum TransportMode: String, Codable, CaseIterable {
    case walking
    case transit
}

struct ScheduleItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var teacher: String?
    var room: String?
    var start: DateComponents // only hour/minute used
    var end: DateComponents   // only hour/minute used
    var weekday: Int?         // 1..7 (Mon=2 in Apple)
    var subgroup: Subgroup?
    var weekParity: WeekParity?
}

struct ParsedEvent {
    var title: String
    var notes: String?
    var startDate: Date
    var endDate: Date
    var recurrenceWeeks: Int? // 1 or 2
    var recurrenceEnd: Date?
    var structuredAddress: String?
    var locationCoordinate: CLLocationCoordinate2D?
    var transport: TransportMode
}

struct ImportResult {
    var addedCount: Int
    var skippedCount: Int
}
