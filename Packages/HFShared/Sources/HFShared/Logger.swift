import os
import Foundation

public enum HFLogger {
    private static let subsystem = "com.hyperfin.app"

    public static let general = Logger(subsystem: subsystem, category: "general")
    public static let ai = Logger(subsystem: subsystem, category: "ai")
    public static let data = Logger(subsystem: subsystem, category: "data")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
}
