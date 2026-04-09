import XCTest
@testable import HFShared

final class AnonymizerTests: XCTestCase {

    // MARK: - Email

    func testRedactsEmail() {
        let out = Anonymizer.anonymize(text: "contact me at kevin@example.com please", userName: nil)
        XCTAssertEqual(out, "contact me at [EMAIL] please")
    }

    func testRedactsMultipleEmails() {
        let out = Anonymizer.anonymize(text: "send to a@b.co and c.d+tag@e.io", userName: nil)
        XCTAssertEqual(out, "send to [EMAIL] and [EMAIL]")
    }

    // MARK: - SSN

    func testRedactsSSN() {
        let out = Anonymizer.anonymize(text: "my ssn is 123-45-6789 ok?", userName: nil)
        XCTAssertEqual(out, "my ssn is [SSN] ok?")
    }

    func testDoesNotRedactNonSSNDashedNumbers() {
        // 4-digit middle — NOT an SSN
        let out = Anonymizer.anonymize(text: "order 12-3456", userName: nil)
        XCTAssertEqual(out, "order 12-3456")
    }

    // MARK: - Plaid ID

    func testRedactsPlaidItemId() {
        let out = Anonymizer.anonymize(text: "item-sandbox-a1b2c3d4-ef56-7890 was linked", userName: nil)
        XCTAssertEqual(out, "[PLAID_ID] was linked")
    }

    func testRedactsPlaidAccessToken() {
        let out = Anonymizer.anonymize(text: "token access-production-abc123ef", userName: nil)
        XCTAssertEqual(out, "token [PLAID_ID]")
    }

    // MARK: - Account last-4

    func testRedactsAsteriskLast4() {
        let out = Anonymizer.anonymize(text: "card ****1234 charged", userName: nil)
        XCTAssertEqual(out, "card [ACCT] charged")
    }

    func testRedactsXPrefixedLast4() {
        let out = Anonymizer.anonymize(text: "acct x9876 balance", userName: nil)
        XCTAssertEqual(out, "acct [ACCT] balance")
    }

    // MARK: - 10+ digit runs

    func testRedactsLongDigitRun() {
        let out = Anonymizer.anonymize(text: "routing 0123456789 ok", userName: nil)
        XCTAssertEqual(out, "routing [ACCT] ok")
    }

    func testDoesNotRedactShortDigitRun() {
        let out = Anonymizer.anonymize(text: "spent $142.50 on 2026-04-08", userName: nil)
        XCTAssertEqual(out, "spent $142.50 on 2026-04-08")
    }

    // MARK: - User name

    func testRedactsSingleNameWordBoundary() {
        let out = Anonymizer.anonymize(text: "How much did Kevin spend?", userName: "Kevin")
        XCTAssertEqual(out, "How much did [NAME] spend?")
    }

    func testRedactsNameCaseInsensitive() {
        let out = Anonymizer.anonymize(text: "did KEVIN spend much", userName: "Kevin")
        XCTAssertEqual(out, "did [NAME] spend much")
    }

    func testRedactsMultipleNameTokens() {
        let out = Anonymizer.anonymize(text: "Kevin Lee bought coffee", userName: "Kevin Lee")
        XCTAssertEqual(out, "[NAME] [NAME] bought coffee")
    }

    func testDoesNotRedactNameSubstring() {
        // "Kev" is a prefix of "Kevlar" — word-boundary must prevent match.
        let out = Anonymizer.anonymize(text: "bought Kevlar vest", userName: "Kev")
        // "Kev" is only 3 chars so it IS processed, but it shouldn't match inside "Kevlar"
        XCTAssertEqual(out, "bought Kevlar vest")
    }

    func testSkipsShortNameTokens() {
        // "Al" is < 3 chars, so it should NOT be redacted even if it appears
        let out = Anonymizer.anonymize(text: "Al went shopping", userName: "Al")
        XCTAssertEqual(out, "Al went shopping")
    }

    func testHandlesNilUserName() {
        let out = Anonymizer.anonymize(text: "Kevin spent money", userName: nil)
        XCTAssertEqual(out, "Kevin spent money")
    }

    // MARK: - Combined / preservation

    func testPreservesMerchantAmountDate() {
        let out = Anonymizer.anonymize(
            text: "$142.50 at Uber on 2026-04-08 for Kevin",
            userName: "Kevin"
        )
        XCTAssertEqual(out, "$142.50 at Uber on 2026-04-08 for [NAME]")
    }

    func testAllRulesAtOnce() {
        let input = "Kevin kevin@ex.com 123-45-6789 item-sandbox-abc ****1111 9999999999"
        let out = Anonymizer.anonymize(text: input, userName: "Kevin")
        XCTAssertEqual(out, "[NAME] [EMAIL] [SSN] [PLAID_ID] [ACCT] [ACCT]")
    }

    func testEmptyString() {
        XCTAssertEqual(Anonymizer.anonymize(text: "", userName: "Kevin"), "")
    }
}
