import Foundation
import SwiftData
import HFDomain

/// SwiftData row for a Plaid liability. We store the raw JSON payload as a
/// `Data` blob alongside a `kind` discriminator (credit / mortgage / student)
/// since each kind's shape diverges heavily. Views decode on-demand into the
/// matching domain struct.
@Model
public final class SDLiability {
    @Attribute(.unique) public var id: UUID
    public var accountId: String
    public var kind: String
    public var payload: Data
    public var updatedAt: Date

    public init(id: UUID = UUID(), accountId: String, kind: String, payload: Data) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.payload = payload
        self.updatedAt = Date()
    }

    public func toLiability() -> Liability? {
        let decoder = JSONDecoder()
        switch kind {
        case "credit":
            return (try? decoder.decode(CreditLiability.self, from: payload)).map { .credit($0) }
        case "mortgage":
            return (try? decoder.decode(MortgageLiability.self, from: payload)).map { .mortgage($0) }
        case "student":
            return (try? decoder.decode(StudentLiability.self, from: payload)).map { .student($0) }
        default:
            return nil
        }
    }
}
