import os

enum Log {
    static let app = Logger(subsystem: "dev.bobby.DuoTranslator", category: "app")
    static let engine = Logger(subsystem: "dev.bobby.DuoTranslator", category: "engine")
    static let capture = Logger(subsystem: "dev.bobby.DuoTranslator", category: "capture")
    static let ocr = Logger(subsystem: "dev.bobby.DuoTranslator", category: "ocr")
    static let sync = Logger(subsystem: "dev.bobby.DuoTranslator", category: "sync")
}
