import Foundation

/// 入力イベント列。`--record` の出力と `e2e/fixtures/*.json` が同じ形式。
public struct Recording: Codable {
    public struct Event: Codable {
        public var t: Double
        public var device: Int?
        public var touches: [Touch]?
        /// "down" / "dragged" / "up"
        public var mouse: String?

        public init(t: Double, device: Int? = nil, touches: [Touch]? = nil, mouse: String? = nil) {
            self.t = t
            self.device = device
            self.touches = touches
            self.mouse = mouse
        }
    }

    public struct Expectation: Codable, Equatable {
        public var actions: [Action]
        /// 認識したジェスチャー（= ハプティックを鳴らすタイミング）。省略時は検証しない
        public var triggers: [Trigger]?
        /// mouse イベントごとの判定（省略時は検証しない）
        public var mouse: [MouseDecision]?
        /// mouse / trigger / action を起きた順に並べたもの（省略時は検証しない）。
        /// 左クリックの判定を押す力のフレームまで待たせたときは、その down の前に "wait" が入る
        public var timeline: [String]?
    }

    public var name: String
    /// docs/failure-modes.md の番号
    public var failureModes: [Int]?
    public var events: [Event]
    public var expect: Expectation?

    public init(name: String, events: [Event]) {
        self.name = name
        self.events = events
    }
}

public struct ReplayResult: Codable {
    public var file: String
    public var name: String
    public var failureModes: [Int]
    public var expected: Recording.Expectation?
    public var actual: Recording.Expectation
    public var passed: Bool
}

public enum Replay {
    public static func run(_ recording: Recording, file: String) throws -> ReplayResult {
        let engine = Engine()
        var actions: [Action] = []
        var decisions: [MouseDecision] = []
        var triggers: [Trigger] = []
        var timeline: [String] = []
        engine.onAction = { actions.append($0); timeline.append("action:\($0.rawValue)") }
        engine.onTrigger = { triggers.append($0); timeline.append("trigger:\($0.rawValue)") }

        // 左クリックの判定を押す力の強いフレームまで待たせる（ライブと同じく最大 Engine.maxPressureWait）。
        // 待っている間のフレームは先に流し、押されたフレームか期限で判定する
        var pendingDown: Double?
        func resolveDown(at time: Double) {
            timeline.append("down")
            decisions.append(engine.mouseDown(time: time))
            pendingDown = nil
        }

        for event in recording.events {
            if let down = pendingDown {
                let deadline = down + Engine.maxPressureWait
                if event.mouse != nil || event.t > deadline { resolveDown(at: min(event.t, deadline)) }
            }
            if let touches = event.touches {
                engine.handleFrame(device: event.device ?? 0, time: event.t, touches: touches)
                if pendingDown != nil, !engine.shouldWaitForPressure(at: event.t) { resolveDown(at: event.t) }
            }
            switch event.mouse {
            case nil: break
            case "down":
                if engine.shouldWaitForPressure(at: event.t) {
                    engine.noteMouseDown(time: event.t)
                    timeline.append("wait")
                    pendingDown = event.t
                } else {
                    resolveDown(at: event.t)
                }
            case "dragged": timeline.append("dragged"); decisions.append(engine.mouseDragged())
            case "up": timeline.append("up"); decisions.append(engine.mouseUp())
            case let other?:
                throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file): 不明な mouse イベント \(other)"])
            }
        }
        if let down = pendingDown { resolveDown(at: down + Engine.maxPressureWait) }

        let actual = Recording.Expectation(actions: actions, triggers: triggers, mouse: decisions, timeline: timeline)
        var passed = true
        if let expect = recording.expect {
            passed = expect.actions == actions
                && (expect.triggers.map { $0 == triggers } ?? true)
                && (expect.mouse.map { $0 == decisions } ?? true)
                && (expect.timeline.map { $0 == timeline } ?? true)
        }
        return ReplayResult(
            file: file, name: recording.name, failureModes: recording.failureModes ?? [],
            expected: recording.expect, actual: actual, passed: passed
        )
    }

    public static func markdownReport(_ results: [ReplayResult], environment: [String: String]) -> String {
        let passed = results.filter(\.passed).count
        var md = "# trackpad-runner E2E レポート\n\n"
        for key in environment.keys.sorted() { md += "- \(key): \(environment[key]!)\n" }
        md += "- 結果: **\(passed)/\(results.count) passed**\n\n"
        md += "| | ケース | 失敗パターン | 期待 | 実際 |\n|---|---|---|---|---|\n"
        for r in results {
            let fm = r.failureModes.map { "#\($0)" }.joined(separator: " ")
            md += "| \(r.passed ? "✅" : "❌") | \(r.name) | \(fm) | \(describe(r.expected)) | \(describe(r.actual)) |\n"
        }
        return md
    }

    private static func describe(_ e: Recording.Expectation?) -> String {
        guard let e else { return "—" }
        let actions = e.actions.isEmpty ? "なし" : e.actions.map(\.rawValue).joined(separator: ", ")
        var parts = ["actions: \(actions)"]
        if let triggers = e.triggers {
            parts.append("haptic: " + (triggers.isEmpty ? "なし" : triggers.map(\.rawValue).joined(separator: ", ")))
        }
        if let mouse = e.mouse, !mouse.isEmpty {
            parts.append("mouse: " + mouse.map(\.rawValue).joined(separator: " → "))
        }
        if let timeline = e.timeline, timeline.contains(where: { $0.contains(":") || $0 == "wait" }) {
            parts.append("順序: " + timeline.joined(separator: " → "))
        }
        return parts.joined(separator: " / ")
    }
}
