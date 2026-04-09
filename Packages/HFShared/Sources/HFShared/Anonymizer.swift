import Foundation

/// Scrubs personally-identifying information out of free-form chat text before
/// it is persisted or uploaded. Ordered list of redactions:
/// 1. Emails → `[EMAIL]`
/// 2. SSNs → `[SSN]`
/// 3. Plaid item/access IDs → `[PLAID_ID]`
/// 4. Account last-4 (`****1234`, `x1234`) → `[ACCT]`
/// 5. Any run of 10+ consecutive digits → `[ACCT]`
/// 6. User's name tokens (each word ≥ 3 chars, word-boundary, case-insensitive) → `[NAME]`
///
/// Preserved on purpose: merchant names, amounts, dates, categories, short words
/// (so "He" or "Al" aren't accidentally redacted from common text).
public enum Anonymizer {
    /// Replace PII in `text`. Pass the user's full display name (if known) so
    /// each space-separated token ≥ 3 characters can be redacted.
    public static func anonymize(text: String, userName: String?) -> String {
        var s = text

        // 1. Email
        s = s.replacingOccurrences(
            of: #"[\w._%+-]+@[\w.-]+\.[A-Za-z]{2,}"#,
            with: "[EMAIL]",
            options: .regularExpression
        )

        // 2. SSN (xxx-xx-xxxx)
        s = s.replacingOccurrences(
            of: #"\b\d{3}-\d{2}-\d{4}\b"#,
            with: "[SSN]",
            options: .regularExpression
        )

        // 3. Plaid item/access tokens
        s = s.replacingOccurrences(
            of: #"\b(?:item|access)-[a-z]+-[a-f0-9-]+\b"#,
            with: "[PLAID_ID]",
            options: [.regularExpression, .caseInsensitive]
        )

        // 4. Account last-4: "****1234" or "x1234" / "X1234"
        s = s.replacingOccurrences(
            of: #"(?:\*{2,}|[xX])\d{4}\b"#,
            with: "[ACCT]",
            options: .regularExpression
        )

        // 5. Any run of 10+ consecutive digits (account-like)
        s = s.replacingOccurrences(
            of: #"\b\d{10,}\b"#,
            with: "[ACCT]",
            options: .regularExpression
        )

        // 6. User name tokens
        if let name = userName {
            for token in name.split(separator: " ") where token.count >= 3 {
                let escaped = NSRegularExpression.escapedPattern(for: String(token))
                s = s.replacingOccurrences(
                    of: "\\b\(escaped)\\b",
                    with: "[NAME]",
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }

        return s
    }
}
