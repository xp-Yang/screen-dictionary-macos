import Foundation
import SQLite3

struct OfflineDefinition {
    let translation: String
    let phonetic: String?
}

enum OfflineDictionary {
    private static let databaseURL = Bundle.main.url(forResource: "ECDICT", withExtension: "sqlite3")

    static func lookup(_ word: String, sourceLanguage: String, targetLanguage: String) -> OfflineDefinition? {
        guard sourceLanguage.split(separator: "-").first == "en", targetLanguage == "zh-Hans",
              let databaseURL else { return nil }
        let key = word.replacingOccurrences(of: "’", with: "'")
            .lowercased().precomposedStringWithCanonicalMapping

        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(connection) }
        guard opened == SQLITE_OK else { return nil }

        // The bound bytes stay alive until the prepared statement is finalized.
        return key.withCString { bytes in
            var query: OpaquePointer?
            let prepared = sqlite3_prepare_v2(connection,
                "SELECT translation, phonetic FROM entries WHERE word = ?1", -1, &query, nil)
            defer { sqlite3_finalize(query) }
            guard prepared == SQLITE_OK, sqlite3_bind_text(query, 1, bytes, -1, nil) == SQLITE_OK,
                  sqlite3_step(query) == SQLITE_ROW, let translation = sqlite3_column_text(query, 0) else { return nil }
            let phonetic = sqlite3_column_text(query, 1).map { String(cString: $0) }
            return OfflineDefinition(translation: String(cString: translation), phonetic: phonetic)
        }
    }
}
