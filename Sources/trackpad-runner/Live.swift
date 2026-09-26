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
/// デバイスごとの Force Touch 対応。コールバックはデバイスごとのスレッドから呼ばれるので lock で保護する
private var forceSupport: [Int: Bool] = [:]
private let forceSupportLock = NSLock()

private let multitouchCallback: MTContactCallback = { device, fingers, count, _, _ in
    var touches: [Touch] = []
    // Force Touch 非対応のトラックパッドでは押す力のフィールドに意味が無いので読まない（nil = 分からない）
    let supportsForce = forceSupportLock.withLock {
        let key = Int(bitPattern: device)
        if let known = forceSupport[key] { return known }
        let supported = cmt_device_supports_force(device) != 0
        forceSupport[key] = supported
        return supported
    }
    if let fingers {
        touches.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let f = fingers[i]
            touches.append(Touch(
                id: Int(f.identifier),
                x: Double(f.normalized.position.x),
                y: Double(f.normalized.position.y),
                state: Int(f.state),
                pressure: supportsForce ? Double(f.pressure) : nil
            ))
        }
    }
    frameHandler?(Int(bitPattern: device), touches)
    return 0
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// MultitouchSupport → Engine → CGEvent をつなぐ。
final class LiveRunner {
    private let engine = Engine()
    private let lock = NSLock()
    private var tap: EventTap?
    private var permissionTimer: Timer?
    /// 直前に指が触れていたトラックパッド。ハプティックはこれだけで鳴らす（BTT と同じ）
    private var lastDevice: Int?
    /// アクセシビリティ権限が外れてクリックの横取りをやめている間は true（lock で保護）
    private var suspended = false

    /// 権限が外れた / 戻ったときに main スレッドで呼ぶ。引数は権限があるかどうか
    var onPermissionChange: (Bool) -> Void = { _ in }

    var isEnabled: Bool {
        get { lock.withLock { engine.isEnabled } }
        set { lock.withLock { engine.isEnabled = newValue } }
    }

    var hasPermission: Bool { lock.withLock { !suspended } }

    func start() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw LiveError.accessibilityNotGranted }

        engine.onTrigger = { [unowned self] trigger in
            // onTrigger / onAction は lock の内側から呼ばれるので、suspended / lastDevice はそのまま読める。
            // 権限が無いとイベントを送れないので、ハプティックだけ鳴らすことはしない
            guard !suspended, let pattern = hapticPatterns[trigger] else { return }
            Haptics.play(pattern, device: lastDevice.flatMap { UnsafeMutableRawPointer(bitPattern: $0) })
            log.info("trigger=\(trigger.rawValue, privacy: .public) haptic=\(pattern.name, privacy: .public)")
        }
        engine.onAction = { [unowned self] action in
            guard !suspended else { return }
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
        switch cmt_start(multitouchCallback) {
        case -1: throw LiveError.multitouchUnavailable
        case 0: throw LiveError.noTrackpad
        default: break
        }

        tap = try makeTap()

        // 起動中に権限を外されると、残ったタップが左クリックを止めてしまう。1秒ごとに確認して、
        // 外れたらタップを取り外し、戻ったら作り直す
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkPermission() }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func makeTap() throws -> EventTap {
        let tap = try EventTap(listenOnly: false) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            // 押す力の強いフレームが左クリックより遅れて届くことがあるので、必要なときだけ少し待つ。
            // フレームは別スレッドで届くので、待つ間は lock を手放す
            var waited = 0.0
            if type == .leftMouseDown {
                let start = now()
                self.lock.withLock { self.engine.noteMouseDown(time: start) }
                while self.lock.withLock({ self.engine.shouldWaitForPressure(at: now()) }), now() - start < Engine.maxPressureWait {
                    usleep(2_000)
                }
                waited = now() - start
            }
            let decision: MouseDecision = self.lock.withLock {
                switch type {
                case .leftMouseDown: self.engine.mouseDown(time: now())
                case .leftMouseDragged: self.engine.mouseDragged()
                default: self.engine.mouseUp()
                }
            }
            if type == .leftMouseDown {
                let (fingers, source, pressAge) = self.lock.withLock {
                    (self.engine.fingerCountAtLastClick, self.engine.sourceAtLastClick, self.engine.pressAgeAtLastClick)
                }
                log.info("mouseDown source=\(source.map { String($0) } ?? "none", privacy: .public) fingers=\(fingers) waited=\(Int(waited * 1000))ms pressAge=\(pressAge.map { "\(Int($0 * 1000))ms" } ?? "-", privacy: .public) decision=\(decision.rawValue, privacy: .public)")
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
        tap.onDisabledWithoutPermission = { [weak self] in self?.checkPermission() }
        return tap
    }

    private func checkPermission() {
        let trusted = AXIsProcessTrusted()
        if !trusted, let tap {
            tap.remove()
            self.tap = nil
            lock.withLock {
                suspended = true
                engine.cancelPress()
            }
            log.error("アクセシビリティ権限が外れたので、クリックの横取りをやめました")
            onPermissionChange(false)
        } else if trusted, tap == nil {
            // 権限が戻った直後はタップを作れないことがある。その場合は次の確認で再試行する
            guard let newTap = try? makeTap() else { return }
            tap = newTap
            lock.withLock { suspended = false }
            log.info("アクセシビリティ権限が戻ったので、クリックの横取りを再開しました")
            onPermissionChange(true)
        }
    }
}

/// 実機の入力をそのまま Recording 形式で保存する（フィクスチャ作成用）。
final class Recorder {
    private let lock = NSLock()
    private var events: [Recording.Event] = []
    private var deviceIndex: [Int: Int] = [:]
    private let startTime = now()
    private var tap: EventTap?

    func start(seconds: Double, output: URL) throws {
        switch cmt_start(multitouchCallback) {
        case -1: throw LiveError.multitouchUnavailable
        case 0: throw LiveError.noTrackpad
        default: break
        }
        frameHandler = { [weak self] device, touches in
            guard let self else { return }
            self.lock.withLock {
                let index = self.deviceIndex[device] ?? self.deviceIndex.count
                self.deviceIndex[device] = index
                self.events.append(.init(t: now() - self.startTime, device: index, touches: touches))
            }
        }
        tap = try EventTap(listenOnly: true) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            let name = switch type {
            case .leftMouseDown: "down"
            case .leftMouseDragged: "dragged"
            default: "up"
            }
            self.lock.withLock { self.events.append(.init(t: now() - self.startTime, mouse: name)) }
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

/// 左ボタンのイベントタップ。main の run loop で動く。
private final class EventTap {
    private let handler: TapHandler
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// 権限が無い状態で OS にタップを無効化されたときに呼ぶ（main スレッド）
    var onDisabledWithoutPermission: () -> Void = {}

    init(listenOnly: Bool, handler: @escaping TapHandler) throws {
        self.handler = handler
        let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let tap = Unmanaged<EventTap>.fromOpaque(userInfo!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tap.handleDisabled()
                return Unmanaged.passUnretained(event)
            }
            return tap.handler(type, event)
        }
        // userInfo は保持しない。remove() でタップを無効にしてから手放すこと
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw LiveError.eventTapFailed }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    deinit { remove() }

    private func handleDisabled() {
        guard let port else { return }
        if AXIsProcessTrusted() {
            // タイムアウトなどで OS に無効化されたら再度有効化する
            CGEvent.tapEnable(tap: port, enable: true)
        } else {
            // 権限が無いまま再有効化すると、クリックが止まり続ける。取り外しはコールバックの外で行う
            DispatchQueue.main.async { [weak self] in self?.onDisabledWithoutPermission() }
        }
    }

    func remove() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }
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
