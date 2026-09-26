import Foundation

/// トラックパッド上の1本の指。座標は 0..1（原点は左下）。
public struct Touch: Codable, Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    /// MultitouchSupport の接触状態。省略時は 5 (touching)。
    public var state: Int
    /// 押す力（Force Touch のトラックパッドのみ）。押す力が分からないトラックパッドでは nil。
    public var pressure: Double?

    public init(id: Int, x: Double, y: Double, state: Int = 5, pressure: Double? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.state = state
        self.pressure = pressure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        state = try c.decodeIfPresent(Int.self, forKey: .state) ?? 5
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure)
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
    /// 直近の mouseDown のクリック元のトラックパッド（ログ用）。分からなければ nil
    public private(set) var sourceAtLastClick: Int?
    /// 直近の mouseDown の時点で、クリック元が押され始めてからの時間（ログ用。押す力で決めたときだけ）
    public private(set) var pressAgeAtLastClick: Double?

    private enum Press { case middle, shortcut }

    /// これより古いフレームの指の本数はクリックの判定に使わない（コールバックが止まった場合の保険）
    public static let frameFreshness = 0.25
    /// この押す力以上の指があるトラックパッドをクリック元とみなす。
    /// 実機（内蔵 Force Touch トラックパッド）で、指を置いただけは 0〜35 程度、クリックはピークが 100〜130 だった
    public static let clickPressure = 50.0
    /// 押す力が clickPressure 以上だった最後のフレームがこの時間以内なら、クリック元とみなす
    public static let pressWindow = 0.08
    /// 押し始め（押す力が clickPressure を超えた時点）からこの時間を過ぎたら、クリック元とみなさない。
    /// 押し続けているだけ（クリックしない）のトラックパッドが、あとのマウスのクリックのクリック元にならないようにする。
    /// ゆっくり押し込んだクリックを見逃さないよう、長めにとる
    public static let maxPressAge = 0.2
    /// 押す力の強いフレームが左クリックより遅れて届く場合に、待つ最長時間
    public static let maxPressureWait = 0.03

    private var touchingCount: [Int: Int] = [:]
    private var lastFrameTime: [Int: Double] = [:]
    /// 押す力が分かるトラックパッド（押す力付きのフレームを受け取ったもの）
    private var forceDevices: Set<Int> = []
    /// 押す力が clickPressure 以上だった最後のフレームの時刻
    private var pressedTime: [Int: Double] = [:]
    /// 押す力が clickPressure を超えた（押され始めた）時刻。下回ったら次に超えたときに測り直す
    private var pressStartTime: [Int: Double] = [:]
    /// 直前のフレームで押す力が clickPressure 以上だったトラックパッド
    private var pressedNow: Set<Int> = []
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
        if touching.contains(where: { $0.pressure != nil }) { forceDevices.insert(device) }
        // 3本指クリックでも強く押すのは1本だけなので、指ごとの最大値を見る（BTT と同じ）
        if let pressure = touching.compactMap(\.pressure).max(), pressure >= Self.clickPressure {
            if !pressedNow.contains(device) { pressStartTime[device] = time }
            pressedNow.insert(device)
            pressedTime[device] = time
        } else {
            pressedNow.remove(device)
        }

        let recognizer = tipTaps[device] ?? TipTapRecognizer(config: tipTapConfig)
        tipTaps[device] = recognizer
        if recognizer.feed(time: time, touching: touching), isEnabled {
            onTrigger(.tipTapLeft)
            onAction(.middleClick)
        }
    }

    /// 左クリックが届いたことを TipTap に伝える。押す力のフレームを待つ前に呼ぶこと
    /// （待っている間に TipTap左が発火して、クリックと二重にならないように）
    public func noteMouseDown(time: Double) {
        for recognizer in tipTaps.values { recognizer.noteClick(at: time) }
    }

    public func mouseDown(time: Double) -> MouseDecision {
        noteMouseDown(time: time)
        sourceAtLastClick = clickSource(at: time)
        pressAgeAtLastClick = sourceAtLastClick.flatMap { device in
            pressedDevices(at: time).contains(device) ? pressStartTime[device].map { time - $0 } : nil
        }
        fingerCountAtLastClick = sourceAtLastClick.map { touchingCount[$0] ?? 0 } ?? 0
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

    /// 左クリックの判定を、押す力の強いフレームが届くまで待つべきか。
    /// 3本以上触れている Force Touch のトラックパッドがあるのに、まだどれも押されていないときだけ待つ
    /// （それ以外で待つと、マウスや1本指の通常のクリックが遅れる）
    public func shouldWaitForPressure(at time: Double) -> Bool {
        guard isEnabled, pressedDevices(at: time).isEmpty else { return false }
        return forceDevices.contains { freshTouchingCount(device: $0, at: time) >= 3 }
    }

    /// CGEvent にはクリック元のトラックパッドの情報が無いので、フレームから推定する。
    /// 1. Force Touch のトラックパッドで、最近強く押されたもの（複数なら押され始めたのが最も新しいもの）
    /// 2. 新しい接触があるのが、押す力が分からないトラックパッド1台だけならそれ
    ///    （Force Touch の方にも触れているなら、どちらのクリックか分からない）
    /// どれにも当たらなければ nil（マウスのクリックなど。通常のクリックを握りつぶさないよう、そのまま通す）
    private func clickSource(at time: Double) -> Int? {
        if let pressed = pressedDevices(at: time).max(by: { (pressStartTime[$0]!, $0) < (pressStartTime[$1]!, $1) }) {
            return pressed
        }
        let touched = touchingCount.keys.filter { freshTouchingCount(device: $0, at: time) > 0 }
        return touched.count == 1 && !forceDevices.contains(touched[0]) ? touched[0] : nil
    }

    private func pressedDevices(at time: Double) -> [Int] {
        forceDevices.filter { device in
            freshTouchingCount(device: device, at: time) > 0
                && (pressedTime[device].map { time - $0 <= Self.pressWindow } ?? false)
                && (pressStartTime[device].map { time - $0 <= Self.maxPressAge } ?? false)
        }
    }

    /// 新しいフレームで触れている指の本数（古いフレームなら 0）
    private func freshTouchingCount(device: Int, at time: Double) -> Int {
        guard let last = lastFrameTime[device], time - last <= Self.frameFreshness else { return 0 }
        return touchingCount[device] ?? 0
    }

    /// 押下中の判定を捨てる（クリックの横取りをやめるとき用）。以後の解放はそのまま通す。
    public func cancelPress() {
        press = nil
    }

    private func decision(for press: Press?) -> MouseDecision {
        switch press {
        case .middle: .convertToMiddle
        case .shortcut: .swallow
        case nil: .passThrough
        }
    }
}
