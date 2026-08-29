import Foundation
import SwiftData

@Model
public final class Tag {
    public var id: UUID
    @Attribute(.unique)
    public var name: String
    public var stations: [Station]

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.stations = []
    }
}
