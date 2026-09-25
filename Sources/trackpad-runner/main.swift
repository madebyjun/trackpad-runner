import AppKit
import CMultitouch
import Foundation
import TrackpadRunnerCore

let usage = """
使い方:
  trackpad-runner                         メニューバーに常駐して動作する
  trackpad-runner --headless              メニューバー無しで動作する（ターミナルから）
  trackpad-runner --list-devices          トラックパッドの数を表示する
  trackpad-runner --haptic ID             トラックパッドを振動させる（ID を試す用。指を置いたまま実行）
  trackpad-runner --send-shortcut         ⇧⌘5 を送る（アクセシビリティ権限が必要）
  trackpad-runner --record FILE [--seconds N]
                                          実機の入力を N 秒（既定 10）記録して JSON に保存する
  trackpad-runner --replay FILE... [--report-dir DIR]
                                          記録/フィクスチャを判定ロジックに流し、結果を出力する
"""

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func runReplay(_ args: [String]) {
    var files: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == "--report-dir" { i += 2; continue }
        files.append(args[i])
        i += 1
    }
    guard !files.isEmpty else { fail(usage) }

    var results: [ReplayResult] = []
    for file in files {
        do {
            let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            results.append(try Replay.run(recording, file: file))
        } catch {
            fail("\(file): \(error)")
        }
    }

    let environment = [
        "日時": ISO8601DateFormatter().string(from: Date()),
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "トラックパッド数": String(cmt_device_count()),
    ]
    let report = Replay.markdownReport(results, environment: environment)
    print(report)

    if let dir = option("--report-dir", in: args) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try report.write(to: url.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: url.appendingPathComponent("report.json"))
        } catch {
            fail("レポートの書き込みに失敗しました: \(error)")
        }
    }
    exit(results.allSatisfy(\.passed) ? 0 : 1)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "--replay":
    runReplay(Array(args.dropFirst()))

case "--list-devices":
    let count = cmt_device_count()
    if count < 0 { fail(LiveError.multitouchUnavailable.description) }
    print(count)

case "--haptic":
    guard let value = option("--haptic", in: args), let id = Int32(value) else { fail(usage) }
    let count = cmt_actuate(id)
    if count < 0 { fail(LiveError.multitouchUnavailable.description) }
    print("振動させたデバイス数: \(count)")

case "--send-shortcut":
    Output.screenshotShortcut()

case "--record":
    guard let file = option("--record", in: args) else { fail(usage) }
    let seconds = option("--seconds", in: args).flatMap(Double.init) ?? 10
    let recorder = Recorder()
    do {
        try recorder.start(seconds: seconds, output: URL(fileURLWithPath: file))
    } catch {
        fail("\(error)")
    }
    withExtendedLifetime(recorder) { CFRunLoopRun() }

case "--headless":
    let runner = LiveRunner()
    do { try runner.start() } catch { fail("\(error)") }
    print("動作中（Ctrl-C で終了）")
    withExtendedLifetime(runner) { CFRunLoopRun() }

case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()

case "-h", "--help":
    print(usage)

default:
    fail(usage)
}
