import ApplicationServices
import CMultitouch
import Foundation
import OSLog
import TrackpadRunnerCore

let log = Logger(subsystem: "com.madebyjun.trackpad-runner", category: "live")

enum LiveError: Error, CustomStringConvertible {
    case accessibilityNotGranted
    case multitouchUnavailable
    case noTrackpad
    case eventTapFailed

    var description: String {
        switch self {
        case .accessibilityNotGranted:
            "アクセシビリティ権限がありません。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可してください。"
        case .multitouchUnavailable:
            "MultitouchSupport.framework を読み込めませんでした。"
        case .noTrackpad:
            "トラックパッドが見つかりませんでした。"
        case .eventTapFailed:
            "イベントタップを作成できませんでした（アクセシビリティ権限を確認してください）。"
        }
    }
}

// MultitouchSupport のコールバックは C 関数ポインタなので、状態はグローバルに置く。
private var frameHandler: ((Int, [Touch]) -> Void)?

private let multitouchCallback: MTContactCallback = { device, fingers, count, _, _ in
    var touches: [Touch] = []
    if let fingers {
        touches.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let f = fingers[i]
            touches.append(Touch(
                id: Int(f.identifier),
                x: Double(f.normalized.position.x),
                y: Double(f.normalized.position.y),
                state: Int(f.state)
            ))
        }
    }
    frameHandler?(Int(bitPattern: device), touches)
    return 0
}

private var buttonHandler: ((Int, Int32) -> Void)?

private let buttonCallback: CMTButtonCallback = { device, state in
    buttonHandler?(Int(bitPattern: device), state)
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// トラックパッドの物理ボタンの通知と、その時点の指の本数を表示する（MultitouchSupport の前提確認用）。
func probeButtons(seconds: Double) -> Int32 {
    var devices: [Int: Int] = [:]
    var fingers: [Int: Int] = [:]
    let lock = NSLock()
    func index(_ device: Int) -> Int {
        let i = devices[device] ?? devices.count
        devices[device] = i
        return i
    }
    frameHandler = { device, touches in
        lock.withLock { fingers[index(device)] = touches.filter(\.isTouching).count }
    }
    buttonHandler = { device, state in
        lock.withLock { print("device=\(index(device)) state=\(state) fingers=\(fingers[index(device)] ?? 0)") }
    }
    let count = cmt_start(multitouchCallback, buttonCallback)
    guard count > 0 else { return count }
    print("トラックパッド \(count) 台。\(Int(seconds)) 秒間、ボタンの通知を表示します（クリックしてみてください）")
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    return count
}

/// トラックパッドの物理ボタンの押下を覚えておき、左クリックのイベントと結び付ける。
/// CGEvent にはどのトラックパッドで押されたかの情報が無いため。
final class ButtonTracker {
    /// 左クリックと同じ押下とみなす時間差
    static let matchWindow = 0.1
    /// 押下の通知（MultitouchSupport のスレッド）が遅れて届くのを待つ最大時間
    static let maxWait: useconds_t = 30_000

    private let lock = NSLock()
    private var lastDown: (device: Int, time: Double)?

    init() {
        buttonHandler = { [weak self] device, state in
            guard let self, state != 0 else { return }
            let t = now()
            self.lock.withLock { self.lastDown = (device, t) }
            log.info("button down device=\(device)")
        }
    }

    /// time の左クリックがどのトラックパッドの押下か。見つからなければ nil（マウスのクリックなど）。
    /// shouldWait が true なら、通知が遅れている可能性を考えて maxWait まで待つ。
    func device(forClickAt time: Double, shouldWait: Bool) -> Int? {
        var waited: useconds_t = 0
        while true {
            if let device = take(near: time) { return device }
            guard shouldWait, waited < Self.maxWait else { return nil }
            usleep(2_000)
            waited += 2_000
        }
    }

    /// 1回の押下は1回のクリックにだけ使う
    private func take(near time: Double) -> Int? {
        lock.withLock {
            guard let down = lastDown, abs(time - down.time) <= Self.matchWindow else { return nil }
            lastDown = nil
            return down.device
        }
    }
}

/// MultitouchSupport → Engine → CGEvent をつなぐ。
final class LiveRunner {
    private let engine = Engine()
    private let lock = NSLock()
    private var tap: CFMachPort?
    private let buttons = ButtonTracker()
    /// 直前に指が触れていたトラックパッド。ハプティックはこれだけで鳴らす（BTT と同じ）
    private var lastDevice: Int?

    var isEnabled: Bool {
        get { lock.withLock { engine.isEnabled } }
        set { lock.withLock { engine.isEnabled = newValue } }
    }

    func start() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw LiveError.accessibilityNotGranted }

        engine.onTrigger = { [unowned self] trigger in
            guard let pattern = hapticPatterns[trigger] else { return }
            // onTrigger は lock の内側から呼ばれるので、lastDevice はそのまま読める
            Haptics.play(pattern, device: lastDevice.flatMap { UnsafeMutableRawPointer(bitPattern: $0) })
            log.info("trigger=\(trigger.rawValue, privacy: .public) haptic=\(pattern.name, privacy: .public)")
        }
        engine.onAction = { action in
            log.info("action=\(action.rawValue, privacy: .public)")
            switch action {
            case .middleClick: Output.middleClick()
            case .screenshotShortcut: Output.screenshotShortcut()
            }
        }

        frameHandler = { [weak self] device, touches in
            guard let self else { return }
            let t = now()
            self.lock.withLock {
                if !touches.isEmpty { self.lastDevice = device }
                self.engine.handleFrame(device: device, time: t, touches: touches)
            }
        }
        switch cmt_start(multitouchCallback, buttonCallback) {
        case -1: throw LiveError.multitouchUnavailable
        case 0: throw LiveError.noTrackpad
        default: break
        }

        tap = try installEventTap(listenOnly: false) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            let decision: MouseDecision
            switch type {
            case .leftMouseDown:
                let t = now()
                // 3本以上の新しい接触が無ければ変換の対象外なので、通知を待たない（マウスのクリックを遅らせない）
                let shouldWait = self.lock.withLock { self.engine.hasFreshMultiFingerContact(at: t) }
                let device = self.buttons.device(forClickAt: t, shouldWait: shouldWait)
                decision = self.lock.withLock { self.engine.mouseDown(time: t, device: device) }
                let fingers = self.lock.withLock { self.engine.fingerCountAtLastClick }
                log.info("mouseDown device=\(device.map(String.init) ?? "none", privacy: .public) fingers=\(fingers) decision=\(decision.rawValue, privacy: .public)")
            case .leftMouseDragged:
                decision = self.lock.withLock { self.engine.mouseDragged() }
            default:
                decision = self.lock.withLock { self.engine.mouseUp() }
            }
            switch decision {
            case .passThrough:
                break
            case .swallow:
                return nil
            case .convertToMiddle:
                event.type = switch type {
                case .leftMouseDown: .otherMouseDown
                case .leftMouseDragged: .otherMouseDragged
                default: .otherMouseUp
                }
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
            }
            return Unmanaged.passUnretained(event)
        }
    }
}

/// 実機の入力をそのまま Recording 形式で保存する（フィクスチャ作成用）。
final class Recorder {
    /// デバイスのポインタを 0, 1, … の番号に置き換える（lock の内側で呼ぶ）
    private func index(of device: Int) -> Int {
        let index = deviceIndex[device] ?? deviceIndex.count
        deviceIndex[device] = index
        return index
    }

    private let lock = NSLock()
    private var events: [Recording.Event] = []
    private var deviceIndex: [Int: Int] = [:]
    private let startTime = now()
    private var tap: CFMachPort?
    private let buttons = ButtonTracker()

    func start(seconds: Double, output: URL) throws {
        switch cmt_start(multitouchCallback, buttonCallback) {
        case -1: throw LiveError.multitouchUnavailable
        case 0: throw LiveError.noTrackpad
        default: break
        }
        frameHandler = { [weak self] device, touches in
            guard let self else { return }
            self.lock.withLock {
                self.events.append(.init(t: now() - self.startTime, device: self.index(of: device), touches: touches))
            }
        }
        tap = try installEventTap(listenOnly: true) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            let t = now()
            let name = switch type {
            case .leftMouseDown: "down"
            case .leftMouseDragged: "dragged"
            default: "up"
            }
            // down にはボタンが押されたトラックパッドを記録する（マウスのクリックなら無し）
            let device = type == .leftMouseDown ? self.buttons.device(forClickAt: t, shouldWait: true) : nil
            self.lock.withLock {
                self.events.append(.init(t: t - self.startTime, device: device.map { self.index(of: $0) }, mouse: name))
            }
            return Unmanaged.passUnretained(event)
        }

        print("\(Int(seconds)) 秒間記録します…")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            let recording = lock.withLock { Recording(name: output.deletingPathExtension().lastPathComponent, events: events) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(recording).write(to: output)
                print("保存しました: \(output.path)（\(recording.events.count) イベント）")
                exit(0)
            } catch {
                fputs("保存に失敗しました: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

// MARK: - イベントタップ

private typealias TapHandler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

private final class TapBox {
    let handler: TapHandler
    var port: CFMachPort?
    init(handler: @escaping TapHandler) { self.handler = handler }
}

private func installEventTap(listenOnly: Bool, handler: @escaping TapHandler) throws -> CFMachPort {
    let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        .reduce(0) { $0 | (1 << $1.rawValue) }
    let box = TapBox(handler: handler)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let box = Unmanaged<TapBox>.fromOpaque(userInfo!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // OS に無効化されたら再度有効化する
            if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return box.handler(type, event)
    }
    guard let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: listenOnly ? .listenOnly : .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: Unmanaged.passRetained(box).toOpaque()
    ) else { throw LiveError.eventTapFailed }
    box.port = port
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return port
}

// MARK: - 出力

enum Output {
    static func middleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center)?
                .post(tap: .cghidEventTap)
        }
    }

    /// ⇧⌘5。BTT と同じく Shift → Cmd → 5 を順に押して逆順に離す。
    /// スクリーンショットのようなシステムのショートカットは、修飾キー自体のイベントが無いと反応しないことがある。
    static func screenshotShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let shift: CGKeyCode = 56, command: CGKeyCode = 55, five: CGKeyCode = 23
        let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [
            (shift, true, [.maskShift]),
            (command, true, [.maskShift, .maskCommand]),
            (five, true, [.maskShift, .maskCommand]),
            (five, false, [.maskShift, .maskCommand]),
            (command, false, [.maskShift]),
            (shift, false, []),
        ]
        for (key, down, flags) in sequence {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
