import Foundation
import HFDomain
import HFShared

// MARK: - Tool-calling primitives
//
// The chat pipeline is a Plan → Execute → Synthesize loop. The planner
// (an LLM call) inspects the user's query and emits a JSON array of tool
// invocations. The registry executes them (possibly in parallel). The
// synthesizer turns the aggregated tool results into a natural-language
// reply.
//
// This file defines the three primitives that the three phases share:
//   - `ToolArgValue`  — a JSON-like tagged union for untyped tool arguments
//   - `ToolCall`      — a name + args bag (one entry in the planner output)
//   - `Tool`          — the protocol each concrete tool conforms to
//
// Tools themselves live in ConcreteTools.swift. The registry that owns the
// repository graph and looks up tools by name lives in ToolRegistry.swift.

// MARK: - ToolArgValue

/// Loosely-typed argument value. The planner LLM emits JSON whose shape we
/// can't statically type-check, so each arg lands in this enum and the
/// individual tool decodes it into the specific Swift type it needs.
///
/// We keep the enum small — string / number / integer / boolean / null — to
/// match the subset of JSON the planner prompt asks the model to produce.
/// Nested objects and arrays are not supported as arg values: if a tool
/// needs structured input, it should accept it as a JSON-encoded string
/// that it parses internally.
public enum ToolArgValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case null

    /// Decode from `Any` (what `JSONSerialization` produces). Returns nil
    /// when the value is an unsupported type (array/dictionary/NSNull of a
    /// different flavour). Nil is also returned for explicit JSON null so
    /// callers can distinguish "absent" from "null" if they care; the
    /// registry treats both the same.
    public static func from(any value: Any?) -> ToolArgValue? {
        guard let value else { return nil }
        if value is NSNull { return .null }
        if let b = value as? Bool { return .boolean(b) }
        if let i = value as? Int { return .integer(i) }
        if let d = value as? Double { return .number(d) }
        if let n = value as? NSNumber {
            // NSNumber is ambiguous between Bool / Int / Double — inspect
            // the objC type to recover the original intent. This matters
            // because `JSONSerialization` coerces every number to NSNumber
            // on iOS.
            let typeChar = String(cString: n.objCType)
            if typeChar == "c" || typeChar == "B" { return .boolean(n.boolValue) }
            if typeChar == "i" || typeChar == "l" || typeChar == "q" { return .integer(n.intValue) }
            return .number(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case let .boolean(b) = self { return b }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Dict helpers

public extension Dictionary where Key == String, Value == ToolArgValue {
    /// Read a string arg. Returns nil when the key is absent, set to null,
    /// or set to an empty string. Non-empty empty-string check is important
    /// because planners often emit `"category": ""` to mean "no filter"
    /// rather than omitting the key.
    func string(_ key: String) -> String? {
        guard let v = self[key], let s = v.stringValue, !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }

    /// Period args are always encoded as one of the canonical period strings
    /// ("this_month", "last_30_days", "last_6_months", etc.). This helper
    /// translates them to `DatePeriod`, falling back to `defaultTo` when
    /// the key is missing or unrecognized.
    func period(_ key: String, defaultTo: DatePeriod = .thisMonth) -> DatePeriod {
        guard let raw = string(key)?.lowercased() else { return defaultTo }
        switch raw {
        case "today": return .today
        case "this_week": return .thisWeek
        case "this_month": return .thisMonth
        case "last_month": return .lastMonth
        case "last_30_days", "30_days": return .last30Days
        case "last_90_days", "90_days": return .last90Days
        case "year_to_date", "ytd", "this_year", "last_12_months":
            return .lastNMonths(12)
        default:
            if raw.hasPrefix("last_"), raw.hasSuffix("_months") {
                let middle = raw.dropFirst(5).dropLast(7)
                if let n = Int(middle) { return .lastNMonths(n) }
            }
            return defaultTo
        }
    }
}

// MARK: - ToolCall

/// One entry in the planner's output. A plan is a sequence of these.
public struct ToolCall: Sendable, Equatable {
    public let name: String
    public let args: [String: ToolArgValue]

    public init(name: String, args: [String: ToolArgValue] = [:]) {
        self.name = name
        self.args = args
    }
}

// MARK: - Tool protocol

/// Contract every concrete tool implements.
///
/// The repository graph is passed in on every call instead of held by the
/// tool itself so tools can stay value-type / stateless structs. That keeps
/// them trivially `Sendable` and lets the registry build them once at
/// startup.
public protocol Tool: Sendable {
    /// Canonical kebab/snake-cased name the planner emits
    /// (e.g. `"spending_summary"`). Must be unique across the registry.
    var name: String { get }

    /// One-sentence human description for the planner prompt. Keep it
    /// present-tense imperative ("Aggregates spending by category...").
    var description: String { get }

    /// Compact signature string rendered into the planner prompt so the
    /// model knows what args it can pass — e.g.
    /// `"(category?: string, merchant?: string, period?: string)"`.
    /// Args are `?`-suffixed when optional. Use `string` / `integer` /
    /// `number` / `boolean` as the type annotations since the planner
    /// prompt already mirrors that vocabulary.
    var argsSignature: String { get }

    /// Execute the tool against the given repository graph.
    ///
    /// Tools MUST be safe to run in parallel with other tools (read-only
    /// repository access is enforced at the repo protocol level).
    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult
}

// MARK: - Catalog rendering

public extension Tool {
    /// One-line rendering for the planner catalog:
    ///   `- spending_summary(category?: string, period?: string): Aggregate ...`
    var catalogLine: String {
        "- \(name)\(argsSignature): \(description)"
    }
}
