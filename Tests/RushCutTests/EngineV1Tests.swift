import Foundation
import AVFoundation
import CoreImage
import Testing
@testable import RushCut

/// Rendu d'une image Core Image en pixels (pour vérifier les effets).
enum Pixels {
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func render(_ image: CIImage, size: CGSize) -> CGImage? {
        context.createCGImage(image.cropped(to: CGRect(origin: .zero, size: size)), from: CGRect(origin: .zero, size: size))
    }

    static func rgba(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    /// Image de test : dégradé coloré avec un disque blanc.
    static func testImage(_ size: CGSize = CGSize(width: 160, height: 90)) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: size.height),
            "inputColor0": CIColor(red: 0.9, green: 0.3, blue: 0.2), "inputColor1": CIColor(red: 0.2, green: 0.4, blue: 0.9),
        ])!.outputImage!.cropped(to: rect)
        return gradient
    }
}

@Suite("Images clés et vitesse")
struct KeyframeTests {
    @Test func interpolation() {
        var clip = Clip()
        clip.duration = RTime(seconds: 4)
        clip.keyframes[KeyProp.scale.rawValue] = [
            Keyframe(time: .zero, value: 1, interpolation: .lineaire),
            Keyframe(time: RTime(seconds: 2), value: 3, interpolation: .lineaire),
        ]
        #expect(clip.value(.scale, at: .zero) == 1)
        #expect(abs(clip.value(.scale, at: RTime(seconds: 1)) - 2) < 0.001)
        #expect(clip.value(.scale, at: RTime(seconds: 3)) == 3)
        #expect(clip.value(.opacity, at: RTime(seconds: 1)) == 1, "Sans image clé : valeur de base")
    }

    @Test func settingWithKeyframesCreatesKeyframe() {
        var clip = Clip()
        clip.toggleKeyframe(.positionX, at: .zero, fps: 30)
        clip.set(.positionX, 0.5, at: RTime(seconds: 2), fps: 30)
        #expect(clip.keyframes(.positionX).count == 2)
        clip.set(.positionX, 0.25, at: RTime(seconds: 2), fps: 30)
        #expect(clip.keyframes(.positionX).count == 2)
        #expect(clip.value(.positionX, at: RTime(seconds: 2)) == 0.25)
        clip.toggleKeyframe(.positionX, at: RTime(seconds: 2), fps: 30)
        #expect(clip.keyframes(.positionX).count == 1)
    }

    @Test func splitShiftsKeyframes() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.updateClip(id) { $0.keyframes["scale"] = [Keyframe(time: RTime(seconds: 6), value: 2)] }
        let right = p.split(at: RTime(seconds: 4), clipIDs: [])
        #expect(p.clip(right[0])?.keyframes(.scale).first?.time == RTime(seconds: 2))
    }

    @Test func speedChangesDuration() {
        var (p, video, _, _) = Project.sample()
        let id = p.addMedia(video, at: nil)!
        p.setSpeed(id, rate: 2)
        #expect(p.clip(id)?.duration == RTime(seconds: 5))
        p.setSpeed(id, rate: 0.5)
        #expect(p.clip(id)?.duration == RTime(seconds: 20))
        // Couper à mi-chemin : la seconde moitié commence à 5 s de la source.
        let right = p.split(at: RTime(seconds: 10), clipIDs: [])
        #expect(p.clip(right[0])?.sourceIn == RTime(seconds: 5))
    }

    @Test func transitionOverlapsMainTrack() {
        var (p, video, _, _) = Project.sample()
        let a = p.addMedia(video, at: nil)!
        let b = p.addMedia(video, at: nil)!
        p.updateClip(b) { $0.transitionIn = Transition(type: "fondu", duration: RTime(seconds: 1)) }
        p.normalize(magnetic: true)
        #expect(p.clip(a)?.start == .zero)
        #expect(p.clip(b)?.start == RTime(seconds: 9))
        #expect(p.duration == RTime(seconds: 19))
        // Transition trop longue : limitée à la moitié du clip le plus court.
        p.updateClip(b) { $0.transitionIn?.duration = RTime(seconds: 30) }
        p.normalize(magnetic: true)
        #expect(p.clip(b)?.transitionIn?.duration == RTime(seconds: 5))
    }

    @Test func animationsAreIdentityAtRest() {
        for def in AnimationCatalog.all {
            switch def.kind {
            case .entree:
                let s = def.state(1)
                #expect(abs(s.opacity - 1) < 0.02 && abs(s.scale - 1) < 0.05 && abs(s.dx) < 0.01 && abs(s.dy) < 0.02, "\(def.id)")
            case .sortie:
                let s = def.state(0)
                #expect(abs(s.opacity - 1) < 0.02 && abs(s.scale - 1) < 0.05 && abs(s.dx) < 0.01 && abs(s.dy) < 0.02, "\(def.id)")
            case .boucle:
                #expect(def.state(0.3).scale.isFinite, "\(def.id)")
            }
        }
        #expect(AnimationCatalog.all.count >= 30)
    }
}

@Suite("Catalogues", .serialized)
struct CatalogTests {
    let size = CGSize(width: 160, height: 90)

    @Test func counts() {
        #expect(FilterCatalog.all.count >= 60)
        #expect(TransitionCatalog.all.count >= 60)
        #expect(StickerCatalog.all.count >= 50)
        #expect(AnimationCatalog.all.count + TextAnimationCatalog.all.count >= 60)
        let v1 = EffectCatalog.all.filter { ![.stylisation, .corps, .saisons].contains($0.category) }
        #expect(v1.count >= 137)
        #expect(Set(EffectCatalog.all.map(\.id)).count == EffectCatalog.all.count, "Identifiants uniques")
        #expect(Set(TransitionCatalog.all.map(\.id)).count == TransitionCatalog.all.count)
        #expect(Set(FilterCatalog.all.map(\.id)).count == FilterCatalog.all.count)
    }

    @Test func everyEffectRenders() {
        let input = Pixels.testImage(size)
        for def in EffectCatalog.all {
            var ctx = EffectContext(local: 0.7, duration: 3, frame: 21, intensity: 1, params: [:], canvas: size)
            ctx.region = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
            if let f = def.image {
                let out = f(input, ctx).cropped(to: input.extent)
                #expect(Pixels.render(out, size: size) != nil, "Effet \(def.id)")
            }
            if let c = def.camera {
                let s = c(ctx)
                #expect(s.scale.isFinite && s.dx.isFinite && s.rotation.isFinite, "Caméra \(def.id)")
            }
        }
    }

    @Test func everyTransitionRenders() {
        let a = Pixels.testImage(size)
        let b = CI.solid(RGBA(r: 0, g: 1, b: 0), CGRect(origin: .zero, size: size))
        for def in TransitionCatalog.all {
            for p in [0.0, 0.5, 1.0] {
                let out = TransitionCatalog.render(def.id, from: a, to: b, progress: p, extent: CGRect(origin: .zero, size: size), frame: 3)
                #expect(Pixels.render(out, size: size) != nil, "Transition \(def.id) à \(p)")
            }
            // À la fin, l'image d'arrivée (verte) est visible au centre.
            let end = TransitionCatalog.render(def.id, from: a, to: b, progress: 1, extent: CGRect(origin: .zero, size: size), frame: 3)
            let px = Pixels.rgba(Pixels.render(end, size: size)!, x: 80, y: 45)
            #expect(px.g > 150, "Fin de \(def.id) : \(px)")
        }
    }

    @Test func everyFilterRenders() {
        let input = Pixels.testImage(size)
        for def in FilterCatalog.all {
            let out = FilterCatalog.apply(FilterRef(id: def.id, intensity: 1), to: input, frame: 1)
            #expect(Pixels.render(out, size: size) != nil, "Filtre \(def.id)")
        }
    }

    @Test func warmFilterWarms() {
        let gray = CI.solid(RGBA(r: 0.5, g: 0.5, b: 0.5), CGRect(origin: .zero, size: size))
        let warm = Pixels.rgba(Pixels.render(CI.temperature(gray, warmth: 0.8, tint: 0), size: size)!, x: 10, y: 10)
        let cold = Pixels.rgba(Pixels.render(CI.temperature(gray, warmth: -0.8, tint: 0), size: size)!, x: 10, y: 10)
        #expect(warm.r > warm.b, "Chaud : \(warm)")
        #expect(cold.b > cold.r, "Froid : \(cold)")
    }

    @Test func everyStickerRenders() {
        for def in StickerCatalog.all {
            #expect(StickerCatalog.render(def.id, color: RGBA(r: 1, g: 0.8, b: 0.1), canvas: CGSize(width: 1920, height: 1080)) != nil, "Autocollant \(def.id)")
        }
    }

    @Test func chromaKeyRemovesGreen() {
        let rect = CGRect(origin: .zero, size: size)
        let green = CI.solid(RGBA(r: 0.1, g: 0.85, b: 0.2), rect)
        let red = CI.solid(RGBA(r: 0.9, g: 0.1, b: 0.1), CGRect(x: 0, y: 0, width: 80, height: 90))
        let keyed = ChromaKeyer.apply(ChromaKey(), to: red.composited(over: green))
        let img = Pixels.render(keyed.composited(over: CI.solid(.white, rect)), size: size)!
        let left = Pixels.rgba(img, x: 20, y: 45), right = Pixels.rgba(img, x: 140, y: 45)
        #expect(left.r > 180 && left.g < 80, "Le rouge reste : \(left)")
        #expect(right.r > 200 && right.g > 200 && right.b > 200, "Le vert devient transparent : \(right)")
    }

    @Test func circleMask() {
        let rect = CGRect(origin: .zero, size: size)
        let masked = MaskRenderer.apply(Mask(shape: .cercle, width: 0.5, height: 0.8, feather: 0.01), to: CI.solid(.black, rect))
        let img = Pixels.render(masked.composited(over: CI.solid(.white, rect)), size: size)!
        #expect(Pixels.rgba(img, x: 80, y: 45).r < 40, "Centre visible")
        #expect(Pixels.rgba(img, x: 3, y: 3).r > 200, "Coin masqué")
    }

    @Test func textReveal() {
        var text = TextContent()
        text.string = "Bonjour tout le monde"
        text.animation = "texte-machine-normale"
        text.animationDuration = 2
        let half = TextReveal.compute(text, local: 1, clipDuration: 4)
        #expect(half?.visibleLength == 10)
        #expect(TextReveal.compute(text, local: 3, clipDuration: 4) == nil, "Texte complet après l'animation")
        text.animation = "texte-karaoke-normale"
        let k = TextReveal.compute(text, local: 2.1, clipDuration: 4)
        #expect(k?.highlight?.location == 13, "Troisième mot (« le ») à 2,1 s sur 4 mots / 4 s")
        text.string = "1500 vues"
        text.animation = "texte-compteur"
        #expect(TextReveal.compute(text, local: 1, clipDuration: 4)?.displayString == "750 vues", "Moitié de l’animation de 2 s")
    }
}

@Suite("Rendu V1", .serialized)
struct RenderV1Tests {
    @Test func transitionCrossfadesInExport() async throws {
        let dir = TestMedia.tempDirectory()
        let red = try await TestMedia.video(in: dir, name: "rouge.mov", width: 320, height: 180, seconds: 2, bgra: (0, 0, 255, 255))
        let blue = try await TestMedia.video(in: dir, name: "bleu.mov", width: 320, height: 180, seconds: 2, bgra: (255, 0, 0, 255))
        var project = Project()
        project.settings = ProjectSettings(width: 640, height: 360, frameRate: 30)
        for url in [red, blue] { project.media.append(try await MediaAnalyzer.analyze(url: url)) }
        project.addMedia(project.media[0].id, at: nil)
        let b = project.addMedia(project.media[1].id, at: nil)!
        project.updateClip(b) { $0.transitionIn = Transition(type: "fondu", duration: RTime(seconds: 1)) }
        project.normalize(magnetic: true)
        #expect(project.duration == RTime(seconds: 3))
        let out = dir.appendingPathComponent("transition.mp4")
        var settings = ExportSettings(destination: out)
        settings.resolution = .project
        try await Exporter().run(project: project, settings: settings) { _ in }
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 3) < 0.05)
        let mid = TestMedia.pixel(try await TestMedia.frame(of: out, at: 1.5), x: 320, y: 180)
        #expect(mid.r > 70 && mid.r < 190 && mid.b > 70 && mid.b < 190, "Mélange rouge/bleu au milieu : \(mid)")
        let end = TestMedia.pixel(try await TestMedia.frame(of: out, at: 2.7), x: 320, y: 180)
        #expect(end.b > 180 && end.r < 70, "Bleu après la transition : \(end)")
    }

    @Test func speedExport() async throws {
        let dir = TestMedia.tempDirectory()
        let url = try await TestMedia.video(in: dir, seconds: 2)
        var project = Project()
        project.media.append(try await MediaAnalyzer.analyze(url: url))
        let id = project.addMedia(project.media[0].id, at: nil)!
        project.setSpeed(id, rate: 2)
        project.normalize(magnetic: true)
        let built = try await CompositionBuilder.build(project: project)
        #expect(abs(try await built.asset.load(.duration).seconds - 1) < 0.05)
    }

    @Test func keyframedOpacityAndEffectsInRender() async throws {
        var project = Project()
        project.settings = ProjectSettings(width: 320, height: 180, frameRate: 30, backgroundColor: .black)
        var text = TextContent()
        text.string = "Test"
        text.backgroundEnabled = true
        text.backgroundColor = .white
        text.color = .white
        let id = project.addText(text, at: .zero, duration: RTime(seconds: 2))
        project.updateClip(id) { c in
            c.transform.scale = 4
            c.keyframes[KeyProp.opacity.rawValue] = [Keyframe(time: .zero, value: 0, interpolation: .lineaire), Keyframe(time: RTime(seconds: 2), value: 1, interpolation: .lineaire)]
            c.effects = [EffectInstance(type: "lumiere-halo-10")]
        }
        project.normalize(magnetic: true)
        let built = try await CompositionBuilder.build(project: project)
        let instruction = built.videoComposition.instructions.first as! RushInstruction
        let size = CGSize(width: 320, height: 180)
        let early = Pixels.render(RushCompositor.render(plan: instruction.plan, time: RTime(seconds: 0.1), renderSize: size) { _ in nil }, size: size)!
        let late = Pixels.render(RushCompositor.render(plan: instruction.plan, time: RTime(seconds: 1.9), renderSize: size) { _ in nil }, size: size)!
        #expect(Pixels.rgba(early, x: 160, y: 90).r < 60, "Presque transparent au début")
        #expect(Pixels.rgba(late, x: 160, y: 90).r > 180, "Opaque à la fin")
    }
}
