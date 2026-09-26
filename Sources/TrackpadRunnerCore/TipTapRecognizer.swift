import Foundation

/// TipTap左（2本指固定）: 2本の指を置いたまま、その左側を1本指で短くタップする。
/// 1デバイスにつき1インスタンス。
///
/// 判定の流れは BTT 6.723 の TipTap（ID 132）と同じ。
/// 1. 2本指になった時刻を「準備」として記録する
/// 2. 3本指のフレームで、準備から readyDelay を超えていれば候補にする（3本目はそれより前に置いてもよい）
/// 3. タップした指だけが離れて2本に戻ったとき、候補から maxTapDuration 未満なら発火する
public final class TipTapRecognizer {
    public struct Config {
        // 値はすべて BTT 6.723 と同じ

        /// 2本指になってから、3本目を候補にできるまでの時間
        public var readyDelay = 0.2
        /// 候補になってから、タップした指が離れるまでの最長時間
        public var maxTapDuration = 0.25
        /// 候補の時点と離した時点で、固定側の左端の x がずれてよい量（2本指スクロール中の誤発火を防ぐ）
        public var maxAnchorShift = 0.1
        /// タップした指が、固定側の左端よりどれだけ左にあればよいか（BTTTwoFingerTipTapMinSpread の既定値）
        public var minSpread = 0.03
        /// 3本の指の x の広がりの上限
        public var maxWidth = 0.6
        /// 物理クリックのあと、候補にしない時間（BTT の justClicked。3本指クリックとの二重発火を防ぐ）
        public var clickCooldown = 0.7

        public init() {}
    }

    private struct Candidate {
        var time: Double
        var anchorIDs: Set<Int>
        var anchorLeftX: Double
        var clicked = false
    }

    private let config: Config
    /// 2本指になった時刻。候補にしたら消費し、2本に戻ったときにまた記録する
    private var readyTime: Double?
    /// 直近の2本指フレームの指（固定側）
    private var anchors: [Int: Touch] = [:]
    private var candidate: Candidate?
    private var lastClickTime = -Double.infinity
    private var lastTime = -Double.infinity

    public init(config: Config = .init()) {
        self.config = config
    }

    /// 物理クリックがあったことを伝える。候補中なら TipTap として扱わず、
    /// 候補になる前なら clickCooldown の間は候補にしない（3本指クリックとの二重発火防止）。
    public func noteClick(at time: Double) {
        candidate?.clicked = true
        lastClickTime = time
    }

    /// 触れている指だけを渡す。発火すべきフレームで true を返す。
    public func feed(time: Double, touching: [Touch]) -> Bool {
        // タイムスタンプが巻き戻ったら状態を捨ててやり直す
        if time < lastTime {
            readyTime = nil
            anchors = [:]
            candidate = nil
            lastClickTime = -.infinity
        }
        lastTime = time

        let ids = Set(touching.map(\.id))
        var fired = false

        switch touching.count {
        case 2:
            if let c = candidate {
                // 固定側が残ったまま、タップした指だけが離れた
                if ids == c.anchorIDs, let left = touching.map(\.x).min() {
                    fired = !c.clicked
                        && time - c.time < config.maxTapDuration
                        && abs(left - c.anchorLeftX) <= config.maxAnchorShift
                }
                candidate = nil
            }
            if readyTime == nil { readyTime = time }
            anchors = Dictionary(touching.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        case 3:
            guard candidate == nil,
                  let ready = readyTime, time - ready > config.readyDelay,
                  time - lastClickTime > config.clickCooldown,
                  anchors.count == 2, anchors.keys.allSatisfy(ids.contains),
                  let tap = touching.first(where: { anchors[$0.id] == nil }),
                  let anchorLeft = anchors.values.map(\.x).min(),
                  let minX = touching.map(\.x).min(), let maxX = touching.map(\.x).max(),
                  maxX - minX < config.maxWidth,
                  tap.x < anchorLeft - config.minSpread
            else { break }
            candidate = Candidate(time: time, anchorIDs: Set(anchors.keys), anchorLeftX: anchorLeft)
            readyTime = nil

        default:
            candidate = nil
            readyTime = nil
            anchors = [:]
        }
        return fired
    }
}
