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
        engine.onAction = { actions.append($0) }
        engine.onTrigger = { triggers.append($0) }

        for event in recording.events {
            if let touches = event.touches {
                engine.handleFrame(device: event.device ?? 0, time: event.t, touches: touches)
            }
            switch event.mouse {
            case nil: break
            case "down": decisions.append(engine.mouseDown())
            case "dragged": decisions.append(engine.mouseDragged())
            case "up": decisions.append(engine.mouseUp())
            case let other?:
                throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file): 不明な mouse イベント \(other)"])
            }
        }

        let actual = Recording.Expectation(actions: actions, triggers: triggers, mouse: decisions)
        var passed = true
        if let expect = recording.expect {
            passed = expect.actions == actions
                && (expect.triggers.map { $0 == triggers } ?? true)
                && (expect.mouse.map { $0 == decisions } ?? true)
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
        return parts.joined(separator: " / ")
    }
}
