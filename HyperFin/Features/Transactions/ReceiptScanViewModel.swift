import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFIntelligence

enum ReceiptScanState: Equatable {
    case selectingImage
    case processing
    case confirming
    case saving
    case saved
    case error(String)
}

@MainActor
@Observable
final class ReceiptScanViewModel {
    var state: ReceiptScanState = .selectingImage

    // Confirmation form fields
    var merchantName = ""
    var amount = ""
    var date = Date()
    var selectedAccountId: UUID?
    var categoryId: UUID?
    var notes = ""

    private var receiptOCR = ReceiptOCR()
    private var receiptParser: ReceiptParser?
    private var categorizationEngine = CategorizationRuleEngine()

    var modelContainer: ModelContainer?

    func configure(inferenceEngine: InferenceEngine) {
        self.receiptParser = ReceiptParser(inferenceEngine: inferenceEngine)
    }

    func processImage(_ image: UIImage) {
        guard receiptParser != nil else {
            state = .error("AI engine not available")
            return
        }

        state = .processing

        Task {
            do {
                let lines = try await receiptOCR.recognizeText(from: image)

                guard !lines.isEmpty else {
                    state = .error("Could not read any text from the image.")
                    return
                }

                let parsed = try await receiptParser!.parse(ocrLines: lines)

                // Populate confirmation form
                merchantName = parsed.merchantName ?? ""
                if let total = parsed.totalAmount {
                    amount = "\(total)"
                }
                if let parsedDate = parsed.date {
                    date = parsedDate
                }

                // Auto-categorize based on merchant name
                if !merchantName.isEmpty {
                    categoryId = categorizationEngine.categorize(description: merchantName)
                }

                state = .confirming
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func saveTransaction() {
        guard let container = modelContainer,
              let accountId = selectedAccountId,
              let decimalAmount = Decimal(string: amount), decimalAmount > 0 else {
            state = .error("Please fill in the required fields.")
            return
        }

        state = .saving

        Task {
            do {
                let transaction = Transaction(
                    plaidTransactionId: "receipt-\(UUID().uuidString)",
                    accountId: accountId,
                    amount: decimalAmount,
                    date: date,
                    merchantName: merchantName.isEmpty ? nil : merchantName,
                    originalDescription: "Receipt scan: \(merchantName.isEmpty ? "Unknown" : merchantName)",
                    categoryId: categoryId,
                    isUserCategorized: categoryId != nil,
                    isPending: false,
                    notes: notes.isEmpty ? nil : notes
                )

                let context = ModelContext(container)
                context.insert(SDTransaction(from: transaction))
                try context.save()

                state = .saved
            } catch {
                state = .error("Failed to save: \(error.localizedDescription)")
            }
        }
    }
}
