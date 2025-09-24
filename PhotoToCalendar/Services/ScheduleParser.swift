//
//  ScheduleParser.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import CoreGraphics

enum ScheduleParser {
    // Новый основной метод: парсим по позициям строк
    static func parsePositioned(lines: [OCRLine]) -> [ScheduleItem] {
        // 1) Выделяем все строки со временем (HH:mm-HH:mm)
        let timeLines = lines.compactMap { line -> (OCRLine, DateComponents, DateComponents)? in
            guard let (s, e) = extractTime(line.text) else { return nil }
            return (line, s, e)
        }
        guard !timeLines.isEmpty else { return [] }
        
        var items: [ScheduleItem] = []
        
        // Допуск по вертикали: строки одной “дорожки” таблицы имеют близкий midY
        let yTolerance: CGFloat = 0.02
        
        for (timeLine, start, end) in timeLines {
            // 2) Берём все строки, чей midY близок к времени — это содержимое той же строки таблицы
            let bandMidY = timeLine.rect.midY
            let sameRow = lines.filter { abs($0.rect.midY - bandMidY) <= yTolerance }
                .sorted { $0.rect.minX < $1.rect.minX }
            
            // 3) Из этих строк убираем саму строку времени и любые “мета”-заголовки
            let candidates = sameRow.filter { $0.text != timeLine.text && !looksLikeMeta($0.text) }
            
            // 4) Определяем поля
            var title: String = "Занятие"
            var teacher: String?
            var room: String?
            var subgroup: Subgroup?
            var weekParity: WeekParity?
            var weekday: Int?
            
            for c in candidates {
                if teacher == nil, looksLikeTeacher(c.text) { teacher = c.text; continue }
                if room == nil, let r = extractRoom(c.text) { room = r; continue }
                if subgroup == nil, let s = extractSubgroup(c.text) { subgroup = s; continue }
                if weekParity == nil, let p = extractParity(c.text) { weekParity = p; continue }
                if weekday == nil, let wd = extractWeekday(c.text) { weekday = wd; continue }
            }
            // Заголовок — самая длинная строка, которая не время/не meta/не преподаватель/не аудитория
            let titleCandidate = candidates
                .filter { extractTime($0.text) == nil && !looksLikeTeacher($0.text) && extractRoom($0.text) == nil }
                .max(by: { $0.text.count < $1.text.count })?.text
            if let t = titleCandidate, !t.isEmpty { title = t }
            
            let item = ScheduleItem(title: title,
                                    teacher: teacher,
                                    room: room,
                                    start: start,
                                    end: end,
                                    weekday: weekday,
                                    subgroup: subgroup,
                                    weekParity: weekParity)
            items.append(item)
        }
        return items
    }
    
    // Старый метод — оставим как запасной (когда нет позиций)
    static func parse(lines: [String]) -> [ScheduleItem] {
        var items: [ScheduleItem] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let (start, end) = extractTime(line) {
                var title = extractTitle(from: line) ?? "Занятие"
                var teacher: String?
                var room: String?
                var weekParity: WeekParity?
                var subgroup: Subgroup?
                var weekday: Int?
                
                var j = i + 1
                while j < min(lines.count, i + 6) {
                    let extra = lines[j]
                    if teacher == nil, looksLikeTeacher(extra) { teacher = extra }
                    if room == nil, let r = extractRoom(extra) { room = r }
                    if weekParity == nil, let p = extractParity(extra) { weekParity = p }
                    if subgroup == nil, let s = extractSubgroup(extra) { subgroup = s }
                    if let wd = extractWeekday(extra) { weekday = wd }
                    if title == "Занятие", !looksLikeMeta(extra), extractTime(extra) == nil {
                        title = extra
                    }
                    j += 1
                }
                
                let item = ScheduleItem(title: title,
                                        teacher: teacher,
                                        room: room,
                                        start: start,
                                        end: end,
                                        weekday: weekday,
                                        subgroup: subgroup,
                                        weekParity: weekParity)
                items.append(item)
            }
            i += 1
        }
        return items
    }
    
    // MARK: - Helpers (без изменений, кроме публичности)
    static func extractTime(_ s: String) -> (DateComponents, DateComponents)? {
        let pattern = #"(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})"#
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let str = String(s[r])
        let parts = str.replacingOccurrences(of: " ", with: "").split(separator: "-")
        guard parts.count == 2 else { return nil }
        func toDC(_ part: Substring) -> DateComponents? {
            let hm = part.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
            return DateComponents(hour: h, minute: m)
        }
        if let s1 = toDC(parts[0]), let s2 = toDC(parts[1]) {
            return (s1, s2)
        }
        return nil
    }
    
    static func extractTitle(from s: String) -> String? {
        if let range = s.range(of: #"^\s*\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}\s*"#, options: .regularExpression) {
            let rest = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : String(rest)
        }
        return nil
    }
    
    static func looksLikeTeacher(_ s: String) -> Bool {
        s.range(of: #"[А-ЯA-Z][а-яa-z\-]+(\s+[А-ЯA-Z]\.[А-ЯA-Z]\.)"#, options: .regularExpression) != nil
    }
    
    static func extractRoom(_ s: String) -> String? {
        if let r = s.range(of: #"(Ауд\.?|Ауд|Каб\.?|Каб|каб\.?|ауд\.?)\s*([0-9A-Za-z\-]+)"#, options: .regularExpression) {
            let sub = String(s[r])
            if let last = sub.split(separator: " ").last {
                return String(last)
            }
        }
        if let r = s.range(of: #"[ \t](\d{2,4})$"#, options: .regularExpression) {
            return String(s[r]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    
    static func extractParity(_ s: String) -> WeekParity? {
        let low = s.lowercased()
        if low.contains("неделя 1") || low.contains("неч") || low.contains("odd") || low.contains("ungerade") {
            return .odd
        }
        if low.contains("неделя 2") || low.contains("чет") || low.contains("even") || low.contains("gerade") {
            return .even
        }
        return nil
    }
    
    static func extractSubgroup(_ s: String) -> Subgroup? {
        let low = s.lowercased()
        if low.contains("подгруппа: 1") || low.contains("подгр. 1") || low == "1" { return .one }
        if low.contains("подгруппа: 2") || low.contains("подгр. 2") || low == "2" { return .two }
        return nil
    }
    
    static func extractWeekday(_ s: String) -> Int? {
        let low = s.lowercased()
        let map: [String:Int] = [
            "понедельник": 2, "вторник": 3, "среда": 4, "четверг": 5, "пятница": 6, "суббота": 7, "воскрес": 1,
            "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1,
            "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonntag": 1
        ]
        for (k,v) in map where low.contains(k) { return v }
        return nil
    }
    
    static func looksLikeMeta(_ s: String) -> Bool {
        let low = s.lowercased()
        return low.contains("дисциплина") || low.contains("преподаватель") || low.contains("ауд")
    }
}
