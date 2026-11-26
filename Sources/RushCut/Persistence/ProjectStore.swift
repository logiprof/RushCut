import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ProjectSummary: Identifiable, Hashable {
    var url: URL
    var name: String
    var modifiedAt: Date
    var duration: RTime
    var formatLabel: String
    var posterURL: URL?

    var id: URL { url }
}

/// Lecture et écriture des paquets de projet `.rushcut` (un dossier contenant `project.json` et `poster.jpg`).
enum ProjectStore {
    static let fileExtension = "rushcut"
    static let typeIdentifier = "ch.logiprof.rushcut.project"
    static let projectFileName = "project.json"
    static let posterFileName = "poster.jpg"

    /// Dossier des projets : ~/Movies/RushCut.
    static var defaultDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return AppPaths.ensure(movies.appendingPathComponent("RushCut", isDirectory: true))
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Création

    static func uniqueURL(for name: String, in directory: URL) -> URL {
        let clean = sanitize(name)
        var candidate = directory.appendingPathComponent(clean).appendingPathExtension(fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(clean) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let cleaned = trimmed.components(separatedBy: forbidden).joined(separator: "-")
        return cleaned.isEmpty ? "Sans titre" : cleaned
    }

    static func createProject(name: String, settings: ProjectSettings, in directory: URL = defaultDirectory) throws -> (Project, URL) {
        var project = Project()
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sans titre" : name
        project.settings = settings
        let url = uniqueURL(for: project.name, in: directory)
        try save(project, to: url)
        return (project, url)
    }

    // MARK: - Lecture / écriture

    /// Écriture atomique : fichier temporaire puis remplacement. Une coupure ne peut pas corrompre le projet.
    static func save(_ project: Project, to url: URL, poster: CGImage? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        try data.write(to: url.appendingPathComponent(projectFileName), options: [.atomic])
        if let poster {
            writeJPEG(poster, to: url.appendingPathComponent(posterFileName))
        }
    }

    static func load(_ url: URL) throws -> Project {
        let file = url.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RushError.invalidProject("le fichier project.json est absent.")
        }
        let data = try Data(contentsOf: file)
        do {
            var project = try decoder.decode(Project.self, from: data)
            migrate(&project)
            project.normalize(magnetic: true)
            return project
        } catch let error as RushError {
            throw error
        } catch {
            throw RushError.invalidProject("le contenu est endommagé (\(error.localizedDescription)).")
        }
    }

    /// Mise à niveau des projets enregistrés par d'anciennes versions.
    static func migrate(_ project: inout Project) {
        if project.version < 1 {
            // Version 0 : pas de piste principale explicite.
            project.ensureMainTrack()
        }
        project.version = Project.currentVersion
    }

    // MARK: - Liste et gestion

    static func listProjects(in directory: URL = defaultDirectory) -> [ProjectSummary] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [ProjectSummary] = []
        for url in items where url.pathExtension == fileExtension {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(projectFileName)),
                  let project = try? decoder.decode(Project.self, from: data) else { continue }
            let poster = url.appendingPathComponent(posterFileName)
            result.append(ProjectSummary(
                url: url,
                name: project.name,
                modifiedAt: project.modifiedAt,
                duration: project.duration,
                formatLabel: project.settings.formatLabel,
                posterURL: fm.fileExists(atPath: poster.path) ? poster : nil))
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func duplicate(_ url: URL) throws -> URL {
        var project = try load(url)
        project.id = UUID()
        project.name += " (copie)"
        project.createdAt = Date()
        project.modifiedAt = Date()
        let target = uniqueURL(for: project.name, in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: target)
        try save(project, to: target)
        return target
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        var project = try load(url)
        project.name = name
        project.modifiedAt = Date()
        let target = uniqueURL(for: name, in: url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: url, to: target)
        try save(project, to: target)
        return target
    }

    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Récupération après plantage

    private static var sessionLockURL: URL { AppPaths.applicationSupport.appendingPathComponent("session.json") }

    static func writeSessionLock(_ projectURL: URL) {
        let payload = ["projet": projectURL.path]
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: sessionLockURL, options: .atomic)
        }
    }

    static func clearSessionLock() {
        try? FileManager.default.removeItem(at: sessionLockURL)
    }

    /// Projet resté ouvert lors d'une fermeture inattendue.
    static func readSessionLock() -> URL? {
        guard let data = try? Data(contentsOf: sessionLockURL),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let path = payload["projet"], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Image

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
