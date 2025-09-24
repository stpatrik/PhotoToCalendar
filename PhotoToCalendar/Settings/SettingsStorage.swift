//
//  SettingsStorage.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import SwiftUI

enum SettingsStorage {
    static func saveSemesterEnd(_ date: Date?) {
        let key = "semesterEndISO8601"
        if let date {
            UserDefaults.standard.set(ISO8601DateFormatter().string(from: date), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
