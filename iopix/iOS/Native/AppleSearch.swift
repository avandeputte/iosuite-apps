import MapKit

/// Address and place search for the location screens, with Apple's own search (free, no key). The web app keeps
/// iopix's server search (Google, then OpenStreetMap).
enum AppleSearch {
    struct Place { let name: String; let detail: String; let lat: Double; let lon: Double }

    static func places(_ query: String) async throws -> [Place] {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        r.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: r).start()
        return response.mapItems.prefix(12).map { item in
            let p = item.placemark
            let name = item.name ?? p.locality ?? query
            // where it is, without repeating the name: "Pittsburgh, PA, United States"
            let detail = [p.locality, p.administrativeArea, p.country]
                .compactMap { $0 }.filter { $0 != name }.joined(separator: ", ")
            return Place(name: name, detail: detail, lat: p.coordinate.latitude, lon: p.coordinate.longitude)
        }
    }

    /// Words for a failed search: "nothing found" is not an error.
    static func message(_ error: Error) -> String {
        if let e = error as? MKError, e.code == .placemarkNotFound { return "Nothing found." }
        return "Apple Maps could not search: \(error.localizedDescription)"
    }
}
