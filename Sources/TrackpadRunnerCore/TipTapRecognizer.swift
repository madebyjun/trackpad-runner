import Foundation

/// TipTap左（2本指固定）: 2本の指を置いたまま、その左側を1本指で短くタップする。
/// 1デバイスにつき1インスタンス。
public final class TipTapRecognizer {
    public struct Config {
        // 固定側の最短時間・タップの最長時間・固定側の許容移動量は BTT 6.723 の TipTap（2本指固定）と同じ値

        /// 固定側の指が、タップ開始前から置かれている必要がある最短時間
        public var minAnchorAge = 0.2
        /// タップとみなす最長の接触時間
        public var maxTapDuration = 0.25
        /// タップした指の許容移動量（正規化座標）
        public var maxTapMove = 0.04
        /// 固定側の指の許容移動量（2本指スクロール中の誤発火を防ぐ）
        public var maxAnchorMove = 0.1
        /// 固定側の最も左の指より、どれだけ左にあればよいか
        public var leftMargin = 0.02

        public init() {}
    }

    private struct Contact {
        var since: Double
        var x: Double
        var y: Double
    }

    private struct Candidate {
        var id: Int
        var start: Double
        var x: Double
        var y: Double
        var anchors: [Int: Contact]
        var clicked = false
    }

    private let config: Config
    private var contacts: [Int: Contact] = [:]
    private var candidate: Candidate?
    private var lastTime = -Double.infinity

    public init(config: Config = .init()) {
        self.config = config
    }

    /// タップ中に物理クリックがあった場合は TipTap として扱わない（3本指クリックとの二重発火防止）。
    public func noteClick() {
        candidate?.clicked = true
    }

    /// 触れている指だけを渡す。発火すべきフレームで true を返す。
    public func feed(time: Double, touching: [Touch]) -> Bool {
        // タイムスタンプが巻き戻ったら状態を捨ててやり直す
        if time < lastTime {
            contacts = [:]
            candidate = nil
        }
        lastTime = time

        let current = Dictionary(touching.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = current.keys.filter { contacts[$0] == nil }
        var fired = false

        if let c = candidate {
            if !newIDs.isEmpty {
                // タップ中に別の指が加わった
                candidate = nil
            } else if !c.anchors.keys.allSatisfy({ current[$0] != nil }) || anchorsMoved(c, current) {
                candidate = nil
            } else if let tap = current[c.id] {
                if time - c.start > config.maxTapDuration
                    || hypot(tap.x - c.x, tap.y - c.y) > config.maxTapMove {
                    candidate = nil
                }
            } else {
                // タップした指が離れた
                fired = !c.clicked && time - c.start <= config.maxTapDuration
                candidate = nil
            }
        } else if newIDs.count == 1, let newID = newIDs.first, let tap = current[newID] {
            let anchors = contacts.filter { current[$0.key] != nil }
            if anchors.count == 2, current.count == 3,
               anchors.values.allSatisfy({ time - $0.since >= config.minAnchorAge }),
               let leftmost = anchors.values.map(\.x).min(),
               tap.x < leftmost - config.leftMargin {
                candidate = Candidate(id: newID, start: time, x: tap.x, y: tap.y, anchors: anchors)
            }
        }

        var next: [Int: Contact] = [:]
        for (id, t) in current {
            next[id] = Contact(since: contacts[id]?.since ?? time, x: t.x, y: t.y)
        }
        contacts = next
        return fired
    }

    private func anchorsMoved(_ c: Candidate, _ current: [Int: Touch]) -> Bool {
        c.anchors.contains { id, start in
            guard let now = current[id] else { return true }
            return hypot(now.x - start.x, now.y - start.y) > config.maxAnchorMove
        }
    }
}
