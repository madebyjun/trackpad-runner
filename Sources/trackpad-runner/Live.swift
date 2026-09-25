import ApplicationServices
import CMultitouch
import Foundation
import TrackpadRunnerCore

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

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// MultitouchSupport → Engine → CGEvent をつなぐ。
final class LiveRunner {
    private let engine = Engine()
    private let lock = NSLock()
    private var tap: CFMachPort?

    var isEnabled: Bool {
        get { lock.withLock { engine.isEnabled } }
        set { lock.withLock { engine.isEnabled = newValue } }
    }

    func start() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw LiveError.accessibilityNotGranted }

        engine.onAction = { action in
            switch action {
            case .middleClick: Output.middleClick()
            case .screenshotShortcut: Output.screenshotShortcut()
            }
        }

        frameHandler = { [weak self] device, touches in
            guard let self else { return }
            let t = now()
            self.lock.withLock { self.engine.handleFrame(device: device, time: t, touches: touches) }
        }
        switch cmt_start(multitouchCallback) {
        case -1: throw LiveError.multitouchUnavailable
        case 0: throw LiveError.noTrackpad
        default: break
        }

        tap = try installEventTap(listenOnly: false) { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            let decision: MouseDecision = self.lock.withLock {
                switch type {
                case .leftMouseDown: self.engine.mouseDown()
                case .leftMouseDragged: self.engine.mouseDragged()
                default: self.engine.mouseUp()
                }
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
    private let lock = NSLock()
    private var events: [Recording.Event] = []
    private var deviceIndex: [Int: Int] = [:]
    private let startTime = now()
    private var tap: CFMachPort?

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
        tap = try installEventTap(listenOnly: true) { [weak self] type, event in
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

    /// ⇧⌘5。privateState のソースを使い、実際の修飾キーの状態に影響させない。
    static func screenshotShortcut() {
        let source = CGEventSource(stateID: .privateState)
        let keyCode: CGKeyCode = 23 // "5"
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = [.maskShift, .maskCommand]
            event?.post(tap: .cghidEventTap)
        }
    }
}
