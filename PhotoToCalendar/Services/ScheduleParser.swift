//
//  ScheduleParser.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import CoreGraphics

enum ScheduleParser {
    // Парсим по позициям строк с устойчивостью к перемешанным кускам:
    // 1) Кластеризуем строки в "ряды" по Y.
    // 2) Внутри ряда сортируем по X.
    // 3) Находим якоря времени, включая формат "<день> HH:MM bis HH:MM" (в т.ч. несколько в одной строке).
    // 4) Ищем заголовки дней и применяем их к последующим рядам.
    // 5) Для каждого якоря собираем контекст: сверху (несколько рядов), справа в том же ряду и несколько рядов ниже до следующего якоря.
    static func parsePositioned(lines: [OCRLine]) -> [ScheduleItem] {
        guard !lines.isEmpty else { return [] }
        
        // 0) Предварительная сортировка по Y (сверху-вниз), затем по X
        let sorted = lines.sorted {
            if abs($0.rect.midY - $1.rect.midY) > 0.0001 {
                return $0.rect.midY > $1.rect.midY
            } else {
                return $0.rect.minX < $1.rect.minX
            }
        }
        
        // 1) Кластеризация по Y в "ряды"
        let yTol: CGFloat = 0.02 // допуск по вертикали (2% высоты)
        var rows: [[OCRLine]] = []
        for l in sorted {
            if let idx = rows.firstIndex(where: { row in
                guard let any = row.first else { return false }
                return abs(any.rect.midY - l.rect.midY) <= yTol
            }) {
                rows[idx].append(l)
            } else {
                rows.append([l])
            }
        }
        // Сортируем внутри ряда по X
        rows = rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
        
        // 2) Найти якоря времени по рядам
        struct TimeAnchor {
            let rowIndex: Int
            let lineIndexInRow: Int
            let start: DateComponents
            let end: DateComponents
            let line: OCRLine
            let weekdayHint: Int? // если формат "Di 13:20 bis 15:45" — здесь будет день
        }
        var anchors: [TimeAnchor] = []
        for (ri, row) in rows.enumerated() {
            for (ci, l) in row.enumerated() {
                // Сначала ищем несколько пар "<день> время bis время" в одной строке
                let pairs = extractWeekdayTimePairs(l.text)
                if !pairs.isEmpty {
                    for p in pairs {
                        anchors.append(TimeAnchor(rowIndex: ri, lineIndexInRow: ci, start: p.start, end: p.end, line: l, weekdayHint: p.weekday))
                    }
                    continue
                }
                // Обычный формат "HH:MM- HH:MM"
                if let (s,e) = extractTime(l.text) {
                    anchors.append(TimeAnchor(rowIndex: ri, lineIndexInRow: ci, start: s, end: e, line: l, weekdayHint: nil))
                }
            }
        }
        guard !anchors.isEmpty else { return [] }
        anchors.sort { a, b in
            if a.rowIndex != b.rowIndex { return a.rowIndex < b.rowIndex } // сверху-вниз по индексам рядов
            return a.line.rect.minX < b.line.rect.minX
        }
        
        // 3) Карта заголовков дней: определяем день недели для ряда (если есть строка без времени с названием дня)
        var rowWeekday: [Int:Int] = [:] // rowIndex -> weekday
        var currentWeekday: Int? = nil
        for (ri, row) in rows.enumerated() {
            // если в ряду есть время — это не заголовок дня
            let hasTimeInRow = row.contains { extractTime($0.text) != nil || !extractWeekdayTimePairs($0.text).isEmpty }
            if hasTimeInRow {
                // применяем текущий weekday к этому ряду (если есть)
                if let wd = currentWeekday {
                    rowWeekday[ri] = wd
                }
                continue
            }
            // ищем weekday в строках ряда
            var found: Int? = nil
            for l in row {
                if let wd = extractWeekday(l.text) {
                    found = wd
                    break
                }
            }
            if let wd = found {
                currentWeekday = wd
                rowWeekday[ri] = wd
            } else if let wd = currentWeekday {
                // ряд без времени, но между заголовком и парами — наследуем
                rowWeekday[ri] = wd
            }
        }
        
        // 4) Строим элементы на основе якорей
        var items: [ScheduleItem] = []
        
        // Помощник: собрать блок контекста для якоря
        func contextBlock(for anchorIndex: Int) -> (above: [OCRLine], sameRowRight: [OCRLine], below: [OCRLine]) {
            let anchor = anchors[anchorIndex]
            let startRow = anchor.rowIndex
            
            // 4.1) В той же строке: все куски справа от времени
            let sameRowRight: [OCRLine] = rows[startRow].filter {
                if $0.text == anchor.line.text { return false }
                return $0.rect.minX >= anchor.line.rect.maxX - 0.002
            }
            
            // 4.2) Ряды ВЫШЕ (до 2 рядов), если там нет времени
            let maxRowsLookback = 2
            var above: [OCRLine] = []
            if startRow > 0 {
                let lower = max(0, startRow - maxRowsLookback)
                for ri in stride(from: startRow - 1, through: lower, by: -1) {
                    // безопасная проверка индекса
                    guard rows.indices.contains(ri) else { continue }
                    let rowHasTime = rows[ri].contains { extractTime($0.text) != nil || !extractWeekdayTimePairs($0.text).isEmpty }
                    if rowHasTime { break } // другой якорь выше — стоп
                    above.append(contentsOf: rows[ri])
                }
            }
            
            // 4.3) Несколько рядов ниже до следующего якоря (или пока не встретим ряд с временем)
            let nextRowLimit: Int = {
                if anchorIndex + 1 < anchors.count {
                    return anchors[anchorIndex + 1].rowIndex
                } else {
                    return rows.count
                }
            }()
            let maxRowsLookahead = 6 // ограничим "вниз" 6 рядами
            let lowerBound = startRow + 1
            let upperBound = min(nextRowLimit, startRow + 1 + maxRowsLookahead)
            var below: [OCRLine] = []
            if lowerBound < upperBound {
                for ri in lowerBound..<upperBound {
                    // безопасная проверка индекса
                    guard rows.indices.contains(ri) else { continue }
                    let rowHasTime = rows[ri].contains { extractTime($0.text) != nil || !extractWeekdayTimePairs($0.text).isEmpty }
                    if rowHasTime { break }
                    below.append(contentsOf: rows[ri])
                }
            }
            
            // Убираем дубли в каждом массиве
            func uniq(_ arr: [OCRLine]) -> [OCRLine] {
                var res: [OCRLine] = []
                for l in arr where !res.contains(l) { res.append(l) }
                return res
            }
            return (uniq(above), uniq(sameRowRight), uniq(below))
        }
        
        for (idx, anchor) in anchors.enumerated() {
            var title: String = "Занятие"
            var teacher: String?
            var room: String?
            var subgroup: Subgroup?
            var parity: WeekParity?
            var weekday: Int? = anchor.weekdayHint ?? rowWeekday[anchor.rowIndex]
            
            // Попробуем взять заголовок прямо из строки с временем (после времени) — для обычного формата
            if anchor.weekdayHint == nil, let t = extractTitle(from: anchor.line.text), !t.isEmpty {
                title = t
            }
            
            // Собираем контекст
            let ctx = contextBlock(for: idx)
            
            // 4.a) Приоритет — заголовок в ряду ВЫШЕ (частый случай: название над временем)
            if title == "Занятие" {
                let aboveTitle = ctx.above
                    .filter { extractTime($0.text) == nil && extractWeekdayTimePairs($0.text).isEmpty && !looksLikeTeacher($0.text) && extractRoom($0.text) == nil && !looksLikeMeta($0.text) }
                    .max(by: { $0.text.count < $1.text.count })?.text
                if let t = aboveTitle, !t.isEmpty {
                    title = t
                }
            }
            
            // 4.b) Если всё ещё нет — пытаемся собрать из кусков справа в той же строке
            if title == "Занятие" {
                let sameRowJoined = ctx.sameRowRight.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !sameRowJoined.isEmpty, !looksLikeMeta(sameRowJoined) {
                    title = sameRowJoined
                }
            }
            
            // 4.c) Если всё ещё нет — лучший кандидат снизу
            if title == "Занятие" {
                let candidate = ctx.below
                    .filter { extractTime($0.text) == nil && extractWeekdayTimePairs($0.text).isEmpty && !looksLikeTeacher($0.text) && extractRoom($0.text) == nil && !looksLikeMeta($0.text) }
                    .max(by: { $0.text.count < $1.text.count })?.text
                if let c = candidate, !c.isEmpty {
                    title = c
                }
            }
            
            // Остальные поля: собираем из всего контекста (сверху/справа/снизу)
            let allContext = ctx.above + ctx.sameRowRight + ctx.below
            for l in allContext {
                let t = l.text
                if teacher == nil, looksLikeTeacher(t) { teacher = t; continue }
                if room == nil, let r = extractRoom(t) { room = r; continue }
                if subgroup == nil, let s = extractSubgroup(t) { subgroup = s; continue }
                if parity == nil, let p = extractParity(t) { parity = p; continue }
                if weekday == nil, let wd = extractWeekday(t) { weekday = wd; continue }
            }
            
            // Пост-валидация: end > start
            let sH = anchor.start.hour ?? 0
            let sM = anchor.start.minute ?? 0
            let eH = anchor.end.hour ?? 0
            let eM = anchor.end.minute ?? 0
            let startMinutes = sH * 60 + sM
            let endMinutes = eH * 60 + eM
            if endMinutes <= startMinutes {
                continue
            }
            
            let item = ScheduleItem(title: title,
                                    teacher: teacher,
                                    room: room,
                                    start: anchor.start,
                                    end: anchor.end,
                                    weekday: weekday,
                                    subgroup: subgroup,
                                    weekParity: parity)
            items.append(item)
        }
        
        // Дедупликация
        var unique: [ScheduleItem] = []
        var seen = Set<String>()
        for it in items {
            let key = "\(it.title.lowercased())|\(it.teacher ?? "")|\(it.room ?? "")|\(it.start.hour ?? -1):\(it.start.minute ?? -1)|\(it.end.hour ?? -1):\(it.end.minute ?? -1)|\(it.weekday ?? -1)|\(it.subgroup?.rawValue ?? "")|\(it.weekParity?.rawValue ?? "")"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(it)
            }
        }
        return unique
    }
    
    // Старый метод — на случай, когда нет позиций
    static func parse(lines: [String]) -> [ScheduleItem] {
        var items: [ScheduleItem] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Сначала — немецкие пары по дням
            let pairs = extractWeekdayTimePairs(line)
            if !pairs.isEmpty {
                for p in pairs {
                    let item = ScheduleItem(title: "Занятие",
                                            teacher: nil,
                                            room: nil,
                                            start: p.start,
                                            end: p.end,
                                            weekday: p.weekday,
                                            subgroup: nil,
                                            weekParity: nil)
                    items.append(item)
                }
                i += 1
                continue
            }
            // Обычное время
            if let (start, end) = extractTime(line) {
                var title = extractTitle(from: line) ?? "Занятие"
                var teacher: String?
                var room: String?
                var weekParity: WeekParity?
                var subgroup: Subgroup?
                var weekday: Int?
                
                var j = i + 1
                while j < min(lines.count, i + 8) {
                    let extra = lines[j]
                    if teacher == nil, looksLikeTeacher(extra) { teacher = extra }
                    if room == nil, let r = extractRoom(extra) { room = r }
                    if weekParity == nil, let p = extractParity(extra) { weekParity = p }
                    if subgroup == nil, let s = extractSubgroup(extra) { subgroup = s }
                    if let wd = extractWeekday(extra) { weekday = wd }
                    if title == "Занятие", !looksLikeMeta(extra), extractTime(extra) == nil, extractWeekdayTimePairs(extra).isEmpty {
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
    
    // MARK: - Helpers
    
    // Извлекает несколько пар "<день> HH:MM bis HH:MM" из строки.
    // Поддерживает немецкие сокращения дней: Mo, Di, Mi, Do, Fr, Sa, So (регистр не важен), разделители "," и ";"
    struct WeekdayTimePair {
        let weekday: Int
        let start: DateComponents
        let end: DateComponents
    }
    static func extractWeekdayTimePairs(_ s: String) -> [WeekdayTimePair] {
        // Примеры: "Di 13:20 bis 15:45", "Fr 10:40 bis 13:05"
        // Допускаем "." вместо ":" в времени
        let pattern = #"(?i)\b(Mo|Di|Mi|Do|Fr|Sa|So)\b[^0-9]*([01]?\d|2[0-3])[:\.]([0-5]\d)\s*(?:bis|[\-–—])\s*([01]?\d|2[0-3])[:\.]([0-5]\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var result: [WeekdayTimePair] = []
        for m in matches {
            guard m.numberOfRanges == 6 else { continue }
            let dayStr = ns.substring(with: m.range(at: 1)).lowercased()
            guard let wd = weekdayFromShortGerman(dayStr) else { continue }
            let sh = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let sm = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let eh = Int(ns.substring(with: m.range(at: 4))) ?? 0
            let em = Int(ns.substring(with: m.range(at: 5))) ?? 0
            let start = DateComponents(hour: sh, minute: sm)
            let end = DateComponents(hour: eh, minute: em)
            result.append(WeekdayTimePair(weekday: wd, start: start, end: end))
        }
        return result
    }
    
    private static func weekdayFromShortGerman(_ s: String) -> Int? {
        switch s.lowercased() {
        case "mo": return 2
        case "di": return 3
        case "mi": return 4
        case "do": return 5
        case "fr": return 6
        case "sa": return 7
        case "so": return 1
        default: return nil
        }
    }
    
    // Расширенный парсер времени: поддерживает 9:00, 9.00, 09-30, тире/минус/длинное тире
    static func extractTime(_ s: String) -> (DateComponents, DateComponents)? {
        let pattern = #"(?<!\d)([01]?\d|2[0-3])[:\.]([0-5]\d)\s*[\-–—]\s*([01]?\d|2[0-3])[:\.]([0-5]\d)(?!\d)"#
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(s[r])
        // нормализуем разделители
        let norm = match.replacingOccurrences(of: "–", with: "-")
                         .replacingOccurrences(of: "—", with: "-")
                         .replacingOccurrences(of: ".", with: ":")
                         .replacingOccurrences(of: " ", with: "")
        let parts = norm.split(separator: "-")
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
        if let range = s.range(of: #"^\s*([01]?\d|2[0-3])[:\.][0-5]\d\s*[\-–—]\s*([01]?\d|2[0-3])[:\.][0-5]\d\s*"#, options: .regularExpression) {
            let rest = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : String(rest)
        }
        return nil
    }
    
    static func looksLikeTeacher(_ s: String) -> Bool {
        // 1) Фамилия + инициалы (рус)
        if s.range(of: #"[А-ЯA-Z][А-Яа-яA-Za-z\-]+(\s+[А-ЯA-Z]\.[А-ЯA-Z]\.)"#, options: .regularExpression) != nil {
            return true
        }
        // 2) Академические титулы + латиница (Dr., Prof.)
        if s.range(of: #"(?i)\b(dr|prof)\.?\b"#, options: .regularExpression) != nil {
            return true
        }
        // 3) Простая форма "Фамилия Имя" латиницей c заглавных
        if s.range(of: #"\b[A-ZÄÖÜ][A-Za-zÄÖÜäöüß\-]+(?:\s+[A-ZÄÖÜ][A-Za-zÄÖÜäöüß\-]+)+"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
    
    static func extractRoom(_ s: String) -> String? {
        // "Ауд. 304", "каб. 23", "room 12"
        if let r = s.range(of: #"(?i)\b(ауд\.?|каб\.?|room|aud)\b\s*[:#]?\s*([0-9A-Za-z\-]+)"#, options: .regularExpression) {
            let sub = String(s[r])
            if let last = sub.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "#" }).last {
                return String(last)
            }
        }
        // Просто число в конце строки "... 304"
        if let r = s.range(of: #"[ \t](\d{2,5})$"#, options: .regularExpression) {
            return String(s[r]).trimmingCharacters(in: .whitespaces)
        }
        // Строка — только номер аудитории: "304"
        if s.range(of: #"^\d{2,5}$"#, options: .regularExpression) != nil {
            return s
        }
        return nil
    }
    
    static func extractParity(_ s: String) -> WeekParity? {
        let low = s.lowercased()
        if low.contains("неделя 1") || low.contains("нед. 1") || low.contains("неч") || low.contains("odd") || low.contains("ungerade") {
            return .odd
        }
        if low.contains("неделя 2") || low.contains("нед. 2") || low.contains("чет") || low.contains("even") || low.contains("gerade") {
            return .even
        }
        return nil
    }
    
    static func extractSubgroup(_ s: String) -> Subgroup? {
        let low = s.lowercased()
        // “1 п/г”, “подгр. 1”, “1 пг”, “подгруппа 1”
        if low.range(of: #"(?i)\b(1)\s*(п\/?г|подг(руппа)?|pg)\b"#, options: .regularExpression) != nil { return .one }
        if low.range(of: #"(?i)\b(2)\s*(п\/?г|подг(руппа)?|pg)\b"#, options: .regularExpression) != nil { return .two }
        if low == "1" { return .one }
        if low == "2" { return .two }
        return nil
    }
    
    static func extractWeekday(_ s: String) -> Int? {
        let low = s.lowercased()
        let map: [String:Int] = [
            "понедельник": 2, "вторник": 3, "среда": 4, "четверг": 5, "пятница": 6, "суббота": 7, "воскрес": 1,
            "пн": 2, "вт": 3, "ср": 4, "чт": 5, "пт": 6, "сб": 7, "вс": 1,
            "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1,
            "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1,
            // Немецкие полные и сокращённые
            "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonntag": 1,
            "mo": 2, "di": 3, "mi": 4, "do": 5, "fr": 6, "sa": 7, "so": 1
        ]
        for (k,v) in map where low.contains(k) { return v }
        return nil
    }
    
    static func looksLikeMeta(_ s: String) -> Bool {
        let low = s.lowercased()
        // фильтр явных “шапок”
        return low.contains("дисциплина") || low.contains("преподаватель") || low.contains("ауд") || low.contains("кафедра") || low.contains("перерыв")
    }
}
