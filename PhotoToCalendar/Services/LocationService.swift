//
//  LocationService.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private override init() {}
    
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    
    func requestWhenInUse() {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
    
    func currentLocation() async -> CLLocation? {
        manager.delegate = self
        manager.requestLocation()
        return await withCheckedContinuation { cont in
            continuation = cont
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.last)
        continuation = nil
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
