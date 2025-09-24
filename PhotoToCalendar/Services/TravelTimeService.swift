//
//  TravelTimeService.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import Foundation
import CoreLocation
import MapKit

final class TravelTimeService {
    static let shared = TravelTimeService()
    private init() {}
    
    // Returns ETA seconds; if coordinate is nil, returns default 600 (10 min)
    func leaveNowOffset(to destination: CLLocationCoordinate2D?, transport: TransportMode) async throws -> TimeInterval {
        guard let dest = destination else { return 10 * 60 }
        let manager = CLLocationManager()
        let auth = manager.authorizationStatus
        if auth == .notDetermined { await MainActor.run { LocationService.shared.requestWhenInUse() } }
        let start = await LocationService.shared.currentLocation()
        guard let startLoc = start else { return 10 * 60 }
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: startLoc.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        request.transportType = (transport == .walking) ? .walking : .transit
        request.departureDate = Date() // now
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        // Pick the first route
        if let route = response.routes.first {
            // add 5 minutes buffer
            return max(route.expectedTravelTime + 5*60, 5*60)
        }
        return 10 * 60
    }
}


