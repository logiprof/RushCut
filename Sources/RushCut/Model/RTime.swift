import Foundation
import CoreMedia

/// Temps exact du projet : nombre de « ticks » à 60 000 par seconde.
/// 60 000 est divisible par 24, 25, 30, 50 et 60 : chaque image tombe sur un nombre entier de ticks,
/// ce qui évite tout décalage d'une image dû aux nombres à virgule.
struct RTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    static let timescale: Int64 = 60_000

    var ticks: Int64

    init(ticks: Int64) { self.ticks = ticks }

    init(seconds: Double) {
        guard seconds.isFinite else { self.ticks = 0; return }
        self.ticks = Int64((seconds * Double(RTime.timescale)).rounded())
    }

    init(_ time: CMTime) {
        if time.isValid && time.isNumeric {
            self.ticks = time.convertScale(Int32(RTime.timescale), method: .roundHalfAwayFromZero).value
        } else {
            self.ticks = 0
        }
    }

    init(from decoder: Decoder) throws {
        ticks = try decoder.singleValueContainer().decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }

    static let zero = RTime(ticks: 0)

    var seconds: Double { Double(ticks) / Double(RTime.timescale) }
    var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(RTime.timescale)) }

    static func ticksPerFrame(fps: Int) -> Int64 { timescale / Int64(max(fps, 1)) }

    /// Durée d'une image à la fréquence donnée.
    static func frame(fps: Int) -> RTime { RTime(ticks: ticksPerFrame(fps: fps)) }

    static func frames(_ count: Int64, fps: Int) -> RTime { RTime(ticks: count * ticksPerFrame(fps: fps)) }

    /// Arrondit à l'image la plus proche.
    func snapped(fps: Int) -> RTime {
        let f = RTime.ticksPerFrame(fps: fps)
        let n = (Double(ticks) / Double(f)).rounded()
        return RTime(ticks: Int64(n) * f)
    }

    func frameIndex(fps: Int) -> Int64 { ticks / RTime.ticksPerFrame(fps: fps) }

    static func < (lhs: RTime, rhs: RTime) -> Bool { lhs.ticks < rhs.ticks }
    static func + (lhs: RTime, rhs: RTime) -> RTime { RTime(ticks: lhs.ticks + rhs.ticks) }
    static func - (lhs: RTime, rhs: RTime) -> RTime { RTime(ticks: lhs.ticks - rhs.ticks) }
    static func += (lhs: inout RTime, rhs: RTime) { lhs.ticks += rhs.ticks }
    static func -= (lhs: inout RTime, rhs: RTime) { lhs.ticks -= rhs.ticks }
    static func * (lhs: RTime, rhs: Double) -> RTime { RTime(ticks: Int64((Double(lhs.ticks) * rhs).rounded())) }

    var description: String { String(format: "%.3f s", seconds) }

    /// Minutage « hh:mm:ss:ii » (ii = numéro d'image dans la seconde).
    func timecode(fps: Int) -> String {
        let rate = Int64(max(fps, 1))
        let total = max(0, frameIndex(fps: fps))
        let frames = total % rate
        let allSeconds = total / rate
        let s = allSeconds % 60
        let m = (allSeconds / 60) % 60
        let h = allSeconds / 3600
        return String(format: "%02lld:%02lld:%02lld:%02lld", h, m, s, frames)
    }

    /// Texte court pour la règle et les durées (« 1:05 », « 12,4 s »).
    var shortLabel: String {
        let total = max(0, seconds)
        if total < 60 {
            return String(format: "%.1f s", total).replacingOccurrences(of: ".", with: ",")
        }
        let m = Int(total) / 60
        let s = Int(total) % 60
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }
}
