//
//  DateParsing.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation

enum DateParsing {
    static func nextWorkingDay(from date: Date) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        var d = date
        while !cal.isDateInWeekend(d) && cal.component(.weekday, from: d) != 1 {
            // if today is weekday and before end of day, pick tomorrow
            if cal.isDateInToday(d) { d = cal.date(byAdding: .day, value: 1, to: d)!; break }
            break
        }
        // ensure Mon-Fri
        var wd = cal.component(.weekday, from: d)
        if wd == 7 { // Saturday -> Monday
            return cal.nextDate(after: d, matching: DateComponents(weekday: 2), matchingPolicy: .nextTimePreservingSmallerComponents) ?? d
        }
        if wd == 1 { // Sunday -> Monday
            return cal.nextDate(after: d, matching: DateComponents(weekday: 2), matchingPolicy: .nextTimePreservingSmallerComponents) ?? d
        }
        return d
    }
    
    static func nextMonday(from date: Date) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let wd = cal.component(.weekday, from: date)
        if wd == 2 {
            return cal.startOfDay(for: date)
        } else {
            return cal.nextDate(after: date, matching: DateComponents(weekday: 2), matchingPolicy: .nextTimePreservingSmallerComponents) ?? cal.startOfDay(for: date)
        }
    }
    
    static func addWeeks(_ w: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: w, to: date) ?? date
    }
    
    static func hhmm(_ dc: DateComponents) -> String {
        let h = dc.hour ?? 0
        let m = dc.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }
    
    static func weekdayName(_ wd: Int) -> String {
        switch wd {
        case 2: return "Пн"
        case 3: return "Вт"
        case 4: return "Ср"
        case 5: return "Чт"
        case 6: return "Пт"
        case 7: return "Сб"
        case 1: return "Вс"
        default: return "-"
        }
    }
}
