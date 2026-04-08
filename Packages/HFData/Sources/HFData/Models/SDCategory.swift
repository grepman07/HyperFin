import Foundation
import SwiftData
import HFDomain

@Model
public final class SDCategory {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var icon: String
    public var colorHex: String
    public var isSystem: Bool
    public var parentId: UUID?

    public init(from domain: SpendingCategory) {
        self.id = domain.id
        self.name = domain.name
        self.icon = domain.icon
        self.colorHex = domain.colorHex
        self.isSystem = domain.isSystem
        self.parentId = domain.parentId
    }

    public func toDomain() -> SpendingCategory {
        SpendingCategory(
            id: id,
            name: name,
            icon: icon,
            colorHex: colorHex,
            isSystem: isSystem,
            parentId: parentId
        )
    }
}
