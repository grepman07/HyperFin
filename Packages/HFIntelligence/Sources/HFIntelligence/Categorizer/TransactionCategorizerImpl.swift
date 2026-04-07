import Foundation
import HFDomain
import HFShared

public actor TransactionCategorizerImpl: TransactionCategorizer {
    private let merchantMappingRepo: MerchantMappingRepository
    private let inferenceEngine: InferenceEngine
    private let ruleEngine: CategorizationRuleEngine

    public init(
        merchantMappingRepo: MerchantMappingRepository,
        inferenceEngine: InferenceEngine
    ) {
        self.merchantMappingRepo = merchantMappingRepo
        self.inferenceEngine = inferenceEngine
        self.ruleEngine = CategorizationRuleEngine()
    }

    public func categorize(_ transaction: Transaction) async throws -> UUID? {
        // Tier 1: Merchant cache lookup (< 1ms)
        if let merchantName = transaction.merchantName {
            let normalized = merchantName.normalizedMerchantName
            if let mapping = try await merchantMappingRepo.fetch(merchantName: normalized),
               mapping.confidence >= 0.7 {
                HFLogger.ai.debug("Tier 1 hit for \(merchantName)")
                return mapping.categoryId
            }
        }

        // Tier 2: Rule-based matching (< 5ms)
        let description = transaction.merchantName ?? transaction.originalDescription
        if let categoryId = ruleEngine.categorize(description: description) {
            HFLogger.ai.debug("Tier 2 hit for \(description)")
            return categoryId
        }

        // Tier 3: AI inference (~1-2s) — deferred for batch processing
        HFLogger.ai.debug("No quick categorization for: \(description)")
        return nil
    }

    public func categorizeBatch(_ transactions: [Transaction]) async throws -> [UUID: UUID] {
        var results: [UUID: UUID] = [:]

        for transaction in transactions {
            if let categoryId = try await categorize(transaction) {
                results[transaction.id] = categoryId
            }
        }

        // Remaining uncategorized can be sent to Gemma 4 in batch
        let uncategorized = transactions.filter { results[$0.id] == nil }
        if !uncategorized.isEmpty {
            HFLogger.ai.info("Batch AI categorization for \(uncategorized.count) transactions")
            // AI batch categorization will be implemented with the model runtime
        }

        return results
    }

    public func recordUserCorrection(merchantName: String, categoryId: UUID) async throws {
        let normalized = merchantName.normalizedMerchantName
        let mapping = MerchantMapping(
            merchantName: normalized,
            categoryId: categoryId,
            confidence: 1.0,
            source: .userCorrection
        )
        try await merchantMappingRepo.save(mapping)
        HFLogger.ai.info("Recorded user correction: \(normalized) → \(categoryId)")
    }
}
