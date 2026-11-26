import Foundation
import CoreMedia
import Testing
@testable import RushCut

@Suite("Temps exact")
struct RTimeTests {
    @Test func framesAreExactTicks() {
        #expect(RTime.frame(fps: 24).ticks == 2_500)
        #expect(RTime.frame(fps: 25).ticks == 2_400)
        #expect(RTime.frame(fps: 30).ticks == 2_000)
        #expect(RTime.frame(fps: 50).ticks == 1_200)
        #expect(RTime.frame(fps: 60).ticks == 1_000)
    }

    @Test func conversions() {
        let t = RTime(seconds: 2.5)
        #expect(t.ticks == 150_000)
        #expect(RTime(t.cmTime) == t)
        #expect(RTime(CMTime(value: 1001, timescale: 30_000)).ticks == 2_002)
        #expect(RTime(CMTime.invalid) == .zero)
    }

    @Test func snappingAndTimecode() {
        let t = RTime(seconds: 62.51)
        #expect(t.snapped(fps: 30).ticks % 2_000 == 0)
        #expect(RTime(seconds: 62.5).timecode(fps: 30) == "00:01:02:15")
        #expect(RTime(seconds: 3_725).timecode(fps: 25) == "01:02:05:00")
        #expect(RTime(seconds: -3).timecode(fps: 30) == "00:00:00:00")
    }

    @Test func arithmetic() {
        let a = RTime(seconds: 1), b = RTime(seconds: 0.5)
        #expect((a + b).seconds == 1.5)
        #expect((a - b).seconds == 0.5)
        #expect((a * 2).seconds == 2)
        #expect(b < a)
    }
}

@Suite("Géométrie")
struct GeometryTests {
    @Test func fitAndFill() {
        let canvas = CGSize(width: 1920, height: 1080)
        let square = CGSize(width: 1000, height: 1000)
        let fit = Geometry.layer(sourceSize: square, canvas: canvas, fit: .fit, transform: Transform())
        #expect(fit.size == CGSize(width: 1080, height: 1080))
        #expect(fit.center == CGPoint(x: 960, y: 540))
        let fill = Geometry.layer(sourceSize: square, canvas: canvas, fit: .fill, transform: Transform())
        #expect(fill.size == CGSize(width: 1920, height: 1920))
    }

    @Test func transformMovesAndScales() {
        var t = Transform()
        t.positionX = 0.25
        t.positionY = -0.25
        t.scale = 0.5
        let g = Geometry.layer(sourceSize: CGSize(width: 1920, height: 1080), canvas: CGSize(width: 1920, height: 1080), fit: .fit, transform: t)
        #expect(g.size == CGSize(width: 960, height: 540))
        #expect(g.center == CGPoint(x: 1440, y: 270))
        #expect(g.contains(CGPoint(x: 1440, y: 270)))
        #expect(!g.contains(CGPoint(x: 100, y: 1000)))
    }

    @Test func cropForAspect() {
        let crop = Geometry.crop(forAspect: 1, source: CGSize(width: 1920, height: 1080))
        let size = Geometry.croppedSize(CGSize(width: 1920, height: 1080), crop: crop)
        #expect(abs(size.width - size.height) < 1)
    }
}

@Suite("Montage")
struct EditingTests {
    @Test func addMediaAppendsOnMainTrack() {
        var (p, video, image, _) = Project.sample()
        p.addMedia(video, at: nil)
        p.addMedia(image, at: nil)
        p.normalize(magnetic: true)
        #expect(p.mainClips.count == 2)
        #expect(p.mainClips[0].start == .zero)
        #expect(p.mainClips[1].start == RTime(seconds: 10))
        #expect(p.duration == RTime(seconds: 15))
    }

    @Test func audioGoesToAudioTrack() {
        var (p, _, _, audio) = Project.sample()
        p.addMedia(audio, at: RTime(seconds: 2))
        p.normalize(magnetic: true)
        let audioTracks = p.tracks.filter { $0.kind == .audio }
        #expect(audioTracks.count == 1)
        #expect(audioTracks[0].clips.first?.start == RTime(seconds: 2))
    }

    @Test func splitKeepsSourceContinuity() {
        var (p, video, _, _) = Project.sample()
        p.addMedia(video, at: nil)
        let created = p.split(at: RTime(seconds: 4), clipIDs: [])
        p.normalize(magnetic: true)
        #expect(created.count == 1)
        #expect(p.mainClips.count == 2)
        #expect(p.mainClips[0].duration == RTime(seconds: 4))
        #expect(p.mainClips[1].start == RTime(seconds: 4))
        #expect(p.mainClips[1].sourceIn == RTime(seconds: 4))
        #expect(p.mainClips[1].duration == RTime(seconds: 6))
    }

    @Test func splitAtEdgeDoesNothing() {
        var (p, video, _, _) = Project.sample()
        p.addMedia(video, at: nil)
        #expect(p.split(at: .zero, clipIDs: []).isEmpty)
        #expect(p.split(at: RTime(seconds: 10), clipIDs: []).isEmpty)
    }

    @Test func trimIsLimitedByMedia() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.trim(id, edge: .end, to: RTime(seconds: 30))
        #expect(p.clip(id)?.duration == RTime(seconds: 10))
        p.trim(id, edge: .end, to: RTime(seconds: 6))
        #expect(p.clip(id)?.duration == RTime(seconds: 6))
        p.trim(id, edge: .start, to: RTime(seconds: 2))
        p.normalize(magnetic: true)
        let clip = p.clip(id)!
        #expect(clip.sourceIn == RTime(seconds: 2))
        #expect(clip.duration == RTime(seconds: 4))
        #expect(clip.start == .zero, "La piste principale reste magnétique")
    }

    @Test func imageCanBeExtended() {
        var (p, _, image, _) = Project.sample()
        let id = p.addMedia(image, at: nil)!
        p.trim(id, edge: .end, to: RTime(seconds: 20))
        #expect(p.clip(id)?.duration == RTime(seconds: 20))
    }

    @Test func rippleDeleteOnMainTrack() {
        var (p, video, image, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        let b = p.addMedia(image, at: nil)!
        let c = p.addMedia(video, at: nil)!
        p.normalize(magnetic: true)
        p.delete([b])
        p.normalize(magnetic: true)
        #expect(p.clip(a)?.start == .zero)
        #expect(p.clip(c)?.start == RTime(seconds: 10))
        #expect(p.duration == RTime(seconds: 20))
    }

    @Test func overlappingMoveCreatesTrack() {
        var (p, _, image, _) = Project.sample()
        let a = p.addMedia(image, at: .zero, target: .newTrack)!
        let b = p.addMedia(image, at: RTime(seconds: 10), target: .newTrack)!
        p.normalize(magnetic: true)
        let trackA = p.trackIndex(of: a)!
        #expect(p.trackIndex(of: b) == trackA, "Deux images sans chevauchement partagent la piste")
        p.move(b, to: RTime(seconds: 2), target: .existing(trackA))
        p.normalize(magnetic: true)
        #expect(p.trackIndex(of: b) != p.trackIndex(of: a))
        #expect(p.clip(b)?.start == RTime(seconds: 2))
    }

    @Test func reorderOnMainTrack() {
        var (p, video, image, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        let b = p.addMedia(image, at: nil)!
        p.normalize(magnetic: true)
        // Glisser la vidéo après l'image.
        p.move(a, to: RTime(seconds: 12), target: .existing(0))
        p.normalize(magnetic: true)
        #expect(p.mainClips.map(\.id) == [b, a])
        #expect(p.clip(b)?.start == .zero)
        #expect(p.clip(a)?.start == RTime(seconds: 5))
    }

    @Test func detachAudioCreatesLinkedClip() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        let audioID = p.detachAudio(id)
        p.normalize(magnetic: true)
        #expect(audioID != nil)
        #expect(p.clip(id)?.audio.isMuted == true)
        let audioClip = p.clip(audioID!)!
        #expect(audioClip.linkedClipIDs == [id])
        #expect(p.tracks[p.trackIndex(of: audioID!)!].kind == .audio)
        #expect(p.detachAudio(id) == nil, "On ne détache pas deux fois")
    }

    @Test func detachedAudioFollowsMainTrack() {
        var (p, video, image, _) = Project.sample()
        let first = p.addMedia(image, at: nil)!
        let id = p.addMedia(video, at: nil)!
        let audioID = p.detachAudio(id)!
        p.normalize(magnetic: true)
        #expect(p.clip(audioID)?.start == RTime(seconds: 5))
        p.delete([first])
        p.normalize(magnetic: true)
        #expect(p.clip(id)?.start == .zero)
        #expect(p.clip(audioID)?.start == .zero, "Le son détaché suit la vidéo")
    }

    @Test func splitLinkedClipsTogether() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        let audioID = p.detachAudio(id)!
        let created = p.split(at: RTime(seconds: 3), clipIDs: [id])
        p.normalize(magnetic: true)
        #expect(created.count == 2)
        #expect(p.clip(audioID)?.duration == RTime(seconds: 3))
    }

    @Test func trimToPlayhead() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.trimToPlayhead(RTime(seconds: 3), keepRight: true, clipIDs: [])
        p.normalize(magnetic: true)
        #expect(p.clip(id)?.sourceIn == RTime(seconds: 3))
        #expect(p.clip(id)?.duration == RTime(seconds: 7))
        p.trimToPlayhead(RTime(seconds: 5), keepRight: false, clipIDs: [])
        #expect(p.clip(id)?.duration == RTime(seconds: 5))
    }

    @Test func duplicateAndPaste() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        let dup = p.duplicate([id])
        p.normalize(magnetic: true)
        #expect(dup.count == 1)
        #expect(p.mainClips.count == 2)
        let items = p.clipboardItems(for: [id])
        let pasted = p.paste(items, at: RTime(seconds: 20))
        p.normalize(magnetic: true)
        #expect(pasted.count == 1)
        #expect(!pasted.contains(id))
        #expect(p.mainClips.count == 3)
    }

    @Test func textOnTextTrack() {
        var (p, _, _, _) = Project.sample()
        let id = p.addText(TextContent(), at: RTime(seconds: 1))
        p.normalize(magnetic: true)
        #expect(p.tracks[p.trackIndex(of: id)!].kind == .text)
        #expect(p.clip(id)?.start == RTime(seconds: 1))
    }

    @Test func emptyTracksAreRemoved() {
        var (p, _, _, audio) = Project.sample()
        let id = p.addMedia(audio, at: .zero)!
        p.normalize(magnetic: true)
        #expect(p.tracks.count == 2)
        p.delete([id])
        p.normalize(magnetic: true)
        #expect(p.tracks.count == 1)
        #expect(p.tracks[0].isMain)
    }

    @Test func lockedTrackIsProtected() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.tracks[0].isLocked = true
        p.delete([id])
        #expect(p.clip(id) != nil)
        #expect(p.split(at: RTime(seconds: 5), clipIDs: []).isEmpty)
    }

    @Test func fadesAreClamped() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.updateClip(id) { $0.audio.fadeIn = RTime(seconds: 8); $0.audio.fadeOut = RTime(seconds: 8) }
        let clip = p.clip(id)!
        #expect(clip.audio.fadeIn + clip.audio.fadeOut <= clip.duration)
    }

    @Test func markers() {
        var (p, _, _, _) = Project.sample()
        p.addMarker(at: RTime(seconds: 2))
        p.addMarker(at: RTime(seconds: 1))
        p.addMarker(at: RTime(seconds: 2))
        #expect(p.markers.count == 2)
        #expect(p.markers.first?.time == RTime(seconds: 1))
    }
}

@Suite("Annuler / rétablir")
struct UndoTests {
    @Test func fiftyOperationsThenFiftyUndos() {
        var (p, video, image, audio) = Project.sample()
        p.normalize(magnetic: true)
        let initial = p
        var stack = UndoStack()
        var generator = SystemRandomNumberGenerator()
        for i in 0..<50 {
            let before = p
            switch i % 7 {
            case 0: p.addMedia(video, at: nil)
            case 1: p.addMedia(image, at: nil)
            case 2: p.addMedia(audio, at: RTime(seconds: Double(i)))
            case 3: p.split(at: RTime(seconds: Double(Int.random(in: 1...20, using: &generator))), clipIDs: [])
            case 4: if let c = p.mainClips.first { p.trim(c.id, edge: .end, to: c.start + RTime(seconds: 2)) }
            case 5: p.addText(TextContent(), at: RTime(seconds: Double(i)))
            default: if let c = p.mainClips.last { p.delete([c.id]) }
            }
            p.normalize(magnetic: true)
            stack.record(before: before, name: "op \(i)")
        }
        for _ in 0..<50 {
            if let previous = stack.undo(current: p) { p = previous }
        }
        #expect(p == initial)
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func coalescesSliderChanges() {
        var stack = UndoStack()
        let p = Project()
        let now = Date()
        stack.record(before: p, name: "Échelle", coalesceKey: "scale", now: now)
        stack.record(before: p, name: "Échelle", coalesceKey: "scale", now: now.addingTimeInterval(0.5))
        stack.record(before: p, name: "Échelle", coalesceKey: "scale", now: now.addingTimeInterval(1.0))
        #expect(stack.undoEntries.count == 1)
        stack.record(before: p, name: "Échelle", coalesceKey: "scale", now: now.addingTimeInterval(5))
        #expect(stack.undoEntries.count == 2)
    }

    @Test func redoAfterUndo() {
        var stack = UndoStack()
        var p = Project()
        let before = p
        p.name = "Modifié"
        stack.record(before: before, name: "Renommer")
        let undone = stack.undo(current: p)!
        #expect(undone.name == "Sans titre")
        let redone = stack.redo(current: undone)!
        #expect(redone.name == "Modifié")
    }
}
