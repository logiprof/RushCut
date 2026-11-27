import Foundation
import os

/// Erreurs affichées à l'utilisateur, toujours en français et avec une piste de solution.
enum RushError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadable(String)
    case missingMedia(String)
    case exportFailed(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case invalidProject(String)
    case render(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Le format « \(ext.uppercased()) » n'est pas lu directement par macOS. RushCut peut le convertir en MP4 avec le module de conversion (FFmpeg, téléchargé une seule fois)."
        case .unreadable(let name):
            return "Le fichier « \(name) » est illisible ou endommagé."
        case .missingMedia(let name):
            return "Le fichier « \(name) » est introuvable. Utilisez « Relier le média… » pour indiquer son nouvel emplacement."
        case .exportFailed(let reason):
            return "L'export a échoué : \(reason)"
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Espace disque insuffisant : il faut environ \(f.string(fromByteCount: needed)) et il reste \(f.string(fromByteCount: available))."
        case .invalidProject(let reason):
            return "Le projet ne peut pas être ouvert : \(reason)"
        case .render(let reason):
            return "Erreur de rendu : \(reason)"
        }
    }
}

/// Emplacements des fichiers de l'application.
enum AppPaths {
    static var fileManager: FileManager { .default }

    static var applicationSupport: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("RushCut", isDirectory: true))
    }

    static var caches: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("RushCut", isDirectory: true))
    }

    static var logs: URL {
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Logs/RushCut", isDirectory: true))
    }

    static var fonts: URL { ensure(applicationSupport.appendingPathComponent("Polices", isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Journal technique : console système + fichier (10 Mo maximum, avec rotation).
enum Log {
    private static let logger = Logger(subsystem: "ch.logiprof.rushcut", category: "app")
    private static let queue = DispatchQueue(label: "ch.logiprof.rushcut.log")
    private static let maxSize: Int64 = 10 * 1024 * 1024

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERREUR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let url = AppPaths.logs.appendingPathComponent("rushcut.log")
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, size > maxSize {
                let old = AppPaths.logs.appendingPathComponent("rushcut.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }
}
