import Foundation
import EventKit
import CoreLocation
import MapKit
import UIKit

final class CalendarService {
    static let shared = CalendarService()
    private init() {}
    
    private let store = EKEventStore()
    private let calendarName = "Расписание"
    
    func ensureAccess() async throws {
        try await store.requestFullAccessToEvents()
    }
    
    private func findOrCreateCalendar() throws -> EKCalendar {
        // 1) Уже существует?
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName }) {
            return existing
        }
        
        // 2) Выбираем источник
        let source = try pickBestSource()
        
        // 3) Создаём календарь
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = calendarName
        cal.source = source
        cal.cgColor = UIColor.systemBlue.cgColor
        try store.saveCalendar(cal, commit: true)
        return cal
    }
    
    private func pickBestSource() throws -> EKSource {
        // Если у системы есть дефолтный календарь — используем его источник
        if let defaultCal = store.defaultCalendarForNewEvents {
            return defaultCal.source
        }
        
        // Проверяем наличие «записываемых» источников
        let writableTypes: [EKSourceType] = [.calDAV, .exchange, .local]
        let writableSources = store.sources.filter { writableTypes.contains($0.sourceType) }
        if writableSources.isEmpty {
            // На симуляторе особенно частый кейс
            #if targetEnvironment(simulator)
            let hint = "Вы запускаете в Simulator. У симулятора часто нет календарных источников. Проверьте на реальном устройстве с включённым iCloud Календарём или добавленным аккаунтом."
            #else
            let hint = "Включите iCloud Календарь или добавьте аккаунт календарей в Настройки → Календарь → Аккаунты."
            #endif
            throw NSError(
                domain: "CalendarService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Не найден источник календарей. \(hint)"
                ]
            )
        }
        
        // Предпочитаемые типы источников (iCloud/CalDAV → Exchange → Local)
        let preferredOrder: [EKSourceType] = [.calDAV, .exchange, .local]
        for t in preferredOrder {
            if let s = writableSources.first(where: { $0.sourceType == t }) {
                return s
            }
        }
        
        // Fallback: источник любого существующего календаря событий
        if let anyCalSource = store.calendars(for: .event).first?.source {
            return anyCalSource
        }
        
        // Последний шанс — любой первый источник (из уже отфильтрованных writable)
        if let any = writableSources.first {
            return any
        }
        
        throw NSError(
            domain: "CalendarService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Не найден источник календарей. Включите iCloud Календарь или добавьте учётную запись календарей в настройках устройства."
            ]
        )
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
        
        // Геокод адреса один раз
        var coord: CLLocationCoordinate2D?
        if let addr = campusAddress, !addr.isEmpty {
            coord = try await geocode(address: addr)
        }
        
        for item in items {
            // Фильтр по подгруппам
            if subgroup == .one, item.subgroup == .two { continue }
            if subgroup == .two, item.subgroup == .one { continue }
            // Фильтр по чётности
            let parity = item.weekParity ?? weekParity
            let recurrenceWeeks = (parity == .none) ? 1 : 2
            
            // Первая дата
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
            
            // Повторяемость
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
            
            // Локация + "пора выходить"
            if let addr = campusAddress, !addr.isEmpty {
                let loc = EKStructuredLocation(title: addr)
                if let c = coord {
                    loc.geoLocation = CLLocation(latitude: c.latitude, longitude: c.longitude)
                }
                event.structuredLocation = loc
                if let offset = try? await TravelTimeService.shared.leaveNowOffset(to: coord, transport: transport) {
                    let alarm = EKAlarm(relativeOffset: -offset)
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
