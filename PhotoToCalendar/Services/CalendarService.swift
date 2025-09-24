import Foundation
import EventKit
import CoreLocation
import MapKit
import UIKit // нужно для UIColor.systemBlue

final class CalendarService {
    static let shared = CalendarService()
    private init() {}
    
    private let store = EKEventStore()
    private let calendarName = "Расписание"
    
    func ensureAccess() async throws {
        try await store.requestFullAccessToEvents()
    }
    
    private func findOrCreateCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV }) else {
            throw NSError(domain: "CalendarService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден источник календарей"])
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = calendarName
        cal.source = source
        cal.cgColor = UIColor.systemBlue.cgColor
        try store.saveCalendar(cal, commit: true)
        return cal
    }
    
    func importSchedule(items: [ScheduleItem],
                        scheduleKind: ScheduleKind,
                        weekParity: WeekParity,
                        subgroup: Subgroup,
                        startAnchor: Date,
                        repeatUntil: Date?,
                        campusAddress: String?,
                        transport: TransportMode) async throws -> ImportResult {
        try await ensureAccess()
        let calendar = try findOrCreateCalendar()
        
        var added = 0
        var skipped = 0
        
        // Geocode campus address once
        var coord: CLLocationCoordinate2D?
        if let addr = campusAddress, !addr.isEmpty {
            coord = try await geocode(address: addr)
        }
        
        for item in items {
            // Subgroup filtering
            if subgroup == .one, item.subgroup == .two { continue }
            if subgroup == .two, item.subgroup == .one { continue }
            // Parity filtering
            let parity = item.weekParity ?? weekParity
            let recurrenceWeeks = (parity == .none) ? 1 : 2
            
            // Build start/end date for first occurrence
            guard let (startDate, endDate) = Self.firstOccurrence(for: item,
                                                                  scheduleKind: scheduleKind,
                                                                  startAnchor: startAnchor) else {
                skipped += 1
                continue
            }
            
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = item.title
            var notes: [String] = []
            if let teacher = item.teacher, !teacher.isEmpty { notes.append(teacher) }
            if let room = item.room, !room.isEmpty { notes.append("Ауд.: \(room)") }
            event.notes = notes.isEmpty ? nil : notes.joined(separator: "\n")
            event.startDate = startDate
            event.endDate = endDate
            
            // Recurrence
            let rule = EKRecurrenceRule(recurrenceWith: .weekly,
                                        interval: recurrenceWeeks,
                                        daysOfTheWeek: nil,
                                        daysOfTheMonth: nil,
                                        monthsOfTheYear: nil,
                                        weeksOfTheYear: nil,
                                        daysOfTheYear: nil,
                                        setPositions: nil,
                                        end: repeatUntil.map { EKRecurrenceEnd(end: $0) })
            event.addRecurrenceRule(rule)
            
            // Location + "time to leave" via ETA alarm
            if let addr = campusAddress, !addr.isEmpty {
                let loc = EKStructuredLocation(title: addr)
                if let c = coord {
                    loc.geoLocation = CLLocation(latitude: c.latitude, longitude: c.longitude)
                }
                event.structuredLocation = loc
                if let offset = try? await TravelTimeService.shared.leaveNowOffset(to: coord, transport: transport) {
                    let alarm = EKAlarm(relativeOffset: -offset) // seconds before start
                    event.addAlarm(alarm)
                }
            }
            
            do {
                try store.save(event, span: .thisEvent, commit: false)
                added += 1
            } catch {
                skipped += 1
            }
        }
        try store.commit()
        return ImportResult(addedCount: added, skippedCount: skipped)
    }
    
    private static func firstOccurrence(for item: ScheduleItem,
                                        scheduleKind: ScheduleKind,
                                        startAnchor: Date) -> (Date, Date)? {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let dayBase: Date
        switch scheduleKind {
        case .singleDay:
            dayBase = startAnchor
        case .weekly:
            if let wd = item.weekday {
                dayBase = cal.date(byAdding: .day, value: (wd - 2), to: startAnchor) ?? startAnchor
            } else {
                dayBase = startAnchor
            }
        }
        guard let start = cal.date(bySettingHour: item.start.hour ?? 0, minute: item.start.minute ?? 0, second: 0, of: dayBase),
              let end = cal.date(bySettingHour: item.end.hour ?? 0, minute: item.end.minute ?? 0, second: 0, of: dayBase) else { return nil }
        return (start, end)
    }
    
    private func geocode(address: String) async throws -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.geocodeAddressString(address)
        return placemarks.first?.location?.coordinate
    }
}
