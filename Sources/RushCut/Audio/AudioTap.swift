import Foundation
import AVFoundation

/// Traitement audio en temps réel branché sur la composition (aperçu et export).
/// Complété au lot V1-C (gain au-delà de 0 dB, réduction de bruit, effets de voix).
enum AudioTap {
    static func attach(to params: AVMutableAudioMixInputParameters, segments: [AudioSegment]) {}
}
