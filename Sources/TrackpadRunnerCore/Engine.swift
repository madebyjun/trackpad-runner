import Foundation

/// トラックパッド上の1本の指。座標は 0..1（原点は左下）。
public struct Touch: Codable, Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    /// MultitouchSupport の接触状態。省略時は 5 (touching)。
    public var state: Int

    public init(id: Int, x: Double, y: Double, state: Int = 5) {
        self.id = id
        self.x = x
        self.y = y
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        state = try c.decodeIfPresent(Int.self, forKey: .state) ?? 5
    }

    /// makeTouch(4) / touching(5) だけを「触れている」とみなす。ホバーや離れかけは数えない。
    public var isTouching: Bool { state == 4 || state == 5 }
}

public enum Action: String, Codable, Equatable {
    case middleClick
    case screenshotShortcut // ⇧⌘5
}

/// 左ボタンイベントをどう扱うか。
public enum MouseDecision: String, Codable, Equatable {
    case passThrough
    case convertToMiddle
    case swallow
}

/// ジェスチャー判定の本体。実機（ライブ）とリプレイの両方がこのクラスを通る。
/// スレッドセーフではないので、呼び出し側で直列化すること。
public final class Engine {
    public var isEnabled = true
    public var onAction: (Action) -> Void = { _ in }

    private enum Press { case middle, shortcut }

    private var touchingCount: [Int: Int] = [:]
    private var tipTaps: [Int: TipTapRecognizer] = [:]
    /// down 時の判定。up / dragged まで保持し、途中で指の本数が変わっても種類を食い違わせない。
    private var press: Press?
    private let tipTapConfig: TipTapRecognizer.Config

    public init(tipTapConfig: TipTapRecognizer.Config = .init()) {
        self.tipTapConfig = tipTapConfig
    }

    public func handleFrame(device: Int, time: Double, touches: [Touch]) {
        let touching = touches.filter(\.isTouching)
        touchingCount[device] = touching.count

        let recognizer = tipTaps[device] ?? TipTapRecognizer(config: tipTapConfig)
        tipTaps[device] = recognizer
        if recognizer.feed(time: time, touching: touching), isEnabled {
            onAction(.middleClick)
        }
    }

    public func mouseDown() -> MouseDecision {
        for recognizer in tipTaps.values { recognizer.noteClick() }
        guard isEnabled else { press = nil; return .passThrough }

        // どのデバイスでクリックされたかは分からないので、最も指が多いデバイスで判定する
        switch touchingCount.values.max() ?? 0 {
        case 3:
            press = .middle
            return .convertToMiddle
        case 4:
            press = .shortcut
            onAction(.screenshotShortcut)
            return .swallow
        default:
            press = nil
            return .passThrough
        }
    }

    public func mouseDragged() -> MouseDecision {
        decision(for: press)
    }

    public func mouseUp() -> MouseDecision {
        defer { press = nil }
        return decision(for: press)
    }

    private func decision(for press: Press?) -> MouseDecision {
        switch press {
        case .middle: .convertToMiddle
        case .shortcut: .swallow
        case nil: .passThrough
        }
    }
}
