import Foundation
import Testing
import CoreGraphics
@testable import RushCut

@Suite("Montage V1")
struct EditingV1Tests {
    @Test func effectsAndStickersGetTheirOwnTracks() {
        var (p, video, _, _) = Project.sample()
        _ = p.addMedia(video, at: nil)
        let e = p.addEffectClip(EffectCatalog.all[0].id, name: "Éclat", at: RTime(seconds: 1))
        let s = p.addSticker(StickerCatalog.all[0].id, name: "Autocollant", color: .white, at: RTime(seconds: 1))
        let f = p.addFilterClip(FilterCatalog.all[0].id, name: "Filtre", at: .zero)
        p.normalize(magnetic: true)
        #expect(p.trackIndex(of: e).map { p.tracks[$0].kind } == .effect)
        #expect(p.trackIndex(of: f).map { p.tracks[$0].kind } == .effect)
        #expect(p.trackIndex(of: s).map { p.tracks[$0].kind } == .sticker)
        // Deux clips d'effet qui ne se chevauchent pas partagent la même piste.
        let e2 = p.addEffectClip(EffectCatalog.all[0].id, name: "Éclat", at: RTime(seconds: 6))
        #expect(p.trackIndex(of: e2) == p.trackIndex(of: e))
    }

    @Test func transitionsEverywhere() {
        var (p, video, _, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        let b = p.addMedia(video, at: nil)!
        let c = p.addMedia(video, at: nil)!
        p.setTransitionEverywhere("fondu", duration: RTime(seconds: 0.5))
        p.normalize(magnetic: true)
        #expect(p.clip(a)?.transitionIn == nil, "Pas de transition avant le premier clip")
        #expect(p.clip(b)?.transitionIn?.type == "fondu")
        #expect(p.clip(c)?.transitionIn?.type == "fondu")
        p.setTransition(nil, on: b)
        #expect(p.clip(b)?.transitionIn == nil)
    }

    @Test func textStyles() {
        #expect(TextStyleCatalog.all.count == 50)
        #expect(Set(TextStyleCatalog.all.map(\.id)).count == 50)
        for style in TextStyleCatalog.all {
            #expect(TextRenderer.render(style.content, canvas: CGSize(width: 320, height: 180)) != nil, "\(style.name)")
        }
    }

    @Test func catalogThumbnailsRender() async {
        let effect = await CatalogThumbnails.load("test-effet") { f, base in CatalogThumbnails.effect(EffectCatalog.all[0], frame: f, frames: 1, base: base) }
        #expect(effect.count == 1)
        let transition = await CatalogThumbnails.load("test-transition", frames: 4) { f, base in
            CatalogThumbnails.transition(TransitionCatalog.all[0], frame: f, frames: 4, base: base)
        }
        #expect(transition.count == 4)
    }
}
