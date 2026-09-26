import CMultitouch
import Foundation
import TrackpadRunnerCore

/// BTT の組み込みハプティックを再現したもの。
/// 波形・パルス列・間隔は BTT 6.723 の実装（BTTTouch actuatey:onAllDevices:onlyOnBuiltIn:）から読み取った値。
enum HapticPattern: Int32, CaseIterable {
    case lightThenStrong = 3
    case doubleStrong = 4
    case springLight = 6

    var name: String {
        switch self {
        case .lightThenStrong: "Light Then Strong"
        case .doubleStrong: "Double Strong"
        case .springLight: "Spring Light"
        }
    }

    /// (直前のパルスからの待ち時間 [µs], パルス)
    fileprivate var steps: [(delay: UInt32, pulse: Pulse)] {
        let d = Haptics.pulseInterval
        switch self {
        case .doubleStrong:
            return [(0, .strong), (d, .strong), (0, .strong), (d, .strong)]
        case .lightThenStrong:
            return [(0, .light), (d, .light), (d + 50_000, .light),
                    (0, .strong), (d, .strong), (d + 30_000, .strong)]
        case .springLight:
            return [(0, .light)] + Array(repeating: (d, .light), count: 15)
        }
    }
}

/// ジェスチャーごとのハプティック。BTT で設定していたもの（BTTGestureForceFeedbackPattern）と同じ。
let hapticPatterns: [Trigger: HapticPattern] = [
    .threeFingerClick: .doubleStrong,
    .fourFingerClick: .springLight,
    .tipTapLeft: .lightThenStrong,
]

fileprivate enum Pulse { case strong, light }

enum Haptics {
    /// BTT のパルス間隔の既定値（12ms）
    static let pulseInterval: UInt32 = 12_000

    // イベントタップや MultitouchSupport のスレッドを止めないよう、専用のキューで鳴らす
    private static let queue = DispatchQueue(label: "com.madebyjun.trackpad-runner.haptics")

    private static let strong: CFTypeRef? = cmt_actuation_create(waveform(amplitude: 200, baseMedium: 1.2, toneAmplitude: 0.035, toneDelay: 1.5) as CFDictionary)?.takeRetainedValue()
    private static let light: CFTypeRef? = cmt_actuation_create(waveform(amplitude: 20, baseMedium: 1.0, toneAmplitude: 0.015, toneDelay: 1) as CFDictionary)?.takeRetainedValue()

    static func play(_ pattern: HapticPattern) {
        queue.async {
            for step in pattern.steps {
                if step.delay > 0 { usleep(step.delay) }
                _ = cmt_actuation_play(step.pulse == .strong ? strong : light)
            }
        }
    }

    /// 同期的に鳴らし、最初のパルスを鳴らせたデバイス数を返す（CLI の確認用）。
    static func playNow(_ pattern: HapticPattern) -> Int32 {
        var first: Int32 = 0
        for (i, step) in pattern.steps.enumerated() {
            if step.delay > 0 { usleep(step.delay) }
            let count = cmt_actuation_play(step.pulse == .strong ? strong : light)
            if i == 0 { first = count }
        }
        return first
    }

    private static func waveform(amplitude: Int, baseMedium: Double, toneAmplitude: Double, toneDelay: Double) -> [String: Any] {
        let tone: [String: Any] = [
            "Amplitude": toneAmplitude,
            "DelayMS": toneDelay,
            "DurationMS": 2,
            "FrequencykHz": 1.6,
            "Type": "Sawtooth",
        ]
        return [
            "ActuationID": 6,
            "BaseWaveform": ["Amplitude": amplitude, "DurationMS": 20, "Type": "Gaussian"],
            "BaseMultipliers": ["Light": 1.4, "Medium": baseMedium, "Firm": 1.3],
            "Tones": [tone, tone],
            "ToneMultipliers": ["Light": 0.2, "Medium": 0.4, "Firm": 0.4],
        ]
    }
}
