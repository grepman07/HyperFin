import Foundation

public struct SpendingCategory: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var colorHex: String
    public var isSystem: Bool
    public var parentId: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        colorHex: String = "#007AFF",
        isSystem: Bool = true,
        parentId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.isSystem = isSystem
        self.parentId = parentId
    }

    public static let systemCategories: [SpendingCategory] = [
        SpendingCategory(name: "Food & Dining", icon: "fork.knife", colorHex: "#FF6B6B"),
        SpendingCategory(name: "Transportation", icon: "car.fill", colorHex: "#4ECDC4"),
        SpendingCategory(name: "Shopping", icon: "bag.fill", colorHex: "#45B7D1"),
        SpendingCategory(name: "Entertainment", icon: "gamecontroller.fill", colorHex: "#96CEB4"),
        SpendingCategory(name: "Bills & Utilities", icon: "bolt.fill", colorHex: "#FFEAA7"),
        SpendingCategory(name: "Health & Fitness", icon: "heart.fill", colorHex: "#DDA0DD"),
        SpendingCategory(name: "Travel", icon: "airplane", colorHex: "#74B9FF"),
        SpendingCategory(name: "Education", icon: "book.fill", colorHex: "#A29BFE"),
        SpendingCategory(name: "Personal Care", icon: "sparkles", colorHex: "#FD79A8"),
        SpendingCategory(name: "Home", icon: "house.fill", colorHex: "#55A3F5"),
        SpendingCategory(name: "Income", icon: "banknote.fill", colorHex: "#00B894"),
        SpendingCategory(name: "Transfer", icon: "arrow.left.arrow.right", colorHex: "#636E72"),
        SpendingCategory(name: "Subscriptions", icon: "repeat", colorHex: "#E17055"),
        SpendingCategory(name: "Groceries", icon: "cart.fill", colorHex: "#00CEC9"),
        SpendingCategory(name: "Other", icon: "ellipsis.circle.fill", colorHex: "#B2BEC3"),
    ]
}
