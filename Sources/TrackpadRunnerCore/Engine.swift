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

/// 認識したジェスチャー。ハプティックはこの単位で鳴らす。
public enum Trigger: String, Codable, Equatable, CaseIterable {
    case threeFingerClick
    case fourFingerClick
    case tipTapLeft
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
    public var onTrigger: (Trigger) -> Void = { _ in }
    /// 直近の mouseDown 時点の指の本数（ログ用）
    public private(set) var fingerCountAtLastClick = 0

    private enum Press { case middle, shortcut }

    /// これより古いフレームの指の本数はクリックの判定に使わない（コールバックが止まった場合の保険）
    public static let frameFreshness = 0.25

    private var touchingCount: [Int: Int] = [:]
    private var lastFrameTime: [Int: Double] = [:]
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
        lastFrameTime[device] = time

        let recognizer = tipTaps[device] ?? TipTapRecognizer(config: tipTapConfig)
        tipTaps[device] = recognizer
        if recognizer.feed(time: time, touching: touching), isEnabled {
            onTrigger(.tipTapLeft)
            onAction(.middleClick)
        }
    }

    /// device: ボタンが押されたトラックパッド。分からない場合（マウスのクリックなど）は nil で、その場合は常にそのまま通す。
    public func mouseDown(time: Double, device: Int?) -> MouseDecision {
        for recognizer in tipTaps.values { recognizer.noteClick() }
        fingerCountAtLastClick = device.map { freshTouchingCount(device: $0, at: time) } ?? 0
        guard isEnabled else { press = nil; return .passThrough }

        switch fingerCountAtLastClick {
        case 3:
            press = .middle
            return .convertToMiddle
        case 4:
            press = .shortcut
            return .swallow
        default:
            press = nil
            return .passThrough
        }
    }

    public func mouseDragged() -> MouseDecision {
        decision(for: press)
    }

    /// BTT と同じく、ハプティックと動作は離したときに出す（押したときは通常のクリック感だけ）。
    public func mouseUp() -> MouseDecision {
        defer { press = nil }
        switch press {
        case .middle:
            onTrigger(.threeFingerClick)
        case .shortcut:
            onTrigger(.fourFingerClick)
            onAction(.screenshotShortcut)
        case nil:
            break
        }
        return decision(for: press)
    }

    /// device の指の本数。最後のフレームが古ければ 0。
    public func freshTouchingCount(device: Int, at time: Double) -> Int {
        guard let last = lastFrameTime[device], time - last <= Self.frameFreshness else { return 0 }
        return touchingCount[device] ?? 0
    }

    /// 新しいフレームで3本以上触れているトラックパッドがあるか（ボタン押下の通知を待つかどうかの判断用）
    public func hasFreshMultiFingerContact(at time: Double) -> Bool {
        touchingCount.keys.contains { freshTouchingCount(device: $0, at: time) >= 3 }
    }

    private func decision(for press: Press?) -> MouseDecision {
        switch press {
        case .middle: .convertToMiddle
        case .shortcut: .swallow
        case nil: .passThrough
        }
    }
}
