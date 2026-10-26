import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - 常量

/// 给自己合成的事件打的标记，避免被自己的 tap 二次处理
private let kMagicTag: Int64 = 0x5144_4C54
private let kDeleteKey: CGKeyCode = 51   // Delete ⌫
private let kCapsLock: CGKeyCode = 57
private let kEscape: CGKeyCode = 53

/// 纯修饰键（它们产生 flagsChanged 而不是 keyDown）
private let kModifierCodes: Set<CGKeyCode> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

private func modifierFlag(for code: CGKeyCode) -> CGEventFlags? {
    switch code {
    case 56, 60: return .maskShift          // Shift
    case 58, 61: return .maskAlternate      // Option
    case 59, 62: return .maskControl        // Control
    case 54, 55: return .maskCommand        // Command
    case 63: return .maskSecondaryFn        // fn
    case 57: return .maskAlphaShift         // Caps Lock
    default: return nil
    }
}

// MARK: - 键名显示（键码取自 macOS 官方 kVK_* 定义，US 布局）

enum KeyNames {
    static let table: [CGKeyCode: String] = [
        // 修饰键 / 特殊控制键
        55: "左 Command ⌘", 54: "右 Command ⌘",
        56: "左 Shift ⇧", 60: "右 Shift ⇧",
        58: "左 Option ⌥", 61: "右 Option ⌥",
        59: "左 Control ⌃", 62: "右 Control ⌃",
        57: "Caps Lock ⇪", 63: "fn 🌐", 110: "菜单键 ▤",
        // 功能键
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
        // 编辑 / 导航
        51: "Delete ⌫（回退删除）", 117: "Forward Delete ⌦", 114: "Help / Insert",
        115: "Home ↖", 119: "End ↘", 116: "Page Up ⇞", 121: "Page Down ⇟",
        123: "左方向键 ◀", 124: "右方向键 ▶", 125: "下方向键 ▼", 126: "上方向键 ▲",
        48: "Tab ⇥", 53: "Escape ⎋", 36: "Return ↩", 49: "Space 空格",
        // 字母键
        0: "A 键", 1: "S 键", 2: "D 键", 3: "F 键", 4: "H 键", 5: "G 键",
        6: "Z 键", 7: "X 键", 8: "C 键", 9: "V 键", 11: "B 键", 12: "Q 键",
        13: "W 键", 14: "E 键", 15: "R 键", 16: "Y 键", 17: "T 键", 31: "O 键",
        32: "U 键", 34: "I 键", 35: "P 键", 37: "L 键", 38: "J 键", 40: "K 键",
        45: "N 键", 46: "M 键",
        // 数字键
        18: "数字 1", 19: "数字 2", 20: "数字 3", 21: "数字 4", 23: "数字 5",
        22: "数字 6", 26: "数字 7", 28: "数字 8", 25: "数字 9", 29: "数字 0",
        // 符号键
        24: "= + 等号键", 27: "- _ 减号键", 30: "] } 右方括号", 33: "[ { 左方括号",
        39: "引号键", 41: "分号键 ; :", 42: "反斜杠键",
        43: ", < 逗号键", 47: ". > 句号键", 44: "/ ? 斜杠键", 50: "` ~ 波浪号键",
        // 小键盘 / 媒体（一般不建议映射）
        71: "小键盘 Clear ⌧", 76: "小键盘 Enter ⌤", 65: "小键盘 .",
        67: "小键盘 *", 69: "小键盘 +", 75: "小键盘 /", 78: "小键盘 −",
        72: "音量 +", 73: "音量 −", 74: "静音",
    ]

    static func name(for code: CGKeyCode) -> String {
        table[code] ?? "键码 \(code)"
    }
}

// MARK: - 映射引擎

final class RemapEngine {
    static let shared = RemapEngine()

    private static let triggerKey = "TriggerKeyCode"
    private static let enabledKey = "IsEnabled"

    var triggerCode: CGKeyCode {
        didSet { UserDefaults.standard.set(Int(triggerCode), forKey: Self.triggerKey) }
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            refreshStatus()
        }
    }

    private(set) var isCapturing = false
    private(set) var tap: CFMachPort?
    private(set) var fireCount = 0
    /// 自检模式下记录最近一次构造的事件载荷（不投递）
    private(set) var lastPayload = ""

    var statusText = "" { didSet { if statusText != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var capturedHandler: ((CGKeyCode) -> Void)?

    /// 自检用：环境变量 CMDDEL_DRY_RUN=1 时只统计触发，不注入真实按键
    static let dryRun = ProcessInfo.processInfo.environment["CMDDEL_DRY_RUN"] == "1"

    private let source = CGEventSource(stateID: .hidSystemState)
    /// 修饰键触发键被按下时，需要从后续事件里抹掉的修饰位
    private var heldSuppressBits: CGEventFlags = []

    private init() {
        let d = UserDefaults.standard
        triggerCode = CGKeyCode(d.object(forKey: Self.triggerKey) as? Int ?? Int(kCapsLock))
        isEnabled = (d.object(forKey: Self.enabledKey) as? Bool) ?? true
        statusText = computeStatus()
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 安装事件 tap。未授予辅助功能权限时返回 false。
    @discardableResult
    func installTap() -> Bool {
        if let existing = tap {
            CGEvent.tapEnable(tap: existing, enable: true)
            refreshStatus()
            return true
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<RemapEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            refreshStatus()
            return false
        }
        tap = newTap
        let rlSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rlSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        refreshStatus()
        return true
    }

    func startCapture() {
        isCapturing = true
        refreshStatus()
    }

    func cancelCapture() {
        guard isCapturing else { return }
        isCapturing = false
        refreshStatus()
    }

    func refreshStatus() { statusText = computeStatus() }

    private func computeStatus() -> String {
        if isCapturing { return "请按下想映射的键…（Esc 取消）" }
        if tap == nil {
            return isTrusted
                ? "权限已就绪，正在建立监听…"
                : "需要「辅助功能」权限：请在系统设置里打开本 App 的开关，然后点「重试授权」"
        }
        let name = KeyNames.name(for: triggerCode)
        if !isEnabled { return "已暂停 · \(name) 保持原有功能" }
        return "监听中 · \(name) → ⌘⌫ ｜ 已触发 \(fireCount) 次"
    }

    // MARK: 事件处理（运行在主 runloop）

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == kMagicTag {
            return Unmanaged.passUnretained(event)          // 自己注入的，放行
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if isCapturing {
            if type == .keyDown || (type == .flagsChanged && kModifierCodes.contains(code)) {
                let pressed: Bool
                if type == .keyDown {
                    pressed = true
                } else {
                    pressed = (modifierFlag(for: code).map { event.flags.contains($0) }) ?? true
                }
                if pressed {
                    if code == kEscape { cancelCapture() } else { finishCapture(code) }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled else { return Unmanaged.passUnretained(event) }

        // Caps Lock 作为触发键时，顺手抹掉大写位，避免大小写状态被意外切换后影响打字
        if triggerCode == kCapsLock, !event.flags.isDisjoint(with: .maskAlphaShift) {
            event.flags.remove(.maskAlphaShift)
        }
        // 触发键是修饰键且当前处于按下状态时，抹掉它的修饰位
        if !heldSuppressBits.isEmpty {
            if !event.flags.isDisjoint(with: heldSuppressBits) {
                event.flags.remove(heldSuppressBits)
            }
        }

        guard code == triggerCode else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isAutoRepeat { fire() }
            return nil

        case .keyUp:
            return nil

        case .flagsChanged:
            guard let bit = modifierFlag(for: code) else { return Unmanaged.passUnretained(event) }
            let isDown = event.flags.contains(bit)
            if isDown {
                if !heldSuppressBits.contains(bit) {
                    heldSuppressBits.insert(bit)
                    fire()
                }
            } else {
                heldSuppressBits.remove(bit)
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func finishCapture(_ code: CGKeyCode) {
        isCapturing = false
        heldSuppressBits = []
        triggerCode = code
        refreshStatus()
        capturedHandler?(code)
    }

    private func fire() {
        fireCount += 1
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kDeleteKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: kDeleteKey, keyDown: false)
        else { return }
        down.flags = [.maskCommand]
        up.flags = [.maskCommand]
        down.setIntegerValueField(.eventSourceUserData, value: kMagicTag)
        up.setIntegerValueField(.eventSourceUserData, value: kMagicTag)
        // 自检模式：构造并核对事件载荷，但不投递到系统（避免误删当前窗口内容 / 关闭标签页）
        if RemapEngine.dryRun {
            lastPayload = "down(key=\(down.getIntegerValueField(.keyboardEventKeycode)),flags=\(down.flags.rawValue))"
                + " up(key=\(up.getIntegerValueField(.keyboardEventKeycode)),flags=\(up.flags.rawValue))"
            refreshStatus()
            return
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        refreshStatus()
    }
}

// MARK: - 悬浮面板

final class FloatingPanel: NSPanel {
    init(width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = RemapEngine.shared
    private var panel: FloatingPanel!
    private var popup: NSPopUpButton!
    private var captureButton: NSButton!
    private var enableSwitch: NSSwitch!
    private var statusLabel: NSTextField!
    private var permissionButtonsStack: [NSButton] = []
    private var timer: Timer?
    private var capturedCodes: [CGKeyCode] = []

    /// 下拉里的常用候选：几乎无用、又不影响正常打字的键
    private let presets: [CGKeyCode] = [57, 61, 62, 60, 110, 117, 115, 119, 116,
                                        121, 122, 120, 99, 118, 96, 97, 98, 100]

    /// 自诊断：打印当前权限 / 监听 / 触发键状态
    private func dumpStatus() -> String {
        "trusted=\(engine.isTrusted) tap=\(engine.tap == nil ? "nil" : "ok") "
        + "enabled=\(engine.isEnabled) trigger=\(engine.triggerCode)(\(KeyNames.name(for: engine.triggerCode))) "
        + "capturing=\(engine.isCapturing) fires=\(engine.fireCount) status=\(engine.statusText)" + " payload=\(engine.lastPayload)"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        ensureSingleInstance()
        NSApp.setActivationPolicy(.accessory)
        buildUI()
        engine.onChange = { [weak self] in self?.syncUI() }
        engine.capturedHandler = { [weak self] code in self?.handleCaptured(code) }
        // 一次性自诊断模式：打印状态后立即退出
        if CommandLine.arguments.contains("--status") {
            engine.installTap()
            FileHandle.standardError.write("CMDDEL \(dumpStatus())\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        engine.promptForAccessibility()
        engine.installTap()
        syncUI()
        if ProcessInfo.processInfo.environment["CMDDEL_DEBUG"] != nil {
            FileHandle.standardError.write("CMDDEL start \(dumpStatus())\n".data(using: .utf8)!)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.engine.installTap()
            self?.engine.refreshStatus()
            if ProcessInfo.processInfo.environment["CMDDEL_DEBUG"] != nil {
                FileHandle.standardError.write("CMDDEL tick \(self?.dumpStatus() ?? "")\n".data(using: .utf8)!)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ note: Notification) {
        if let t = engine.tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
    }

    // MARK: UI

    private func buildUI() {
        let w: CGFloat = 324
        let h: CGFloat = 194
        panel = FloatingPanel(width: w, height: h)
        panel.delegate = self

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.addSubview(content)
        panel.contentView = effect

        let title = label("⌘⌫ 临时按键映射", size: 13, weight: .semibold)
        title.frame = NSRect(x: 38, y: 14, width: w - 70, height: 18)
        content.addSubview(title)

        let keyLabel = label("触发键", size: 12, weight: .regular, color: .secondaryLabelColor)
        keyLabel.frame = NSRect(x: 18, y: 50, width: 56, height: 16)
        content.addSubview(keyLabel)

        popup = NSPopUpButton(frame: NSRect(x: 74, y: 44, width: 154, height: 26), pullsDown: false)
        popup.target = self
        popup.action = #selector(popupChanged)
        content.addSubview(popup)

        captureButton = button("捕获…", frame: NSRect(x: 234, y: 43, width: 72, height: 27),
                              action: #selector(captureTapped))
        content.addSubview(captureButton)

        let enableLabel = label("启用", size: 12, weight: .regular, color: .secondaryLabelColor)
        enableLabel.frame = NSRect(x: 18, y: 84, width: 40, height: 16)
        content.addSubview(enableLabel)

        enableSwitch = NSSwitch(frame: NSRect(x: 60, y: 79, width: 38, height: 24))
        enableSwitch.target = self
        enableSwitch.action = #selector(switchChanged)
        content.addSubview(enableSwitch)

        let hint = label("按一下触发键 = 执行一次 ⌘⌫（删除选中内容 / 关闭标签）",
                         size: 11, weight: .regular, color: .tertiaryLabelColor)
        hint.frame = NSRect(x: 104, y: 84, width: w - 118, height: 16)
        content.addSubview(hint)

        let separator = NSBox(frame: NSRect(x: 18, y: 116, width: w - 36, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        statusLabel = label("", size: 11, weight: .regular, color: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 18, y: 150, width: w - 124, height: 34)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.cell?.wraps = true
        statusLabel.cell?.isScrollable = false
        content.addSubview(statusLabel)

        let settings = button("打开设置", frame: NSRect(x: w - 96, y: 152, width: 80, height: 26),
                              action: #selector(openSettings))
        content.addSubview(settings)

        let retry = button("重试授权", frame: NSRect(x: w - 96, y: 122, width: 80, height: 26),
                           action: #selector(retryTapped))
        content.addSubview(retry)

        permissionButtonsStack = [settings, retry]

        populatePopup()

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - w - 30, y: f.maxY - h - 30))
        }
        panel.setFrameAutosaveName("CmdDeletePanel")
        panel.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func button(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let b = NSButton(frame: frame)
        b.title = title
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11)
        b.target = self
        b.action = action
        return b
    }

    private func appendItem(_ code: CGKeyCode, suffix: String = "") {
        popup.addItem(withTitle: KeyNames.name(for: code) + suffix)
        popup.lastItem?.representedObject = Int(code)
    }

    private func populatePopup() {
        popup.removeAllItems()
        for code in presets { appendItem(code) }
        if !capturedCodes.isEmpty {
            popup.menu?.addItem(.separator())
            let header = NSMenuItem(title: "— 已捕获 —", action: nil, keyEquivalent: "")
            header.isEnabled = false
            popup.menu?.addItem(header)
            for code in capturedCodes where !presets.contains(code) {
                appendItem(code, suffix: "（捕获）")
            }
        }
        selectCurrentTrigger()
    }

    private func selectCurrentTrigger() {
        let value = Int(engine.triggerCode)
        let index = popup.indexOfItem(withRepresentedObject: value)
        if index >= 0 {
            popup.selectItem(at: index)
        } else {
            appendItem(engine.triggerCode)
            popup.selectItem(at: popup.numberOfItems - 1)
        }
    }

    private func syncUI() {
        enableSwitch.state = engine.isEnabled ? .on : .off
        statusLabel.stringValue = engine.statusText
        let needsPermission = (engine.tap == nil)
        permissionButtonsStack.forEach { $0.isHidden = !needsPermission }
        captureButton.title = engine.isCapturing ? "取消" : "捕获…"
        let index = popup.indexOfItem(withRepresentedObject: Int(engine.triggerCode))
        if index >= 0 { popup.selectItem(at: index) }
    }

    private func handleCaptured(_ code: CGKeyCode) {
        if !capturedCodes.contains(code) { capturedCodes.append(code) }
        populatePopup()
        NSSound.beep()
        syncUI()
    }

    // MARK: 动作

    @objc private func popupChanged() {
        guard let value = popup.selectedItem?.representedObject as? Int else { return }
        engine.triggerCode = CGKeyCode(value)
        engine.refreshStatus()
    }

    @objc private func captureTapped() {
        if engine.isCapturing {
            engine.cancelCapture()
        } else if engine.tap == nil {
            engine.promptForAccessibility()
            engine.refreshStatus()
        } else {
            engine.startCapture()
        }
    }

    @objc private func switchChanged() {
        engine.isEnabled = (enableSwitch.state == .on)
    }

    @objc private func openSettings() {
        engine.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retryTapped() {
        engine.promptForAccessibility()
        engine.installTap()
        engine.refreshStatus()
    }

    /// 关闭窗口即退出，映射同时失效
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

// MARK: - 入口（避免重复开两份，导致两个 tap 互相干扰）

private func ensureSingleInstance() {
    let me = NSRunningApplication.current
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: me.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != me.processIdentifier }
    if !others.isEmpty {
        others.first?.activate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
ensureSingleInstance()
app.run()
