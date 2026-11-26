import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Analyse un fichier importé : type, durée, taille, fréquence, présence de son.
enum MediaAnalyzer {
    /// Formats reconnus mais non lisibles par AVFoundation (conversion prévue en V1).
    static let convertibleExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "3gp", "ogv"]

    static func analyze(url: URL) async throws -> MediaRef {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if convertibleExtensions.contains(ext) { throw RushError.unsupportedFormat(ext) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw RushError.missingMedia(name) }

        var media = MediaRef()
        media.name = name
        media.path = url.path
        media.bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)

        let type = UTType(filenameExtension: ext)
        if let type, type.conforms(to: .image) {
            return try analyzeImage(url: url, into: media)
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable: Bool
        let duration: CMTime
        do {
            (playable, duration) = try await asset.load(.isPlayable, .duration)
        } catch {
            throw RushError.unreadable(name)
        }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard playable || !audioTracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
            throw RushError.unreadable(name)
        }
        media.duration = RTime(duration)
        media.hasAudio = !audioTracks.isEmpty

        if let track = videoTracks.first {
            let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let oriented = size.applying(transform)
            media.kind = .video
            media.width = Int(abs(oriented.width).rounded())
            media.height = Int(abs(oriented.height).rounded())
            media.frameRate = Double(rate)
        } else if !audioTracks.isEmpty {
            media.kind = .audio
        } else {
            throw RushError.unreadable(name)
        }
        return media
    }

    private static func analyzeImage(url: URL, into base: MediaRef) throws -> MediaRef {
        var media = base
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw RushError.unreadable(base.name)
        }
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { throw RushError.unreadable(base.name) }
        media.kind = .image
        media.width = w
        media.height = h
        let count = CGImageSourceGetCount(source)
        if count > 1 {
            media.isAnimated = true
            let total = (0..<count).reduce(0.0) { $0 + frameDelay(source: source, index: $1) }
            media.duration = RTime(seconds: max(0.1, total))
        } else {
            media.duration = RTime(seconds: 5)
        }
        return media
    }

    /// Durée d'une image d'un GIF ou d'un PNG animé.
    static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        var delay: Double = 0
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
        } else if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            delay = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (png[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue ?? 0
        }
        return delay < 0.02 ? 0.1 : delay
    }

    /// Fichiers d'un dossier (récursif, sans fichiers cachés).
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue && url.pathExtension != ProjectStore.fileExtension {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        result.append(file)
                    }
                }
            } else {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Retrouve le fichier d'un média, même s'il a été déplacé (signet).
enum MediaResolver {
    static func url(for media: MediaRef) -> URL? {
        if !media.path.isEmpty, FileManager.default.fileExists(atPath: media.path) {
            return URL(fileURLWithPath: media.path)
        }
        if let bookmark = media.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

/// Cache des AVURLAsset (une seule instance par fichier).
final class AssetCache: @unchecked Sendable {
    static let shared = AssetCache()
    private var assets: [URL: AVURLAsset] = [:]
    private let lock = NSLock()

    func asset(for url: URL) -> AVURLAsset {
        lock.lock(); defer { lock.unlock() }
        if let a = assets[url] { return a }
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[url] = a
        return a
    }
}
