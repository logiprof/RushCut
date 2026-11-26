import Foundation
import Testing
@testable import RushCut

@Suite("Sauvegarde des projets")
struct PersistenceTests {
    @Test func roundTrip() throws {
        let dir = TestMedia.tempDirectory()
        var (p, video, _, audio) = Project.sample()
        p.addMedia(video, at: nil)
        p.addMedia(audio, at: RTime(seconds: 1))
        p.addText(TextContent(), at: RTime(seconds: 2))
        p.addMarker(at: RTime(seconds: 3))
        p.normalize(magnetic: true)
        // Les dates sont enregistrées à la milliseconde près.
        for i in p.media.indices {
            p.media[i].importedAt = Date(timeIntervalSince1970: (p.media[i].importedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        }
        let url = dir.appendingPathComponent("Essai.rushcut")
        try ProjectStore.save(p, to: url)
        let loaded = try ProjectStore.load(url)
        #expect(loaded.tracks == p.tracks)
        #expect(loaded.media.map(\.id) == p.media.map(\.id))
        #expect(loaded.media.map(\.path) == p.media.map(\.path))
        for (a, b) in zip(loaded.media, p.media) {
            #expect(abs(a.importedAt.timeIntervalSince(b.importedAt)) < 0.002)
        }
        #expect(loaded.markers == p.markers)
        #expect(loaded.settings == p.settings)
        #expect(loaded.name == p.name)
    }

    @Test func oldOrPartialFilesStillOpen() throws {
        let dir = TestMedia.tempDirectory()
        let url = dir.appendingPathComponent("Ancien.rushcut")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let json = """
        {"name": "Ancien projet", "settings": {"width": 1080, "height": 1920},
         "tracks": [{"kind": "video", "clips": [{"start": 0, "duration": 120000, "inconnu": true}]}],
         "champFutur": 42}
        """
        try Data(json.utf8).write(to: url.appendingPathComponent("project.json"))
        let p = try ProjectStore.load(url)
        #expect(p.name == "Ancien projet")
        #expect(p.version == Project.currentVersion)
        #expect(p.settings.frameRate == 30)
        #expect(p.settings.height == 1920)
        #expect(p.tracks.first?.isMain == true)
        #expect(p.tracks.first?.clips.first?.duration == RTime(seconds: 2))
    }

    @Test func damagedFileGivesClearError() throws {
        let dir = TestMedia.tempDirectory()
        let url = dir.appendingPathComponent("Abime.rushcut")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: url.appendingPathComponent("project.json"))
        #expect(throws: RushError.self) { try ProjectStore.load(url) }
    }

    @Test func createListDuplicateRename() throws {
        let dir = TestMedia.tempDirectory()
        let (_, url) = try ProjectStore.createProject(name: "Formation M4", settings: ProjectSettings(), in: dir)
        let (_, url2) = try ProjectStore.createProject(name: "Formation M4", settings: ProjectSettings(), in: dir)
        #expect(url != url2, "Deux projets du même nom ne s'écrasent pas")
        let copy = try ProjectStore.duplicate(url)
        #expect(try ProjectStore.load(copy).name == "Formation M4 (copie)")
        let renamed = try ProjectStore.rename(url, to: "Formation M5")
        #expect(try ProjectStore.load(renamed).name == "Formation M5")
        let list = ProjectStore.listProjects(in: dir)
        #expect(list.count == 3)
    }

    @Test func atomicSaveLeavesNoTemporaryFiles() throws {
        let dir = TestMedia.tempDirectory()
        let url = dir.appendingPathComponent("Atomique.rushcut")
        var p = Project()
        for i in 0..<5 {
            p.name = "Version \(i)"
            try ProjectStore.save(p, to: url)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        #expect(files == ["project.json"])
        #expect(try ProjectStore.load(url).name == "Version 4")
    }
}
