import AppKit
import AVFoundation
import Carbon.HIToolbox
import CryptoKit
import Darwin
import Foundation
import ImageIO
import QuartzCore

private let petRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/pet")
private let assetsDir = petRoot.appendingPathComponent("assets")
private let stateURL = petRoot.appendingPathComponent("window.json")
private let statsURL = petRoot.appendingPathComponent("stats.json")
private let runDir = petRoot.appendingPathComponent("run")
private let configURL = petRoot.appendingPathComponent("config.json")
private let reviewOffURL = petRoot.appendingPathComponent("review_off.txt")
private let historyURL = petRoot.deletingLastPathComponent().appendingPathComponent("history.jsonl")
private let showFlagURL = runDir.appendingPathComponent("pet.show")
private let hideFlagURL = runDir.appendingPathComponent("pet.hide")
private let hiddenFlagURL = runDir.appendingPathComponent("pet.hidden")

private struct MotionSpec: Decodable {
    let key: String
    let name: String
    let crop: [Int]
    let durations: [Int]
    let frames: [String]
}

private struct Manifest: Decodable {
    let motions: [MotionSpec]
}

private struct Motion {
    let key: String
    let name: String
    let width: CGFloat
    let height: CGFloat
    let images: [CGImage]
    let durations: [Double]

    var total: Double { durations.reduce(0, +) }
}

private struct PetState: Codable {
    var centerX: Double?
    var bottomY: Double?
    var scale: Double
    var onTop: Bool
    var showBubble: Bool?
    var locked: Bool?
    var speed: Double?
    var showBadge: Bool?
    var sound: Bool?
    var currentOnly: Bool?
    var soundDone: String?
    var soundFailed: String?
    var soundWaiting: String?
    var soundBalance: String?
    var soundTool: String?
    var soundVolume: Double?
    var motionMap: [String: String]?
    var dnd: Bool?
    var fontScale: Double?
    var hotkey: Bool?
    var idleOpacity: Double?
    var pinnedSession: String?
    var effortBySession: [String: String]? = nil
    var mutedSessions: [String]? = nil
    var toolTimeout: Double? = nil
}

private struct PetDayRecord: Codable {
    var day: String
    var done: Int
    var failed: Int
    var activeSeconds: Double
    var tokens: Int

    init(day: String, done: Int, failed: Int, activeSeconds: Double, tokens: Int) {
        self.day = day
        self.done = done
        self.failed = failed
        self.activeSeconds = activeSeconds
        self.tokens = tokens
    }

    init(from stats: PetStats) {
        self.init(
            day: stats.day,
            done: stats.done,
            failed: stats.failed,
            activeSeconds: stats.activeSeconds,
            tokens: stats.tokens
        )
    }
}

private struct PetStats: Codable {
    var day: String
    var done = 0
    var failed = 0
    var activeSeconds = 0.0
    var tokens = 0
    var seen: [String] = []
    var usage: [String: Int] = [:]
    var history: [PetDayRecord] = []

    init(day: String) {
        self.day = day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        seen = try c.decodeIfPresent([String].self, forKey: .seen) ?? []
        usage = try c.decodeIfPresent([String: Int].self, forKey: .usage) ?? [:]
        history = try c.decodeIfPresent([PetDayRecord].self, forKey: .history) ?? []
    }
}

private func todayKey() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private let alertSounds: [(id: String, label: String)] = [
    ("Glass", "Glass"),
    ("Ping", "Ping"),
    ("Pop", "Pop"),
    ("Tink", "Tink"),
    ("Hero", "Hero"),
    ("Funk", "Funk"),
    ("Purr", "Purr"),
    ("Sosumi", "Sosumi"),
    ("Basso", "Basso"),
    ("Blow", "Blow"),
    ("Bottle", "Bottle"),
    ("Frog", "Frog"),
    ("Morse", "Morse"),
    ("Submarine", "Submarine"),
    ("codex-alert-codex-notification", "Codex 提醒"),
]

// group key lists every state the choice applies to; rep is used for the checkmark
private let stateMotionGroups: [(key: String, title: String, rep: String)] = [
    ("thinking", "思考中", "thinking"),
    ("search", "搜索工具", "search"),
    ("bash,tool", "其他工具", "bash"),
    ("waiting", "等待输入", "waiting"),
    ("done", "完成", "done"),
    ("failed", "失败", "failed"),
    ("idle", "空闲", "idle"),
]

private struct PetConfig: Decodable {
    var contextWindow: Int?
    var balanceAlert: Double?
    var toolTimeout: Double?
}

private struct PetStatus: Decodable {
    var state: String
    var event: String?
    var ts: Double?
    var turnStart: Double?
    var sessionId: String?
    var transcript: String?
    var cwd: String?
    var tool: String?
    var detail: String?
    var message: String?
    var prompt: String?
    var last: String?
}

private struct RecentConversation {
    let id: String
    var project: String
    var prompt: String
    var ts: Double
}

private struct Session {
    var id: String
    var state: String
    var event: String?
    var ts: Double
    var cwd: String
    var transcript: String?
    var tool: String
    var detail: String
    var message: String
    var tty: String?
    var term: String?
    var turnStart: Double?
    var resumeID: String?

    var name: String {
        guard !cwd.isEmpty else { return "会话" }
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "会话" : base
    }
}

private func statePriority(_ state: String) -> Int {
    switch state {
    case "waiting": return 5
    case "bash", "search", "tool": return 4
    case "failed": return 3
    case "thinking": return 2
    case "start", "done": return 1
    default: return 0
    }
}

private func stateLabel(_ state: String) -> String {
    switch state {
    case "thinking": return "思考中"
    case "bash", "search", "tool": return "运行工具"
    case "waiting": return "等待输入"
    case "done": return "完成"
    case "start": return "启动中"
    case "failed": return "失败"
    default: return "空闲"
    }
}

private let effortLevels: [(id: String, label: String)] = [
    ("low", "低"),
    ("medium", "中"),
    ("high", "高"),
    ("xhigh", "超高"),
    ("max", "最高"),
]

private func effortLabel(_ id: String) -> String {
    effortLevels.first(where: { $0.id == id })?.label ?? id
}

private func effortIndex(_ id: String) -> Int? {
    effortLevels.firstIndex(where: { $0.id == id })
}

private struct ProcessEntry {
    let pid: Int32
    let ppid: Int32
    let comm: String
    let args: String
}

private func processEntries() -> [ProcessEntry] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,comm=,args="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true) {
            $0 == " " || $0 == "\t"
        }
        guard fields.count >= 3,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]) else { return nil }
        let comm = String(fields[2])
        let args = fields.count > 3 ? String(fields[3]) : comm
        return ProcessEntry(pid: pid, ppid: ppid, comm: comm, args: args)
    }
}

private func effortArgument(_ args: String) -> String? {
    let tokens = args.split(separator: " ").map(String.init)
    for (i, token) in tokens.enumerated() {
        if token == "--effort", i + 1 < tokens.count { return tokens[i + 1] }
        if token.hasPrefix("--effort=") { return String(token.dropFirst("--effort=".count)) }
    }
    return nil
}

private func processName(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

private struct TranscriptInfo {
    var thinking: String?
    var text: String?
    var used: Int?
    var model: String?
}

private struct TranscriptUsageState {
    var offset: UInt64 = 0
    var tokens = 0
    var seen: Set<String> = []
}

private struct TranscriptTextState {
    var offset: UInt64 = 0
    var text = ""
}

private func argValue(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func formatTokens(_ count: Int) -> String {
    let scale: Double
    let suffix: String
    if count >= 1_000_000 {
        scale = 1_000_000
        suffix = "M"
    } else if count >= 1_000 {
        scale = 1_000
        suffix = "k"
    } else {
        return "\(count)"
    }
    let text = String(format: "%.1f", Double(count) / scale)
    return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
}

private func tailSnippet(_ text: String, _ limit: Int) -> String {
    let flattened = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard flattened.count > limit else { return flattened }
    return "…" + String(flattened.suffix(limit))
}

private func headSnippet(_ text: String, _ limit: Int) -> String {
    let flattened = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard flattened.count > limit else { return flattened }
    return String(flattened.prefix(limit - 1)) + "…"
}

private let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoPlain = ISO8601DateFormatter()

private func parseTimestamp(_ string: String?) -> Double? {
    guard let string, !string.isEmpty else { return nil }
    guard let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) else {
        return nil
    }
    return date.timeIntervalSince1970
}

private func readTail(_ url: URL, bytes: UInt64) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > bytes ? size - bytes : 0
    do {
        try handle.seek(toOffset: start)
    } catch {
        return ""
    }
    let data = handle.readDataToEndOfFile()
    var text = String(decoding: data, as: UTF8.self)
    if start > 0, let newline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: newline)...])
    }
    return text
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PetView: NSView {
    var onDragEnd: (() -> Void)?
    var onDragStop: (() -> Void)?
    var onDragDirection: ((Int) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onMove: (() -> Void)?
    var locked = false

    private var downPoint = NSPoint.zero
    private var clickWork: DispatchWorkItem?
    private var startOrigin = NSPoint.zero
    private var lastDragX: CGFloat = 0
    private var dragged = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    func show(_ image: CGImage) {
        layer?.contents = image
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !bounds.contains(point) { return }
        }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if let window {
            // tracking areas are rebuilt whenever the panel resizes; ignore the
            // synthetic exit unless the pointer really left the view
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { return }
        }
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        clickWork?.cancel()
        clickWork = nil
        dragged = false
        guard !locked else { return }
        downPoint = NSEvent.mouseLocation
        lastDragX = downPoint.x
        startOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard !locked else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - downPoint.x
        let dy = point.y - downPoint.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        if dragged {
            window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            let step = point.x - lastDragX
            lastDragX = point.x
            if abs(step) >= 1 {
                onDragDirection?(step > 0 ? 1 : -1)
            }
            onMove?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            onDragStop?()
            onDragEnd?()
        } else if event.clickCount >= 2 {
            clickWork?.cancel()
            clickWork = nil
            onDoubleClick?()
        } else {
            // hold the single click until the double-click window closes so a
            // cheer does not first focus the terminal
            let work = DispatchWorkItem { [weak self] in
                self?.clickWork = nil
                self?.onClick?()
            }
            clickWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval,
                execute: work
            )
        }
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

private final class EffortSlider: NSSlider {
    var onCommit: ((Double) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // NSSlider tracks the whole drag inside mouseDown and consumes the mouse-up,
    // so commit only after the tracking loop returns.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onCommit?(doubleValue)
    }
}

private final class EffortCardView: NSView {
    var onCommit: ((Double) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "思考力度")
    private let valueLabel = NSTextField(labelWithString: "高")
    private let hintLabel = NSTextField(labelWithString: "松开滑块后立即发送 /effort，无需重启")
    private let slider = EffortSlider()
    private let closeButton = NSButton()
    private let container = NSView()
    private var glassView: NSView?
    private var hPad: CGFloat { 16 * BubbleView.scale }
    private var vPad: CGFloat { 12 * BubbleView.scale }
    private var cornerRadius: CGFloat { min(14 * BubbleView.scale, bounds.height / 2) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        container.wantsLayer = true

        titleLabel.font = NSFont.systemFont(ofSize: 12.5 * BubbleView.scale, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12 * BubbleView.scale, weight: .semibold)
        valueLabel.textColor = NSColor(srgbRed: 0.52, green: 0.76, blue: 1.0, alpha: 1)
        valueLabel.alignment = .right
        hintLabel.font = NSFont.systemFont(ofSize: 10 * BubbleView.scale)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        hintLabel.lineBreakMode = .byTruncatingTail

        slider.minValue = 0
        slider.maxValue = Double(effortLevels.count - 1)
        slider.numberOfTickMarks = effortLevels.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.onCommit = { [weak self] value in self?.commit(value) }

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 9 * BubbleView.scale, weight: .semibold)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        closeButton.target = self
        closeButton.action = #selector(cancel)

        container.addSubview(titleLabel)
        container.addSubview(valueLabel)
        container.addSubview(slider)
        container.addSubview(hintLabel)
        container.addSubview(closeButton)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.3)
            glass.contentView = container
            addSubview(glass)
            glassView = glass
        } else {
            addSubview(container)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            container.layer?.backgroundColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.55).cgColor
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
        }
        container.frame = bounds
        let scale = BubbleView.scale
        let valueWidth = 112 * scale
        let closeSize = 14 * scale
        titleLabel.frame = NSRect(
            x: hPad,
            y: bounds.height - vPad - 18 * scale,
            width: max(0, bounds.width - hPad * 2 - valueWidth - closeSize - 20 * scale),
            height: 18 * scale
        )
        valueLabel.frame = NSRect(
            x: bounds.width - hPad - closeSize - 8 * scale - valueWidth,
            y: bounds.height - vPad - 18 * scale,
            width: valueWidth,
            height: 18 * scale
        )
        closeButton.frame = NSRect(
            x: bounds.width - hPad - closeSize,
            y: bounds.height - vPad - 16 * scale,
            width: closeSize,
            height: closeSize
        )
        hintLabel.frame = NSRect(
            x: hPad,
            y: vPad - 2 * scale,
            width: max(0, bounds.width - hPad * 2),
            height: 13 * scale
        )
        slider.frame = NSRect(
            x: hPad,
            y: hintLabel.frame.maxY + 3 * scale,
            width: max(0, bounds.width - hPad * 2),
            height: 27 * scale
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard glassView == nil else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.94).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func cardSize() -> NSSize {
        NSSize(width: 292 * BubbleView.scale, height: 96 * BubbleView.scale)
    }

    func configure(name: String, level: String) {
        titleLabel.stringValue = "思考力度 · " + name
        let index = effortIndex(level) ?? (effortIndex("high") ?? 2)
        slider.doubleValue = Double(index)
        updateValueLabel()
        needsLayout = true
    }

    @objc private func sliderMoved() {
        updateValueLabel()
    }

    private func updateValueLabel() {
        let index = max(0, min(Int(slider.doubleValue.rounded()), effortLevels.count - 1))
        valueLabel.stringValue = effortLevels[index].label + " · " + effortLevels[index].id
    }

    private func commit(_ value: Double) {
        let index = max(0, min(Int(value.rounded()), effortLevels.count - 1))
        onCommit?(Double(index))
    }

    @objc private func cancel() {
        onCancel?()
    }
}

private final class AlertDotView: NSView {
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            isHidden = count == 0
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let diameter = min(bounds.width, bounds.height)
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        NSColor(srgbRed: 0.96, green: 0.26, blue: 0.27, alpha: 1).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = count > 9 ? "9+" : String(count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.6, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 + 0.5
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

private final class BubbleView: NSView {
    static var scale: CGFloat = 1.0
    static var titleFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 12 * scale, weight: .semibold) }
    static var detailFont: NSFont { NSFont.systemFont(ofSize: 11 * scale) }
    static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 10.5 * scale, weight: .regular) }
    static var prefixFont: NSFont { NSFont.systemFont(ofSize: 10 * scale, weight: .medium) }

    struct Row {
        var name: String
        var state: String
        var color: NSColor
        var time: String? = nil
        var pct: String? = nil
    }

    struct Content {
        var prefix: String?
        var title: String
        var detail: String?
        var mono: Bool
        var rows: [Row] = []
        var time: String? = nil
        var titleColor: NSColor? = nil
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let container = NSView()
    private var glassView: NSView?
    private var hPad: CGFloat { 13 * BubbleView.scale }
    private var vPad: CGFloat { 10 * BubbleView.scale }
    private var cornerRadius: CGFloat { 16 * BubbleView.scale }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.maximumNumberOfLines = 5
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.isSelectable = false
        container.wantsLayer = true
        container.addSubview(label)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.3)
            glass.contentView = container
            addSubview(glass)
            glassView = glass
        } else {
            addSubview(container)
        }
    }

    override func layout() {
        super.layout()
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            container.layer?.backgroundColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.42).cgColor
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
        }
        container.frame = bounds
        label.frame = NSRect(
            x: hPad,
            y: vPad,
            width: max(0, bounds.width - hPad * 2),
            height: max(0, bounds.height - vPad * 2)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func attributed(_ content: Content) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5 * BubbleView.scale
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString()
        if !content.rows.isEmpty {
            paragraph.lineSpacing = 3.5 * BubbleView.scale
            for (i, row) in content.rows.enumerated() {
                text.append(NSAttributedString(string: "[" + row.name + "]", attributes: [
                    .font: BubbleView.prefixFont,
                    .foregroundColor: NSColor(srgbRed: 0.52, green: 0.76, blue: 1.0, alpha: 0.9),
                    .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: "  ", attributes: [
                    .font: BubbleView.titleFont,
                    .paragraphStyle: paragraph,
                ]))
                if let time = row.time, !time.isEmpty {
                    text.append(NSAttributedString(string: time + "  ", attributes: [
                        .font: BubbleView.monoFont,
                        .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                        .paragraphStyle: paragraph,
                    ]))
                }
                text.append(NSAttributedString(string: row.state, attributes: [
                    .font: BubbleView.titleFont,
                    .foregroundColor: row.color,
                    .paragraphStyle: paragraph,
                ]))
                if let pct = row.pct, !pct.isEmpty {
                    text.append(NSAttributedString(string: " · " + pct, attributes: [
                        .font: BubbleView.detailFont,
                        .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                        .paragraphStyle: paragraph,
                    ]))
                }
                if i < content.rows.count - 1 {
                    text.append(NSAttributedString(string: "\n", attributes: [
                        .font: BubbleView.titleFont,
                        .paragraphStyle: paragraph,
                    ]))
                }
            }
            if let detail = content.detail, !detail.isEmpty {
                text.append(NSAttributedString(string: "\n" + detail, attributes: [
                    .font: BubbleView.detailFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.66),
                    .paragraphStyle: paragraph,
                ]))
            }
            return text
        }
        if let prefix = content.prefix, !prefix.isEmpty {
            text.append(NSAttributedString(string: prefix + "  ", attributes: [
                .font: BubbleView.prefixFont,
                .foregroundColor: NSColor(srgbRed: 0.52, green: 0.76, blue: 1.0, alpha: 0.9),
            ]))
        }
        if let time = content.time, !time.isEmpty {
            text.append(NSAttributedString(string: time + "  ", attributes: [
                .font: BubbleView.monoFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            ]))
        }
        text.append(NSAttributedString(string: content.title, attributes: [
            .font: BubbleView.titleFont,
            .foregroundColor: content.titleColor ?? NSColor.white.withAlphaComponent(0.97),
        ]))
        if let detail = content.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: content.mono ? BubbleView.monoFont : BubbleView.detailFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.66),
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    func fit(_ content: Content, maxWidth: CGFloat, maxLines: Int) -> NSSize {
        let scale = BubbleView.scale
        let limit = max(160 * scale, maxWidth - hPad * 2)
        // boundingRect under-reports mixed-font wrapped text; the layout manager
        // gives the height NSTextField actually needs to draw every line
        let storage = NSTextStorage(attributedString: attributed(content))
        let manager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: limit, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        manager.addTextContainer(textContainer)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: textContainer)
        let used = manager.usedRect(for: textContainer)
        let lineHeight = ceil(BubbleView.titleFont.boundingRectForFont.height)
            + (content.rows.isEmpty ? 2 : 6) * scale
        let textHeight = min(ceil(used.height) + 4 * scale, lineHeight * CGFloat(maxLines))
        let width = maxWidth
        let height = max(textHeight, lineHeight) + vPad * 2
        return NSSize(width: width, height: height)
    }

    func show(_ content: Content, frame: NSRect, maxLines: Int) {
        self.frame = frame
        label.maximumNumberOfLines = maxLines
        label.cell?.truncatesLastVisibleLine = true
        label.attributedStringValue = attributed(content)
        needsLayout = true
        layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard glassView == nil else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.90).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class BadgeView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let container = NSView()
    private var glassView: NSView?
    private var hPad: CGFloat { 12 * BubbleView.scale }
    private var vPad: CGFloat { 9 * BubbleView.scale }
    private var cornerRadius: CGFloat { min(14 * BubbleView.scale, bounds.height / 2) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.maximumNumberOfLines = 9
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = false
        label.isSelectable = false
        container.wantsLayer = true
        container.addSubview(label)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.tintColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.3)
            glass.contentView = container
            addSubview(glass)
            glassView = glass
        } else {
            addSubview(container)
        }
    }

    override func layout() {
        super.layout()
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            container.layer?.backgroundColor = NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 0.42).cgColor
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
        }
        container.frame = bounds
        label.frame = NSRect(
            x: hPad,
            y: vPad,
            width: max(0, bounds.width - hPad * 2),
            height: max(0, bounds.height - vPad * 2)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func fit(_ text: NSAttributedString, maxWidth: CGFloat, minWidth: CGFloat) -> NSSize {
        let scale = BubbleView.scale
        let limit = max(80 * scale, maxWidth - hPad * 2)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: limit, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        manager.addTextContainer(textContainer)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: textContainer)
        let used = manager.usedRect(for: textContainer)
        let content = max(ceil(used.width), minWidth)
        // usedRect for mixed-size, tabbed text runs a few points short;
        // without slack the final line (API balance) is silently clipped.
        return NSSize(
            width: min(maxWidth, content + hPad * 2 + 8 * scale),
            height: ceil(used.height) + vPad * 2 + 8 * scale
        )
    }

    func show(_ text: NSAttributedString, frame: NSRect) {
        self.frame = frame
        label.attributedStringValue = text
        needsLayout = true
        layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard glassView == nil else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.92).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class PetApp: NSObject, NSApplicationDelegate {
    private var panel: PetPanel!
    private var petView: PetView!
    private var bubblePanel: PetPanel!
    private var bubbleView: BubbleView!
    private var badgePanel: PetPanel!
    private var badgeView: BadgeView!
    private var statsPanel: PetPanel!
    private var statsView: BadgeView!
    private var effortPanel: PetPanel!
    private var effortView: EffortCardView!
    private var effortShown = false
    private var effortSize = NSSize(width: 292, height: 96)
    private var effortOffsetY: CGFloat?
    private var effortBySession: [String: String] = [:]
    private var statsShown = false
    private enum StatsMode { case today, history }
    private var statsMode = StatsMode.today
    private var statsSize = NSSize.zero
    private var statsHideTimer: Timer?
    private var statsTimer: Timer?
    private var stats = PetStats(day: "")
    private var statsSeen = Set<String>()
    private var prevSessionStates: [String: String] = [:]
    private var newlyEnteredStates = Set<String>()
    private var statsDirty = false
    private var menuSessionIDs: [String] = []
    private var recentConversationIDs: [String] = []
    private var recentConversationProjects: [String] = []
    private var sessionModelsCache: [String] = []
    private var sessionModelsCacheAt: Double = 0
    private var sessionModelsRefreshing = false
    private var providerModels: [String] = []
    private var providerModelsCacheAt: Double = 0
    private var providerModelsRefreshing = false
    private var reviewOffIDs: Set<String> = []
    private var motionMap: [String: String] = [:]
    private var alertDot: AlertDotView!

    private var motions: [Motion] = []
    private var index = 0
    private var idleIndex = 0
    private var cheer: [Int] = []
    private var loop = true
    private var frameIndex = 0
    private var motionStart = CACurrentMediaTime()
    private var frameTimer: Timer?
    private var statusTimer: Timer?
    private var gcTimer: Timer?
    private var titlesTimer: Timer?
    private var frontTimer: Timer?
    private var titlesByTTY: [String: String] = [:]
    private var titlesBusy = false
    private var titlesPrimed = false
    private struct FileStamp: Equatable {
        var mtime: Date
        var size: Int
    }

    private struct CachedStatus {
        var stamp: FileStamp
        var status: PetStatus
    }

    private struct CachedTerm {
        var stamp: FileStamp
        var tty: String?
        var term: String?
    }

    private var sessions: [Session] = []
    private var statusCache: [String: CachedStatus] = [:]
    private var termCache: [String: CachedTerm] = [:]
    private struct CachedTranscript {
        var stamp: FileStamp
        var thinkingAfter: Double?
        var wantThinking: Bool
        var info: TranscriptInfo
    }
    private var transcriptCache: [String: CachedTranscript] = [:]
    private var primaryID: String?
    private var usageBySession: [String: Int] = [:]
    private var modelBySession: [String: String] = [:]
    private var pinnedSessionID: String?
    private var emptySince: Date?
    private var lastUsageRead: Double = 0
    private let scanQueue = DispatchQueue(label: "CodexPet.scan", qos: .utility)
    private var usageRefreshing = false
    private var transcriptRefreshing = false
    private var transcriptRefreshPending = false
    private var tokenScanning = false
    private var idleDimmed = false
    private var idleOpacity: CGFloat = 0.6
    private var balanceAlertThreshold = 5.0
    private var balanceLow = false
    private var mutedSessions = Set<String>()
    private var toolTimeout: Double = 600
    private var toolTimeoutOverride: Double?
    private var toolRunStart: [String: Double] = [:]
    private var toolRunAlerted = Set<String>()
    private var turnStartBySession: [String: Double] = [:]
    private var turnDurationBySession: [String: Double] = [:]
    private var alertText: String?
    private var alertUntil: Double = 0
    private var lastTokenScan: Double = 0
    private var tokenScanDay = ""
    private var tokenFileStates: [String: TranscriptUsageState] = [:]
    private var tokenFileMtimes: [String: Date] = [:]
    private var textScanStates: [String: TranscriptTextState] = [:]
    private var balanceLine: String?
    private var lastBalanceRead: Double = 0
    private var balanceFetching = false
    private var balanceFailures = 0
    private var balanceRetryInterval: Double = 60
    private var volcAK: String?
    private var volcSK: String?
    private var volcCredsLoaded = false
    private var volcLine: String?
    private var lastVolcRead: Double = 0
    private var volcFetching = false
    private var volcFailures = 0
    private var volcRetryInterval: Double = 60
    private var arkImageModels: [(id: String, status: String)] = []
    private var arkImageModelsAt: Double = 0
    private var arkImageModelsFetching = false
    private var arkImageModelsFailures = 0
    private var arkImageModelsInterval: Double = 300
    private var lastArkModelsRead: Double = 0
    private var arkImagePrices: [String: String] = [:]
    private var arkImagePricesAt: Double = 0
    private var arkImagePricesFetching = false
    private var lastArkPricesRead: Double = 0
    private var arkImageModel: String?
    private var scale: CGFloat = 0.4
    private var onTop = true
    private var savedCenterX: CGFloat?
    private var savedBottomY: CGFloat?
    private var positioned = false
    private static let defaultCenterX: CGFloat = 115
    private static let defaultBottomY: CGFloat = 49

    private var currentState = "idle"
    private var statusTool = ""
    private var statusDetail = ""
    private var statusMessage = ""
    private var statusTs: Double = 0
    private var transcriptPath: String?
    private var lastThinking = ""
    private var lastAssistantText = ""
    private var thinkingFloor: Double = 0
    private var contextWindow = 200_000
    private var hovered = false
    private var bubbleShown = false
    private var badgeShown = false
    private var bubbleSize = NSSize.zero
    private var badgeSize = NSSize.zero
    private var bubbleCache = ""
    private var badgeCache = ""
    private var showBubble = true
    private var lockedPet = false
    private var speed: Double = 1.0
    private var motionRepeats = 1
    private var showBadge = true
    private var soundEnabled = true
    private var soundDone = "Glass"
    private var soundFailed = "Basso"
    private var soundWaiting = "Ping"
    private var soundBalance = "Ping"
    private var soundTool = "Submarine"
    private var soundVolume: Double = 1.0
    private var currentOnly = false
    private var frontTTY: String?
    private var frontBusy = false
    private var doneBubbleUntil: Double = 0
    private var overrideUntil: Double = 0
    private var draggingPet = false
    private var lastTranscriptRead: Double = 0
    private var claimedSingleton = false
    private var goodbyePlayed = false
    private var doNotDisturb = false
    private var fontScale: CGFloat = 1.0
    private var petHidden = false
    private var hotKeyEnabled = true
    private var hotKeyFailed = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CODEX_PET_VOLC_PROBE"] == "1" {
            let hasCreds = loadVolcCredentials()
            var finished = false
            var result: String?
            fetchVolcBalance { line in
                result = line
                finished = true
            }
            let deadline = Date().addingTimeInterval(12)
            while !finished && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if finished {
                let text = result ?? (hasCreds ? "VOLC_BALANCE failure" : "VOLC_BALANCE no-credentials")
                FileHandle.standardError.write(Data((text + "\n").utf8))
                exit(0)
            }
            FileHandle.standardError.write(Data("VOLC_BALANCE timeout\n".utf8))
            exit(2)
        }
        if ProcessInfo.processInfo.environment["CODEX_PET_ARK_PROBE"] == "1" {
            var models: [(id: String, status: String)]?
            var prices: [String: String] = [:]
            var pricesDone = false
            fetchArkImageModels { result in models = result }
            fetchArkImagePrices { result in
                prices = result ?? [:]
                pricesDone = true
            }
            let deadline = Date().addingTimeInterval(25)
            while (models == nil || !pricesDone) && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if let models {
                for model in models {
                    let price = Self.arkPrice(prices: prices, id: model.id)
                    FileHandle.standardError.write(
                        Data((model.id + "\t" + model.status + "\t" + price + "\n").utf8)
                    )
                }
                exit(0)
            }
            FileHandle.standardError.write(Data("ARK_MODELS no-key-or-failure\n".utf8))
            exit(2)
        }
        guard claimSingleton() else {
            exit(0)
        }
        claimedSingleton = true
        loadState()
        loadReviewOff()
        _ = loadVolcCredentials()
        refreshArkImageModels(force: true)
        loadConfig()
        loadStats()
        loadMotions()
        makePanel()
        refreshVolcBalance(force: true)
        prefetchRecentModels()
        prefetchProviderModels()
        applyHotKeySetting()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        try? FileManager.default.removeItem(at: showFlagURL)
        try? FileManager.default.removeItem(at: hideFlagURL)
        try? FileManager.default.removeItem(at: hiddenFlagURL)
        applyMotion(index: index, loop: loop)
        startTimers()
        pollSessions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        saveStats()
        releaseSingleton()
    }

    private func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(PetState.self, from: data) {
            scale = CGFloat(state.scale)
            onTop = state.onTop
            savedCenterX = state.centerX.map { CGFloat($0) }
            savedBottomY = state.bottomY.map { CGFloat($0) }
            if let value = state.showBubble { showBubble = value }
            if let value = state.locked { lockedPet = value }
            if let value = state.speed { speed = min(max(value, 0.25), 3) }
            if let value = state.showBadge { showBadge = value }
            if let value = state.sound { soundEnabled = value }
            if let value = state.currentOnly { currentOnly = value }
            if let value = state.soundDone, alertSounds.contains(where: { $0.id == value }) { soundDone = value }
            if let value = state.soundFailed, alertSounds.contains(where: { $0.id == value }) { soundFailed = value }
            if let value = state.soundWaiting, alertSounds.contains(where: { $0.id == value }) { soundWaiting = value }
            if let value = state.soundBalance, alertSounds.contains(where: { $0.id == value }) { soundBalance = value }
            if let value = state.soundTool, alertSounds.contains(where: { $0.id == value }) { soundTool = value }
            if let value = state.soundVolume { soundVolume = min(max(value, 0), 3) }
            if let value = state.fontScale { fontScale = min(max(CGFloat(value), 0.85), 1.3) }
            if let value = state.dnd { doNotDisturb = value }
            if let value = state.hotkey { hotKeyEnabled = value }
            if let value = state.idleOpacity { idleOpacity = min(max(CGFloat(value), 0.1), 1.0) }
            if let value = state.pinnedSession, !value.isEmpty { pinnedSessionID = value }
            if let list = state.mutedSessions { mutedSessions = Set(list) }
            if let value = state.toolTimeout, value >= 0 {
                toolTimeoutOverride = value
                toolTimeout = value * 60
            }
            if let map = state.effortBySession {
                let known = Set(effortLevels.map { $0.id })
                for (session, level) in map where known.contains(level) {
                    effortBySession[session] = level
                }
            }
            if let map = state.motionMap {
                let known = Set(stateMotionGroups.flatMap { $0.key.split(separator: ",").map(String.init) })
                for (stateKey, motionKey) in map where known.contains(stateKey) {
                    motionMap[stateKey] = motionKey
                }
            }
        }
        if let raw = argValue("--scale"), let value = Double(raw) {
            scale = CGFloat(value)
        }
        scale = min(max(scale, 0.15), 1.5)
        BubbleView.scale = fontScale
    }

    private func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(PetConfig.self, from: data) {
            if let window = config.contextWindow, window >= 1000 { contextWindow = window }
            if let value = config.balanceAlert, value >= 0 { balanceAlertThreshold = value }
            if toolTimeoutOverride == nil,
               let value = config.toolTimeout, value >= 0 {
                toolTimeout = value * 60
            }
        }
        if let raw = argValue("--context-window"), let value = Int(raw), value >= 1000 {
            contextWindow = value
        }
    }

    private func loadMotionSpecs() -> [Motion]? {
        guard let data = try? Data(contentsOf: assetsDir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        let loaded = manifest.motions.compactMap { spec -> Motion? in
            let images = spec.frames.compactMap { loadImage(assetsDir.appendingPathComponent($0)) }
            guard images.count == spec.frames.count,
                  images.count == spec.durations.count,
                  spec.crop.count == 4 else { return nil }
            return Motion(
                key: spec.key,
                name: spec.name,
                width: CGFloat(spec.crop[2]),
                height: CGFloat(spec.crop[3]),
                images: images,
                durations: spec.durations.map { Double($0) / 1000.0 }
            )
        }
        return loaded.isEmpty ? nil : loaded
    }

    private func loadMotions() {
        guard let loaded = loadMotionSpecs() else {
            FileHandle.standardError.write(Data("CodexPet: cannot read assets/manifest.json\n".utf8))
            NSApp.terminate(nil)
            return
        }
        motions = loaded
        idleIndex = motions.firstIndex(where: { $0.key == "idle" }) ?? 0
        index = idleIndex
        cheer = motions.indices.filter { $0 != idleIndex }

        if let key = argValue("--motion"),
           let found = motions.firstIndex(where: { $0.key == key }) {
            index = found
            loop = found == idleIndex
        }
    }

    private func makePanel() {
        panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = onTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        petView = PetView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        petView.locked = lockedPet
        petView.onClick = { [weak self] in self?.focusTerminal() }
        petView.onDoubleClick = { [weak self] in self?.playNextCheer() }
        petView.onDragEnd = { [weak self] in self?.saveState() }
        petView.onDragStop = { [weak self] in self?.endDragRide() }
        petView.onDragDirection = { [weak self] dir in self?.dragRide(dir) }
        petView.onMenu = { [weak self] event in self?.showMenu(event) }
        petView.onHover = { [weak self] inside in self?.setHover(inside) }
        petView.onMove = { [weak self] in self?.layoutOverlays() }
        alertDot = AlertDotView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        alertDot.wantsLayer = true
        alertDot.isHidden = true
        petView.addSubview(alertDot)
        panel.contentView = petView
        panel.orderFrontRegardless()

        bubblePanel = makeOverlayPanel()
        bubbleView = BubbleView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        bubblePanel.contentView = bubbleView
        panel.addChildWindow(bubblePanel, ordered: .above)
        bubblePanel.orderOut(nil)

        badgePanel = makeOverlayPanel()
        badgeView = BadgeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        badgePanel.contentView = badgeView
        panel.addChildWindow(badgePanel, ordered: .above)
        badgePanel.orderOut(nil)

        statsPanel = makeOverlayPanel()
        statsView = BadgeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        statsPanel.contentView = statsView
        panel.addChildWindow(statsPanel, ordered: .above)
        statsPanel.orderOut(nil)

        effortPanel = makeOverlayPanel()
        effortPanel.ignoresMouseEvents = false
        effortView = EffortCardView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        effortPanel.contentView = effortView
        panel.addChildWindow(effortPanel, ordered: .above)
        effortPanel.orderOut(nil)
    }

    private func makeOverlayPanel() -> PetPanel {
        let overlay = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isFloatingPanel = true
        overlay.level = onTop ? .floating : .normal
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.becomesKeyOnlyIfNeeded = true
        overlay.hidesOnDeactivate = false
        return overlay
    }

    private func applyMotion(index newIndex: Int, loop shouldLoop: Bool) {
        guard newIndex >= 0, newIndex < motions.count else { return }
        index = newIndex
        loop = shouldLoop
        motionRepeats = 1
        frameIndex = 0
        motionStart = CACurrentMediaTime()

        let motion = motions[newIndex]
        petView.show(motion.images[0])

        let size = NSSize(width: motion.width * scale, height: motion.height * scale)
        let anchorX: CGFloat
        let bottom: CGFloat
        if positioned {
            anchorX = panel.frame.midX
            bottom = panel.frame.minY
        } else if let cx = savedCenterX, let by = savedBottomY {
            anchorX = cx
            bottom = by
        } else {
            anchorX = Self.defaultCenterX
            bottom = Self.defaultBottomY
        }
        positioned = true

        var frame = panel.frame
        frame.size = size
        frame.origin = NSPoint(x: anchorX - size.width / 2, y: bottom)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        petView.frame = NSRect(origin: .zero, size: size)
        positionAlertDot()
        clampToScreen()
        layoutOverlays()
        if !petHidden { scheduleFrame(after: nextFrameDelay()) }
    }

    private func positionAlertDot() {
        guard alertDot != nil else { return }
        let diameter = max(13, min(17, panel.frame.width * 0.11))
        alertDot.frame = NSRect(
            x: petView.bounds.width - diameter - 1,
            y: petView.bounds.height - diameter - 1,
            width: diameter,
            height: diameter
        )
    }

    private func updateAlertDot() {
        guard alertDot != nil else { return }
        alertDot.count = sessions.filter { $0.state == "waiting" || $0.state == "failed" }.count
    }

    @discardableResult
    private func setMotion(_ key: String, loop shouldLoop: Bool, repeats: Int = 1) -> Bool {
        guard let target = motions.firstIndex(where: { $0.key == key }) else { return false }
        let count = max(repeats, 1)
        if target == index && shouldLoop == loop && count == motionRepeats { return true }
        applyMotion(index: target, loop: shouldLoop)
        motionRepeats = count
        return true
    }

    private func clampToScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var frame = panel.frame
        if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width }
        if frame.minX < vf.minX { frame.origin.x = vf.minX }
        if frame.minY < vf.minY { frame.origin.y = vf.minY }
        if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.height }
        panel.setFrame(frame, display: false)
    }

    @objc private func screensChanged() {
        guard panel != nil else { return }
        clampToScreen()
        savedCenterX = panel.frame.midX
        savedBottomY = panel.frame.minY
        layoutOverlays()
        if statsShown { positionStats() }
        saveState()
    }

    @objc private func appActivated(_ note: Notification) {
        guard frontmostTerminalHint() != nil else { return }
        refreshFrontTTY()
        refreshTitles()
    }

    private func scheduleFrame(after delay: TimeInterval) {
        frameTimer?.invalidate()
        let step = max(delay, 0.005)
        let timer = Timer(
            timeInterval: step,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = min(step * 0.15, 0.02)
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func nextFrameDelay() -> TimeInterval {
        guard motions.indices.contains(index) else { return 0.2 }
        let motion = motions[index]
        let total = motion.total
        guard total > 0, !motion.durations.isEmpty else { return 0.2 }
        let playback = max(idleAnimationActive ? speed * 0.5 : speed, 0.01)
        let elapsed = (CACurrentMediaTime() - motionStart) * playback
        let repeats = max(motionRepeats, 1)
        let span = total * (loop ? 1 : Double(repeats))
        if !loop && elapsed >= span { return 0.05 }
        let t = (loop || repeats > 1) ? fmod(elapsed, total) : elapsed
        var cursor = 0.0
        for duration in motion.durations {
            if t < cursor + duration {
                return max((cursor + duration - t) / playback, 0.005)
            }
            cursor += duration
        }
        return 0.05
    }

    // idle state uses its mapped motion; after a finished turn the loop also
    // returns to that motion while currentState stays "done"
    private var idleAnimationActive: Bool {
        guard !draggingPet, CACurrentMediaTime() >= overrideUntil else { return false }
        if currentState == "idle" { return true }
        return motions.indices.contains(index) && motions[index].key == motionKey(for: "idle")
    }

    private func startTimers() {
        scheduleFrame(after: 0.05)

        let status = Timer(
            timeInterval: 0.3,
            target: self,
            selector: #selector(pollSessions),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(status, forMode: .common)
        statusTimer = status

        let gc = Timer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(gcSessions),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(gc, forMode: .common)
        gcTimer = gc

        let titles = Timer(
            timeInterval: 8.0,
            target: self,
            selector: #selector(refreshTitles),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(titles, forMode: .common)
        titlesTimer = titles
        refreshTitles()

        let front = Timer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(refreshFrontTTY),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(front, forMode: .common)
        frontTimer = front

        let stats5 = Timer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(tickStats),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(stats5, forMode: .common)
        statsTimer = stats5
    }

    private func frontmostTerminalHint() -> String? {
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case "com.apple.Terminal": return "Apple_Terminal"
        case "com.googlecode.iterm2": return "iTerm.app"
        default: return nil
        }
    }

    private func runningTerminalHint() -> String? {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        if ids.contains("com.googlecode.iterm2") { return "iTerm.app" }
        if ids.contains("com.apple.Terminal") { return "Apple_Terminal" }
        return nil
    }

    private func terminalRunning(_ term: String) -> Bool {
        let bundle = term.hasPrefix("iTerm") ? "com.googlecode.iterm2" : "com.apple.Terminal"
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }
    }

    @objc private func refreshFrontTTY() {
        guard currentOnly, !frontBusy else { return }
        let front = frontmostTerminalHint()
        if front == nil, frontTTY?.isEmpty == false { return }
        let termHint: String?
        if let front {
            termHint = front
        } else {
            // In another app, follow the most recently active session's
            // terminal instead of always preferring iTerm2.
            termHint = sessions.max { $0.ts < $1.ts }?.term
                ?? sessions.compactMap { $0.term }.first
                ?? runningTerminalHint()
        }
        let useITerm = termHint?.hasPrefix("iTerm") == true
        guard terminalRunning(useITerm ? "iTerm.app" : "Apple_Terminal") else {
            frontTTY = ""
            return
        }
        let script = useITerm ? """
        tell application "iTerm2"
        if (count of windows) = 0 then return ""
        return tty of current session of current window
        end tell
        """ : """
        tell application "Terminal"
        if (count of windows) = 0 then return ""
        return tty of selected tab of front window
        end tell
        """
        frontBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.frontBusy = false
                self.frontTTY = text.hasPrefix("/dev/") ? text : ""
            }
        }
    }

    @objc private func refreshTitles() {
        guard !titlesBusy, !petHidden else { return }
        // Titles only matter when they can be seen: warm once, then follow visibility.
        let activeState = currentState != "idle" && currentState != "done"
        guard hovered || bubbleShown || activeState || !titlesPrimed else { return }
        let activeTerms = sessions.filter { $0.tty != nil }.map { $0.term }
        guard !activeTerms.isEmpty else { return }
        let wantsTerminal = activeTerms.contains { ($0 ?? "Apple_Terminal") == "Apple_Terminal" }
            && terminalRunning("Apple_Terminal")
        let wantsITerm = activeTerms.contains { $0?.hasPrefix("iTerm") == true }
            && terminalRunning("iTerm.app")
        guard wantsTerminal || wantsITerm else { return }
        titlesBusy = true
        var script = "set out to \"\"\n"
        if wantsTerminal {
            script += """
            tell application "Terminal"
            repeat with w in windows
            repeat with i from 1 to count of tabs of w
            set t to tab i of w
            set out to out & (tty of t) & "~~" & (custom title of t) & linefeed
            end repeat
            end repeat
            end tell

            """
        }
        if wantsITerm {
            script += """
            tell application "iTerm2"
            repeat with w in windows
            repeat with t in tabs of w
            repeat with s in sessions of t
            set out to out & (tty of s) & "~~" & (name of s) & linefeed
            end repeat
            end repeat
            end repeat
            end tell

            """
        }
        script += "return out"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var map: [String: String] = [:]
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                let parts = line.components(separatedBy: "~~")
                guard parts.count >= 2 else { continue }
                let tty = parts[0].trimmingCharacters(in: .whitespaces)
                var title = parts[1].trimmingCharacters(in: .whitespaces)
                title = String(title.drop(while: { !$0.isLetter && !$0.isNumber }))
                if !tty.isEmpty, !title.isEmpty { map[tty] = title }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.titlesBusy = false
                self.titlesPrimed = true
                if map != self.titlesByTTY {
                    self.titlesByTTY = map
                    self.updateBubble()
                    self.updateBadge()
                }
            }
        }
    }

    private func displayName(_ session: Session) -> String {
        if let tty = session.tty, let title = titlesByTTY[tty], !title.isEmpty { return title }
        return session.name
    }

    @objc private func tick() {
        guard !petHidden, !motions.isEmpty else { return }
        let motion = motions[index]
        let total = motion.total
        guard total > 0 else { return }

        let playback = idleAnimationActive ? speed * 0.5 : speed
        let elapsed = (CACurrentMediaTime() - motionStart) * playback
        let repeats = max(motionRepeats, 1)
        let span = total * (loop ? 1 : Double(repeats))
        if !loop && elapsed >= span {
            let wasOverride = overrideUntil > 0
            overrideUntil = 0
            if wasOverride {
                if currentState == "idle" || currentState == "done" {
                    setMotion(motionKey(for: "idle"), loop: true)
                } else {
                    followStateMotion()
                }
            } else if currentState == "failed" {
                setMotion(motionKey(for: "thinking"), loop: true)
            } else {
                setMotion(motionKey(for: "idle"), loop: true)
            }
            scheduleFrame(after: nextFrameDelay())
            return
        }

        let t = (loop || repeats > 1) ? fmod(elapsed, total) : elapsed
        var cursor = 0.0
        var next = motion.durations.count - 1
        for (i, duration) in motion.durations.enumerated() {
            if t < cursor + duration {
                next = i
                break
            }
            cursor += duration
        }
        if next != frameIndex {
            frameIndex = next
            petView.show(motion.images[next])
        }
        scheduleFrame(after: nextFrameDelay())
    }

    @objc private func pollSessions() {
        if FileManager.default.fileExists(atPath: showFlagURL.path) {
            try? FileManager.default.removeItem(at: showFlagURL)
            if petHidden { togglePetVisible() }
        }
        if FileManager.default.fileExists(atPath: hideFlagURL.path) {
            try? FileManager.default.removeItem(at: hideFlagURL)
            if !petHidden { togglePetVisible() }
        }
        syncHoverFromPointer()
        var loaded = loadSessions()
        trackSessionStates(loaded)
        trackTurnEvents(loaded)
        if currentOnly, let tty = frontTTY {
            let focused = loaded.filter { $0.tty == tty }
            if !focused.isEmpty { loaded = focused }
        }
        let hadSessions = !sessions.isEmpty
        sessions = loaded
        trackToolTimeouts(loaded)
        updateAlertDot()
        guard let primary = sessions.first else {
            primaryID = nil
            applyState("idle")
            if hadSessions, !goodbyePlayed,
               let wave = motions.firstIndex(where: { $0.key == "waving" }) {
                goodbyePlayed = true
                overrideUntil = CACurrentMediaTime() + motions[wave].total + 0.2
                applyMotion(index: wave, loop: false)
            }
            updateBubble()
            updateBadge()
            updateIdleOpacity()
            return
        }

        if goodbyePlayed { goodbyePlayed = false }
        let switched = primary.id != primaryID
        primaryID = primary.id
        statusTool = primary.tool
        statusDetail = primary.detail
        statusMessage = primary.message
        statusTs = primary.ts
        if let path = primary.transcript, !path.isEmpty { transcriptPath = path }

        let changed = primary.state != currentState
        if switched {
            lastThinking = ""
            lastAssistantText = ""
            thinkingFloor = primary.ts
            refreshTitles()
        }
        applyState(primary.state)
        if switched || changed {
            refreshTranscript(force: true)
        } else if currentState == "thinking" || hovered {
            refreshTranscript()
        }
        if hovered { refreshUsages() }
        updateBubble()
        updateBadge()
        updateIdleOpacity()
    }

    private func loadSessions() -> [Session] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        var stamps: [String: FileStamp] = [:]
        for url in entries {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let mtime = values.contentModificationDate,
               let size = values.fileSize {
                stamps[url.path] = FileStamp(mtime: mtime, size: size)
            }
        }
        var liveIDs = Set<String>()
        var result: [Session] = []
        for url in entries where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            liveIDs.insert(id)
            let stamp = stamps[url.path]
            let status: PetStatus
            if let stamp, let cached = statusCache[id], cached.stamp == stamp {
                status = cached.status
            } else {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? JSONDecoder().decode(PetStatus.self, from: data) else {
                    statusCache[id] = nil
                    continue
                }
                status = decoded
                statusCache[id] = stamp.map { CachedStatus(stamp: $0, status: decoded) }
            }
            var tty: String?
            var term: String?
            let termURL = runDir.appendingPathComponent(id + ".term")
            if let stamp = stamps[termURL.path] {
                if let cached = termCache[id], cached.stamp == stamp {
                    tty = cached.tty
                    term = cached.term
                } else if let raw = try? String(contentsOf: termURL, encoding: .utf8) {
                    let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let value = parts.count == 2 ? String(parts[1]) : raw
                    if value.hasPrefix("/dev/") { tty = value }
                    if parts.count == 2, !parts[0].isEmpty { term = String(parts[0]) }
                    termCache[id] = CachedTerm(stamp: stamp, tty: tty, term: term)
                } else {
                    termCache[id] = nil
                }
            } else {
                termCache[id] = nil
            }
            let transcriptID = status.transcript.map {
                (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            let resumeID = status.sessionId ?? transcriptID
            result.append(Session(
                id: id,
                state: status.state,
                event: status.event,
                ts: status.ts ?? 0,
                cwd: status.cwd ?? "",
                transcript: status.transcript,
                tool: status.tool ?? "",
                detail: status.detail ?? "",
                message: status.message ?? "",
                tty: tty,
                term: term,
                turnStart: status.turnStart,
                resumeID: resumeID
            ))
        }
        if statusCache.count != liveIDs.count || !liveIDs.isSuperset(of: statusCache.keys) {
            statusCache = statusCache.filter { liveIDs.contains($0.key) }
        }
        if termCache.count > liveIDs.count || !liveIDs.isSuperset(of: termCache.keys) {
            termCache = termCache.filter { liveIDs.contains($0.key) }
        }
        return result.sorted { a, b in
            if let pin = pinnedSessionID {
                let aPinned = a.resumeID == pin && a.state != "idle" && a.state != "done"
                let bPinned = b.resumeID == pin && b.state != "idle" && b.state != "done"
                if aPinned != bPinned { return aPinned }
            }
            let pa = statePriority(a.state)
            let pb = statePriority(b.state)
            if pa != pb { return pa > pb }
            return a.ts > b.ts
        }
    }

    private func loadRecentConversations(limit: Int) -> [RecentConversation] {
        let text = readTail(historyURL, bytes: 524_288)
        guard !text.isEmpty else { return [] }
        var byID: [String: RecentConversation] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String,
                  id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
                  let project = object["project"] as? String, !project.isEmpty,
                  let stamp = object["timestamp"] as? NSNumber else { continue }
            let ts = stamp.doubleValue / 1000
            let display = (object["display"] as? String ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if var existing = byID[id] {
                if ts >= existing.ts { existing.project = project }
                existing.ts = max(existing.ts, ts)
                if !display.isEmpty, !display.hasPrefix("/") { existing.prompt = display }
                byID[id] = existing
            } else {
                byID[id] = RecentConversation(
                    id: id,
                    project: project,
                    prompt: display.hasPrefix("/") ? "" : display,
                    ts: ts
                )
            }
        }
        let active = Set(sessions.compactMap { $0.resumeID })
        return byID.values
            .filter { !active.contains($0.id) }
            .filter { FileManager.default.fileExists(atPath: $0.project) }
            .sorted { $0.ts > $1.ts }
            .prefix(max(limit, 1))
            .map { $0 }
    }

    private func recentConversationTitle(_ conversation: RecentConversation) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let project = conversation.project == home
            ? "~"
            : (conversation.project as NSString).lastPathComponent
        let name = project.isEmpty ? "会话" : shortName(project, limit: 16)
        let prompt = conversation.prompt.isEmpty
            ? "会话 " + String(conversation.id.prefix(8))
            : shortName(conversation.prompt, limit: 28)
        return "\(relativeTime(conversation.ts)) · \(name) · \(prompt)"
    }

    private func relativeTime(_ ts: Double) -> String {
        let delta = max(Date().timeIntervalSince1970 - ts, 0)
        if delta < 60 { return "刚刚" }
        if delta < 3_600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3_600)) 小时前" }
        if delta < 604_800 { return "\(Int(delta / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    private func refreshUsages() {
        let now = CACurrentMediaTime()
        guard now - lastUsageRead > 0.6, !usageRefreshing else { return }
        lastUsageRead = now
        usageRefreshing = true
        let snapshot = sessions.compactMap { session -> (String, String)? in
            guard let path = session.transcript, !path.isEmpty else { return nil }
            return (session.id, path)
        }
        scanQueue.async { [weak self] in
            guard let self else { return }
            var next: [String: Int] = [:]
            var models: [String: String] = [:]
            for (id, path) in snapshot {
                let info = self.cachedTranscript(path: path, thinkingAfter: nil, wantThinking: false)
                if let model = info.model, !model.isEmpty {
                    models[id] = model
                }
                if let used = info.used, used > 0 {
                    next[id] = used
                }
            }
            let livePaths = Set(snapshot.map { $0.1 })
            self.transcriptCache = self.transcriptCache.filter { livePaths.contains($0.key) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.usageRefreshing = false
                self.usageBySession = next
                self.modelBySession = models
                for (id, used) in next where self.stats.usage[id] != used {
                    self.stats.usage[id] = used
                    self.statsDirty = true
                }
            }
        }
    }

    private func refreshTodayTokens() {
        let now = CACurrentMediaTime()
        let interval: Double = (hovered || statsShown) ? 4 : 120
        guard now - lastTokenScan > interval, !tokenScanning else { return }
        lastTokenScan = now
        let day = todayKey()
        if tokenScanDay != day {
            tokenScanDay = day
            tokenFileStates.removeAll()
            tokenFileMtimes.removeAll()
        }
        tokenScanning = true
        let scanDay = tokenScanDay
        let states = tokenFileStates
        let mtimes = tokenFileMtimes
        scanQueue.async { [weak self] in
            guard let self else { return }
            var states = states
            var mtimes = mtimes
            let fm = FileManager.default
            let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            var total = 0
            var caughtUp = true
            var live = Set<String>()
            let dirs = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let nowDate = Date()
            for dir in dirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let files = (try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let values = try? file.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey]
                    ),
                        let mtime = values.contentModificationDate,
                        Calendar.current.isDate(mtime, inSameDayAs: nowDate)
                    else { continue }
                    let path = file.path
                    live.insert(path)
                    var state = states[path] ?? TranscriptUsageState()
                    let size = UInt64(values.fileSize ?? 0)
                    if size < state.offset {
                        state = TranscriptUsageState()
                    }
                    if mtimes[path] != mtime || size > state.offset {
                        self.scanUsageFile(path: path, state: &state)
                        mtimes[path] = mtime
                    }
                    states[path] = state
                    if state.offset + 65536 < size { caughtUp = false }
                    total += state.tokens
                }
            }
            for path in states.keys where !live.contains(path) {
                states.removeValue(forKey: path)
                mtimes.removeValue(forKey: path)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tokenScanning = false
                guard self.tokenScanDay == scanDay else { return }
                self.tokenFileStates = states
                self.tokenFileMtimes = mtimes
                if caughtUp && self.stats.tokens != total {
                    self.stats.tokens = total
                    self.statsDirty = true
                    self.updateBadge()
                    self.refreshStatsCard()
                }
            }
        }
    }

    // Appends only; dedupes streamed copies by message id.
    private func scanUsageFile(path: String, state: inout TranscriptUsageState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size > state.offset else { return }
            try handle.seek(toOffset: state.offset)
            let chunk = try handle.read(upToCount: Int(min(size - state.offset, UInt64(8 << 20)))) ?? Data()
            guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                // Keep a trailing partial line for the next scan; only skip
                // it when the read cap was hit, or the offset would stall.
                if chunk.count >= 8 << 20 { state.offset += UInt64(chunk.count) }
                return
            }
            let cut = chunk.distance(from: chunk.startIndex, to: lastNewline) + 1
            let body = chunk.prefix(cut)
            state.offset += UInt64(cut)
            for line in body.split(separator: 0x0A) where line.range(of: Self.usageNeedle) != nil {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = root["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let id = (message["id"] as? String)
                    ?? (root["requestId"] as? String)
                    ?? (root["uuid"] as? String)
                if let id, !state.seen.insert(id).inserted { continue }
                guard let stamp = root["timestamp"] as? String,
                      let date = isoFractional.date(from: stamp) ?? isoPlain.date(from: stamp),
                      Calendar.current.isDateInToday(date) else { continue }
                state.tokens += (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
            }
        } catch {}
    }

    private func applyState(_ newState: String) {
        guard newState != currentState else { return }
        currentState = newState
        if newState == "thinking" {
            lastThinking = ""
            thinkingFloor = statusTs > 0 ? statusTs : Date().timeIntervalSince1970
        }
        if newState == "done" {
            doneBubbleUntil = CACurrentMediaTime() + 4.5
        }
        if soundEnabled && !doNotDisturb && !stateFullyMuted(newState) {
            switch newState {
            case "done": playSound(soundDone)
            case "failed": playSound(soundFailed)
            case "waiting": playSound(soundWaiting)
            default: break
            }
        }
        followStateMotion()
        updateIdleOpacity()
    }

    private func sessionIsMuted(_ session: Session) -> Bool {
        if let rid = session.resumeID { return mutedSessions.contains(rid) }
        return mutedSessions.contains(session.id)
    }

    // Attribute the alert to the sessions that just entered this state, so an
    // old unmuted session cannot speak for a newly muted one (or vice versa).
    private func stateFullyMuted(_ state: String) -> Bool {
        let matching = sessions.filter { $0.state == state }
        guard !matching.isEmpty else {
            guard let id = primaryID,
                  let session = sessions.first(where: { $0.id == id }) else { return false }
            return sessionIsMuted(session)
        }
        let entering = matching.filter { newlyEnteredStates.contains($0.id) }
        return (entering.isEmpty ? matching : entering).allSatisfy { sessionIsMuted($0) }
    }

    private func trackToolTimeouts(_ loaded: [Session]) {
        let now = Date().timeIntervalSince1970
        let toolStates: Set<String> = ["bash", "search", "tool"]
        let activeIDs = Set(loaded.filter { toolStates.contains($0.state) }.map { $0.id })
        toolRunStart = toolRunStart.filter { activeIDs.contains($0.key) }
        toolRunAlerted = toolRunAlerted.filter { activeIDs.contains($0) }
        guard toolTimeout > 0 else { return }
        let displayedPrimary = loaded.first?.id
        let hasWaiting = loaded.contains { $0.state == "waiting" }
        for session in loaded where toolStates.contains(session.state) {
            let start: Double
            if session.ts > 0 {
                start = session.ts
            } else if let existing = toolRunStart[session.id] {
                start = existing
            } else {
                start = now
            }
            if toolRunStart[session.id] != start {
                toolRunStart[session.id] = start
                toolRunAlerted.remove(session.id)
            }
            guard now - start >= toolTimeout, !toolRunAlerted.contains(session.id) else { continue }
            toolRunAlerted.insert(session.id)
            let minutes = max(Int((now - start) / 60), 1)
            let name = shortName(displayName(session), limit: 12)
            let message = "「\(name)」工具已运行 \(minutes) 分钟"
            // A waiting permission prompt outranks a background timeout; keep
            // its bubble readable and only beep for the background session.
            let bubbleBlocked = hasWaiting && session.id != displayedPrimary
            if sessionIsMuted(session) {
                if !bubbleBlocked { triggerAlert(message, silent: true) }
            } else if bubbleBlocked {
                if soundEnabled && !doNotDisturb { playSound(soundTool) }
            } else {
                triggerAlert(message, sound: soundTool)
            }
        }
    }

    private func motionKey(for state: String) -> String {
        if let custom = motionMap[state], motions.contains(where: { $0.key == custom }) {
            return custom
        }
        switch state {
        case "thinking": return "review"
        case "search": return "running"
        case "bash", "tool": return "debug"
        case "waiting": return "waiting"
        case "start": return "jumping"
        case "done": return "waving"
        case "failed": return "failed"
        default: return "idle"
        }
    }

    private func followStateMotion() {
        guard !draggingPet else { return }
        guard CACurrentMediaTime() >= overrideUntil else { return }
        switch currentState {
        case "thinking":
            setMotion(motionKey(for: "thinking"), loop: true)
        case "bash", "search", "tool":
            setMotion(motionKey(for: currentState), loop: true)
        case "waiting":
            setMotion(motionKey(for: "waiting"), loop: true)
        case "start":
            setMotion(motionKey(for: "start"), loop: false)
        case "done":
            setMotion(motionKey(for: "done"), loop: false, repeats: 5)
        case "failed":
            setMotion(motionKey(for: "failed"), loop: false)
        default:
            setMotion(motionKey(for: "idle"), loop: true)
        }
    }

    private func refreshTranscript(force: Bool = false) {
        guard let path = transcriptPath else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastTranscriptRead > 0.45 else { return }
        if transcriptRefreshing {
            if force { transcriptRefreshPending = true }
            return
        }
        lastTranscriptRead = now
        transcriptRefreshing = true
        let state = currentState
        let thinkingAfter = state == "thinking" ? thinkingFloor : nil
        scanQueue.async { [weak self] in
            guard let self else { return }
            let info = self.cachedTranscript(path: path, thinkingAfter: thinkingAfter, wantThinking: true)
            let scanned = self.scanAssistantText(path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transcriptRefreshing = false
                let retry = self.transcriptRefreshPending
                self.transcriptRefreshPending = false
                guard self.transcriptPath == path else {
                    self.refreshTranscript(force: true)
                    return
                }
                if !scanned.isEmpty {
                    self.lastAssistantText = scanned
                } else if let text = info.text, !text.isEmpty {
                    self.lastAssistantText = text
                }
                if self.currentState == "thinking",
                   let thinking = info.thinking, !thinking.isEmpty {
                    self.lastThinking = thinking
                }
                if retry { self.refreshTranscript(force: true) }
            }
        }
    }

    private static let assistantNeedleFlat = Data("\"type\":\"assistant\"".utf8)
    private static let assistantNeedleSpaced = Data("\"type\": \"assistant\"".utf8)
    private static let usageNeedle = Data("\"usage\"".utf8)

    private func isAssistantLine(_ line: Data.SubSequence) -> Bool {
        line.range(of: Self.assistantNeedleFlat) != nil
            || line.range(of: Self.assistantNeedleSpaced) != nil
    }

    private func assistantText(_ line: Data.SubSequence) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              (object["type"] as? String) == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content.reversed() where (block["type"] as? String) == "text" {
            if let value = block["text"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    // Finds the newest assistant text once, then follows append-only growth.
    private func scanAssistantText(path: String) -> String {
        var state = textScanStates[path] ?? TranscriptTextState()
        guard let handle = FileHandle(forReadingAtPath: path) else { return state.text }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return state.text }

        if state.offset == 0 || size < state.offset {
            let window: UInt64 = 16 << 20
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            var data = handle.readDataToEndOfFile()
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: newline)...])
            }
            var latest: String?
            for line in data.split(separator: 0x0A) where isAssistantLine(line) {
                if let value = assistantText(line) { latest = value }
            }
            if let latest { state.text = latest }
            state.offset = size
            textScanStates[path] = state
            return state.text
        }

        guard size > state.offset else { return state.text }
        let cap: UInt64 = 8 << 20
        if size - state.offset > cap {
            state.offset = size - cap
        }
        do {
            try handle.seek(toOffset: state.offset)
            let data = handle.readDataToEndOfFile()
            guard let newline = data.lastIndex(of: 0x0A) else {
                state.offset = size
                return state.text
            }
            let cut = data.distance(from: data.startIndex, to: newline) + 1
            state.offset += UInt64(cut)
            var latest: String?
            for line in data.prefix(cut).split(separator: 0x0A) where isAssistantLine(line) {
                if let value = assistantText(line) { latest = value }
            }
            if let latest { state.text = latest }
            textScanStates[path] = state
            return state.text
        } catch {
            return state.text
        }
    }

    // Only valid on scanQueue: avoids re-reading the tail when the file is unchanged.
    private func cachedTranscript(path: String, thinkingAfter: Double?, wantThinking: Bool) -> TranscriptInfo {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = FileStamp(
            mtime: values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0
        )
        if let hit = transcriptCache[path], hit.stamp == stamp,
           hit.thinkingAfter == thinkingAfter, hit.wantThinking == wantThinking {
            return hit.info
        }
        let info = readTranscript(path: path, thinkingAfter: thinkingAfter, wantThinking: wantThinking)
        transcriptCache[path] = CachedTranscript(
            stamp: stamp,
            thinkingAfter: thinkingAfter,
            wantThinking: wantThinking,
            info: info
        )
        return info
    }

    private func readTranscript(path: String, thinkingAfter: Double?, wantThinking: Bool = true) -> TranscriptInfo {
        var info = TranscriptInfo()
        let text = readTail(URL(fileURLWithPath: path), bytes: 262_144)
        guard !text.isEmpty else { return info }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") else {
                continue
            }
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }

            if info.model == nil {
                info.model = message["model"] as? String
            }
            if info.used == nil, let usage = message["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let created = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cached = usage["cache_read_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let total = input + created + cached + output
                if total > 0 { info.used = total }
            }
            if info.text == nil || info.thinking == nil,
               let content = message["content"] as? [[String: Any]] {
                if info.text == nil {
                    for block in content.reversed() where (block["type"] as? String) == "text" {
                        if let value = block["text"] as? String,
                           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            info.text = value
                            break
                        }
                    }
                }
                let entryTs = parseTimestamp(object["timestamp"] as? String)
                let allowed = thinkingAfter == nil || (entryTs ?? 0) >= (thinkingAfter! - 1.0)
                if allowed, info.thinking == nil {
                    for block in content.reversed() where (block["type"] as? String) == "thinking" {
                        if let value = block["thinking"] as? String,
                           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            info.thinking = value
                            break
                        }
                    }
                }
            }
            if info.used != nil && info.text != nil && (info.thinking != nil || !wantThinking) { break }
        }
        return info
    }

    private func bubbleContent() -> BubbleView.Content? {
        if CACurrentMediaTime() < alertUntil, let alertText {
            return BubbleView.Content(
                prefix: "⚠",
                title: alertText,
                detail: nil,
                mono: false,
                titleColor: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.32, alpha: 1)
            )
        }
        let narration = lastAssistantText.isEmpty ? nil : "⏺ " + headSnippet(lastAssistantText, 220)
        if !hovered, sessions.count >= 2 {
            let running = sessions.filter { $0.state != "idle" && $0.state != "done" }
            guard !running.isEmpty else { return nil }
            let capacity = narration == nil ? 3 : 2
            let visible = Array(running.prefix(capacity))
            let overflow = running.count - visible.count
            let avail = 300 * fontScale - 34 * BubbleView.scale
            func textWidth(_ value: String, _ font: NSFont) -> CGFloat {
                (value as NSString).size(withAttributes: [.font: font]).width
            }
            func rowWidth(name: String, state: String, time: String?, pct: String?) -> CGFloat {
                var total = textWidth("[" + name + "]", BubbleView.prefixFont) + 7 * BubbleView.scale
                if let time, !time.isEmpty { total += textWidth(time + "  ", BubbleView.monoFont) }
                total += textWidth(state, BubbleView.titleFont)
                if let pct, !pct.isEmpty { total += textWidth(" · " + pct, BubbleView.detailFont) }
                return total
            }
            var rows: [BubbleView.Row] = []
            for (i, session) in visible.enumerated() {
                var pct = usageBySession[session.id].flatMap { used -> String? in
                    guard used > 0 else { return nil }
                    return "\(Int((Double(used) / Double(max(contextWindow, 1)) * 100).rounded()))%"
                }
                let time = turnElapsedLabel(for: session)
                var state = stateLabel(session.state)
                if i == visible.count - 1, overflow > 0 {
                    state += " · 还有 \(overflow) 个"
                }
                let fullName = displayName(session)
                var name = shortName(fullName, limit: 16)
                if rowWidth(name: name, state: state, time: time, pct: pct) > avail {
                    pct = nil
                    var limit = name.count
                    while limit > 6,
                          rowWidth(name: name, state: state, time: time, pct: nil) > avail {
                        limit -= 1
                        name = shortName(fullName, limit: limit)
                    }
                }
                rows.append(BubbleView.Row(
                    name: name,
                    state: state,
                    color: stateColor(session.state),
                    time: time,
                    pct: pct
                ))
            }
            return BubbleView.Content(
                prefix: nil,
                title: "",
                detail: narration,
                mono: false,
                rows: rows
            )
        }
        let primarySession = primaryID.flatMap { id in
            sessions.first(where: { $0.id == id })
        }
        let prefix = primarySession.map { "[" + shortName(displayName($0), limit: 14) + "]" }
        let elapsed = primarySession.flatMap { turnElapsedLabel(for: $0) }
        switch currentState {
        case "thinking":
            return BubbleView.Content(
                prefix: prefix,
                title: "思考中",
                detail: narration ?? (lastThinking.isEmpty ? nil : tailSnippet(lastThinking, 200)),
                mono: false,
                time: elapsed,
                titleColor: stateColor(currentState)
            )
        case "bash", "search", "tool":
            let name = statusTool.isEmpty ? "工具" : statusTool
            return BubbleView.Content(
                prefix: prefix,
                title: "正在运行 " + name,
                detail: narration,
                mono: false,
                time: elapsed,
                titleColor: stateColor(currentState)
            )
        case "waiting":
            return BubbleView.Content(
                prefix: prefix,
                title: "等待你的操作",
                detail: statusMessage.isEmpty ? nil : statusMessage,
                mono: false,
                time: elapsed,
                titleColor: stateColor(currentState)
            )
        case "failed":
            let suffix = statusTool.isEmpty ? "" : " · " + statusTool
            return BubbleView.Content(
                prefix: prefix,
                title: "工具执行失败" + suffix,
                detail: statusMessage.isEmpty ? nil : statusMessage,
                mono: false,
                titleColor: stateColor(currentState)
            )
        case "done":
            guard CACurrentMediaTime() < doneBubbleUntil else { return nil }
            let duration = primaryID.flatMap { turnDurationBySession[$0] }
            let title = duration.map { "完成 · 用时 " + formatDuration($0) } ?? "完成"
            return BubbleView.Content(
                prefix: prefix,
                title: title,
                detail: narration,
                mono: false,
                titleColor: stateColor(currentState)
            )
        default:
            return nil
        }
    }

    private func shortName(_ name: String, limit: Int = 16) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "…"
    }

    private func stateColor(_ state: String) -> NSColor {
        switch state {
        case "waiting": return NSColor(srgbRed: 1.0, green: 0.72, blue: 0.32, alpha: 1)
        case "bash", "search", "tool": return NSColor(srgbRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
        case "thinking": return NSColor(srgbRed: 0.45, green: 0.86, blue: 0.78, alpha: 1)
        case "failed": return NSColor(srgbRed: 1.0, green: 0.47, blue: 0.45, alpha: 1)
        case "done", "start": return NSColor(srgbRed: 0.58, green: 0.88, blue: 0.60, alpha: 1)
        default: return NSColor.white.withAlphaComponent(0.45)
        }
    }

    private func badgeAttributed() -> (NSAttributedString, String, CGFloat) {
        let nameFont = NSFont.systemFont(ofSize: 11 * fontScale, weight: .semibold)
        let stateFont = NSFont.systemFont(ofSize: 11 * fontScale, weight: .medium)
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5 * fontScale, weight: .regular)
        let modelFont = NSFont.monospacedSystemFont(ofSize: 10 * fontScale, weight: .regular)
        let subFont = NSFont.systemFont(ofSize: 10.5 * fontScale, weight: .regular)
        let dim = NSColor.white.withAlphaComponent(0.55)
        let body = NSColor.white.withAlphaComponent(0.92)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3 * fontScale
        paragraph.lineBreakMode = .byTruncatingTail

        func width(_ value: String, _ font: NSFont) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width
        }

        let text = NSMutableAttributedString()
        var key = ""
        var minWidth: CGFloat = 0

        if sessions.isEmpty {
            let none = NSAttributedString(string: "无活动会话", attributes: [
                .font: nameFont, .foregroundColor: dim,
            ])
            return (none, "empty", 0)
        }

        func appendBalance() {
            let dimLine = NSColor.white.withAlphaComponent(0.65)
            func append(_ line: String) {
                if text.length > 0 {
                    text.append(NSAttributedString(string: "\n", attributes: [.font: subFont]))
                }
                if sessions.count == 1,
                   let label = ["API 余额", "火山余额"].first(where: { line.hasPrefix($0) }) {
                    let value = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        text.append(NSAttributedString(string: label + "\t", attributes: [
                            .font: subFont, .foregroundColor: dimLine, .paragraphStyle: paragraph,
                        ]))
                        text.append(NSAttributedString(string: value, attributes: [
                            .font: subFont, .foregroundColor: dimLine, .paragraphStyle: paragraph,
                        ]))
                        return
                    }
                }
                text.append(NSAttributedString(string: line, attributes: [
                    .font: subFont, .foregroundColor: dimLine, .paragraphStyle: paragraph,
                ]))
            }
            if let balance = balanceLine {
                append(balance + " · 今日 " + formatTokens(stats.tokens) + " tokens")
            }
            if let volc = volcLine {
                append(volc)
            }
        }

        if sessions.count == 1, let session = sessions.first {
            let labelWidth = [
                ("上下文", stateFont), ("模型", stateFont),
                ("本轮已运行", pctFont), ("上轮用时", pctFont),
                ("API 余额", subFont), ("火山余额", subFont),
            ].map { width($0.0, $0.1) }.max() ?? 0
            let valueCol = ceil(labelWidth) + 10 * fontScale
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: valueCol, options: [:])]
            var percent = "--"
            var usage = ""
            if let used = usageBySession[session.id], used > 0 {
                percent = "\(Int((Double(used) / Double(max(contextWindow, 1)) * 100).rounded()))%"
                usage = " · \(formatTokens(used)) / \(formatTokens(contextWindow))"
            }
            text.append(NSAttributedString(string: "上下文\t", attributes: [
                .font: stateFont, .foregroundColor: body, .paragraphStyle: paragraph,
            ]))
            text.append(NSAttributedString(string: percent, attributes: [
                .font: pctFont, .foregroundColor: stateColor(session.state), .paragraphStyle: paragraph,
            ]))
            text.append(NSAttributedString(string: usage, attributes: [
                .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
            ]))
            if let model = modelBySession[session.id], !model.isEmpty {
                text.append(NSAttributedString(string: "\n模型\t", attributes: [
                    .font: stateFont, .foregroundColor: body, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: model, attributes: [
                    .font: modelFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
            }
            let turnLabel = turnElapsedLabel(for: session).map { ("本轮已运行", $0) }
                ?? turnDurationBySession[session.id].map { ("上轮用时", formatDuration($0)) }
            let turnText = turnLabel.map { $0.0 + " " + $0.1 }
            if let turnLabel {
                text.append(NSAttributedString(string: "\n" + turnLabel.0 + "\t", attributes: [
                    .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: turnLabel.1, attributes: [
                    .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
            }
            key = "1|\(percent)|\(usage)|\(modelBySession[session.id] ?? "")|\(turnText ?? "")"
        } else {
            struct Row {
                var name: String
                var state: String
                var model: String
                var time: String
                var percent: String
                var color: NSColor
            }
            var seen: [String: Int] = [:]
            var rows: [Row] = []
            for session in sessions.prefix(6) {
                let base = displayName(session)
                let count = (seen[base] ?? 0) + 1
                seen[base] = count
                let name = shortName(count > 1 ? "\(base) \(count)" : base, limit: 18)
                var percent = "—"
                if let used = usageBySession[session.id], used > 0 {
                    percent = "\(Int((Double(used) / Double(max(contextWindow, 1)) * 100).rounded()))%"
                }
                let model = shortName(modelBySession[session.id] ?? "—", limit: 18)
                let time = turnElapsedLabel(for: session)
                    ?? turnDurationBySession[session.id].map { formatClock($0) }
                    ?? "—"
                rows.append(Row(
                    name: name,
                    state: stateLabel(session.state),
                    model: model,
                    time: time,
                    percent: percent,
                    color: stateColor(session.state)
                ))
            }
            let showModel = rows.contains { $0.model != "—" }

            let gap: CGFloat = 16
            let nameW = rows.map { width($0.name, nameFont) }.max() ?? 0
            let stateW = rows.map { width($0.state, stateFont) }.max() ?? 0
            let modelW = rows.map { width($0.model, modelFont) }.max() ?? 0
            let timeW = rows.map { width($0.time, pctFont) }.max() ?? 0
            let pctW = rows.map { width($0.percent, pctFont) }.max() ?? 0
            let stateCol = ceil(nameW) + gap
            let modelCol = stateCol + ceil(stateW) + gap
            let timeCol = modelCol + (showModel ? ceil(modelW) + gap : 0)
            let totalW = timeCol + ceil(timeW) + gap + ceil(pctW)
            minWidth = totalW
            var stops = [NSTextTab(textAlignment: .left, location: stateCol, options: [:])]
            if showModel {
                stops.append(NSTextTab(textAlignment: .left, location: modelCol, options: [:]))
            }
            stops.append(NSTextTab(textAlignment: .left, location: timeCol, options: [:]))
            stops.append(NSTextTab(textAlignment: .right, location: totalW, options: [:]))
            paragraph.tabStops = stops

            for row in rows {
                text.append(NSAttributedString(string: row.name + "\t", attributes: [
                    .font: nameFont, .foregroundColor: body, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: row.state + "\t", attributes: [
                    .font: stateFont, .foregroundColor: row.color, .paragraphStyle: paragraph,
                ]))
                if showModel {
                    text.append(NSAttributedString(string: row.model + "\t", attributes: [
                        .font: modelFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                    ]))
                }
                text.append(NSAttributedString(string: row.time + "\t", attributes: [
                    .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: row.percent + "\n", attributes: [
                    .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
                key += "\(row.name)|\(row.state)|\(showModel ? row.model : "")|\(row.time)|\(row.percent);"
            }
            if sessions.count > 6 {
                text.append(NSAttributedString(string: "+\(sessions.count - 6) 个会话\n", attributes: [
                    .font: subFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
            }
            if text.string.hasSuffix("\n") {
                text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
            }
        }

        appendBalance()
        key += "|\(balanceLine ?? "")|\(volcLine ?? "")|\(stats.tokens)"
        return (text, key, minWidth)
    }

    private func apiCredentials() -> (token: String, host: String, base: URL)? {
        var token = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"] ?? ""
        var base = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? ""
        let settings = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        if let data = try? Data(contentsOf: settings),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = root["env"] as? [String: Any] {
            if let value = env["ANTHROPIC_AUTH_TOKEN"] as? String, !value.isEmpty { token = value }
            if let value = env["ANTHROPIC_BASE_URL"] as? String, !value.isEmpty { base = value }
        }
        guard !token.isEmpty, let url = URL(string: base), let host = url.host else { return nil }
        return (token, host, url)
    }

    private func refreshBalance(force: Bool = false) {
        let now = CACurrentMediaTime()
        let interval = force ? 2.0 : balanceRetryInterval
        guard now - lastBalanceRead > interval, !balanceFetching else { return }
        lastBalanceRead = now
        guard let cred = apiCredentials(), cred.host.contains("deepseek"),
              let url = URL(string: "https://" + cred.host + "/user/balance") else {
            balanceLine = "API 余额 --"
            return
        }
        if balanceLine == nil { balanceLine = "API 余额 查询中…" }
        balanceFetching = true
        var request = URLRequest(url: url)
        request.setValue("Bearer " + cred.token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var line = "API 余额 --"
            var value: Double?
            var symbol = ""
            var success = false
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if statusOK,
               let data,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let infos = root["balance_infos"] as? [[String: Any]],
               let info = infos.first,
               let total = info["total_balance"] as? String {
                let currency = info["currency"] as? String ?? ""
                symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
                value = Double(total)
                line = "API 余额 " + symbol + total
                success = true
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.balanceFetching = false
                if success || self.balanceLine == nil
                    || self.balanceLine == "API 余额 查询中…"
                    || self.balanceLine == "API 余额 --" {
                    self.balanceLine = line
                }
                self.balanceFailures = success ? 0 : min(self.balanceFailures + 1, 4)
                self.balanceRetryInterval = success
                    ? 60
                    : min(60 * pow(2, Double(self.balanceFailures)), 600)
                self.evaluateBalanceAlert(value, symbol: symbol)
                self.updateBadge()
            }
        }.resume()
    }

    private func evaluateBalanceAlert(_ value: Double?, symbol: String) {
        guard let value else { return }
        let low = value < balanceAlertThreshold
        if low && !balanceLow {
            triggerAlert(
                "API 余额偏低 " + symbol + String(format: "%.2f", value) + "，请及时充值",
                sound: soundBalance,
                repeats: 3
            )
        }
        balanceLow = low
    }

    private func loadVolcCredentials() -> Bool {
        if volcCredsLoaded { return volcAK != nil && volcSK != nil }
        let path = NSHomeDirectory() + "/.config/ark/env"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            if key == "VOLC_ACCESS_KEY_ID" { volcAK = value }
            if key == "VOLC_SECRET_ACCESS_KEY" { volcSK = value }
        }
        volcCredsLoaded = volcAK != nil && volcSK != nil
        return volcCredsLoaded
    }

    private static func sha256Hex(_ data: Data) -> String {
        hexString(Data(SHA256.hash(data: data)))
    }

    private static func hmacSHA256(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func volcBalanceRequest(ak: String, sk: String) -> URLRequest? {
        let host = "billing.volcengineapi.com"
        let query = "Action=QueryBalanceAcct&Version=2022-01-01"
        guard let url = URL(string: "https://" + host + "/?" + query) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = formatter.string(from: Date())
        let shortDate = String(xDate.prefix(8))
        let payloadHash = Self.sha256Hex(Data())
        let canonical = "GET\n/\n" + query + "\n"
            + "host:" + host + "\n"
            + "x-content-sha256:" + payloadHash + "\n"
            + "x-date:" + xDate + "\n\n"
            + "host;x-content-sha256;x-date\n"
            + payloadHash
        let scope = shortDate + "/cn-north-1/billing/request"
        let sts = "HMAC-SHA256\n" + xDate + "\n" + scope + "\n" + Self.sha256Hex(Data(canonical.utf8))
        let kDate = Self.hmacSHA256(Data(sk.utf8), shortDate)
        let kRegion = Self.hmacSHA256(kDate, "cn-north-1")
        let kService = Self.hmacSHA256(kRegion, "billing")
        let kSign = Self.hmacSHA256(kService, "request")
        let signature = Self.hexString(Self.hmacSHA256(kSign, sts))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(
            "HMAC-SHA256 Credential=" + ak + "/" + scope
                + ", SignedHeaders=host;x-content-sha256;x-date, Signature=" + signature,
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func fetchVolcBalance(completion: @escaping (String?) -> Void) {
        guard let ak = volcAK, let sk = volcSK, let request = volcBalanceRequest(ak: ak, sk: sk) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var line: String?
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if statusOK,
               let data,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = root["Result"] as? [String: Any],
               let balance = result["AvailableBalance"] as? String,
               let value = Double(balance) {
                let currency = result["Currency"] as? String ?? ""
                let symbol = currency == "CNY"
                    ? "¥"
                    : (currency == "USD" ? "$" : (currency.isEmpty ? "" : currency + " "))
                let sign = value < 0 ? "-" : ""
                line = "火山余额 " + sign + symbol + String(format: "%.2f", abs(value))
            } else {
                line = nil
            }
            DispatchQueue.main.async { completion(line) }
        }.resume()
    }

    private func refreshVolcBalance(force: Bool = false) {
        let now = CACurrentMediaTime()
        let interval = force ? 2.0 : volcRetryInterval
        guard now - lastVolcRead > interval, !volcFetching else { return }
        lastVolcRead = now
        guard loadVolcCredentials() else {
            volcLine = nil
            updateBadge()
            return
        }
        volcFetching = true
        fetchVolcBalance { [weak self] line in
            guard let self else { return }
            self.volcFetching = false
            self.volcLine = line ?? "火山余额 --"
            let success = line != nil
            self.volcFailures = success ? 0 : min(self.volcFailures + 1, 4)
            self.volcRetryInterval = success
                ? 60
                : min(60 * pow(2, Double(self.volcFailures)), 600)
            self.updateBadge()
        }
    }

    private func arkEnvValue(_ name: String) -> String? {
        let path = NSHomeDirectory() + "/.config/ark/env"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == name else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func fetchArkImageModels(completion: @escaping ([(id: String, status: String)]?) -> Void) {
        guard let key = arkEnvValue("ARK_API_KEY"),
              let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/models") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var result: [(id: String, status: String)]?
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if statusOK,
               let data,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = root["data"] as? [[String: Any]] {
                var models: [(id: String, status: String)] = []
                for item in items {
                    guard item["domain"] as? String == "ImageGeneration",
                          let id = item["id"] as? String else { continue }
                    models.append((id, item["status"] as? String ?? ""))
                }
                models.sort {
                    let leftPublished = $0.status == "Published"
                    let rightPublished = $1.status == "Published"
                    if leftPublished != rightPublished { return leftPublished }
                    return $0.id > $1.id
                }
                if !models.isEmpty { result = models }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parseArkImagePrices(_ text: String) -> [String: String] {
        var prices: [String: String] = [:]
        guard let decimals = try? NSRegularExpression(pattern: "\\d+\\.\\d+") else { return prices }
        var family: String?
        var block: [String] = []
        func flush() {
            guard let name = family else { return }
            defer {
                family = nil
                block = []
            }
            let body = block.joined(separator: "\n")
            guard !body.isEmpty else { return }
            if let range = body.range(of: "单图生成场景") {
                let tail = String(body[range.upperBound...])
                let nsTail = tail as NSString
                let matches = decimals.matches(in: tail, range: NSRange(location: 0, length: nsTail.length))
                let numbers = matches.prefix(2).compactMap { Range($0.range, in: tail).map { String(tail[$0]) } }
                if numbers.count == 2 {
                    prices[name] = "¥" + numbers[0] + "–" + numbers[1] + "/张"
                    return
                }
            }
            let nsBody = body as NSString
            let matches = decimals.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            if let last = matches.last, let range = Range(last.range, in: body) {
                prices[name] = "¥" + body[range] + "/张"
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.replacingOccurrences(of: "\u{200B}", with: "")
            if line.hasPrefix("doubao-seedream-") && !line.contains(" ") {
                flush()
                family = line
                continue
            }
            guard family != nil else { continue }
            if line.contains("计费公式") || line == "3D 生成模型" {
                flush()
                continue
            }
            block.append(line)
        }
        flush()
        return prices
    }

    private func fetchArkImagePrices(completion: @escaping ([String: String]?) -> Void) {
        guard let url = URL(string: "https://r.jina.ai/https://www.volcengine.com/docs/82379/1544106") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var result: [String: String]?
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if statusOK, let data, let text = String(data: data, encoding: .utf8) {
                let parsed = Self.parseArkImagePrices(text)
                if !parsed.isEmpty { result = parsed }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func refreshArkImageModels(force: Bool = false, notify: Bool = false) {
        let now = Date().timeIntervalSince1970
        let interval = force ? 2.0 : arkImageModelsInterval
        guard now - lastArkModelsRead > interval, !arkImageModelsFetching else { return }
        lastArkModelsRead = now
        arkImageModelsFetching = true
        fetchArkImageModels { [weak self] models in
            guard let self else { return }
            self.arkImageModelsFetching = false
            if let models {
                self.arkImageModels = models
                self.arkImageModelsAt = Date().timeIntervalSince1970
                self.arkImageModelsFailures = 0
                self.arkImageModelsInterval = 300
                if notify { self.triggerAlert("生图模型已更新（\(models.count) 个）") }
            } else {
                self.arkImageModelsFailures = min(self.arkImageModelsFailures + 1, 4)
                self.arkImageModelsInterval = min(300 * pow(2, Double(self.arkImageModelsFailures)), 3600)
                if notify { self.triggerAlert("生图模型刷新失败") }
            }
        }
        if force || now - arkImagePricesAt > 86400 {
            refreshArkImagePrices(force: true)
        }
    }

    private func refreshArkImagePrices(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        let interval = force ? 2.0 : 300.0
        guard !arkImagePricesFetching,
              now - lastArkPricesRead > interval,
              force || now - arkImagePricesAt > 86400
        else { return }
        lastArkPricesRead = now
        arkImagePricesFetching = true
        fetchArkImagePrices { [weak self] prices in
            guard let self else { return }
            self.arkImagePricesFetching = false
            if let prices {
                self.arkImagePrices = prices
                self.arkImagePricesAt = Date().timeIntervalSince1970
            }
        }
    }

    private static func arkPriceFamily(_ id: String) -> String {
        if let range = id.range(of: "-\\d{6,8}$", options: .regularExpression) {
            return String(id[..<range.lowerBound])
        }
        return id
    }

    private static func arkPrice(prices: [String: String], id: String) -> String {
        let family = arkPriceFamily(id)
        if let price = prices[family] { return price }
        if family == "doubao-seedream-5-0", let price = prices["doubao-seedream-5-0-lite"] {
            return price
        }
        return "价格以官网为准"
    }

    private func selectArkImageModel(_ id: String) {
        let path = NSHomeDirectory() + "/.config/ark/env"
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else {
            triggerAlert("未找到 ~/.config/ark/env")
            return
        }
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        var lines = text.components(separatedBy: "\n")
        var replaced = false
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExport = line.hasPrefix("export ")
            if hasExport { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "="),
                  String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines) == "ARK_IMAGE_MODEL"
            else { continue }
            lines[index] = (hasExport ? "export " : "") + "ARK_IMAGE_MODEL=\"" + id + "\""
            replaced = true
            break
        }
        if !replaced {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("ARK_IMAGE_MODEL=\"" + id + "\"")
        }
        text = lines.joined(separator: "\n")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try? manager.setAttributes(
                [.posixPermissions: permissions ?? NSNumber(value: 0o600)],
                ofItemAtPath: path
            )
            arkImageModel = id
            triggerAlert("生图模型：\(id)")
        } catch {
            triggerAlert("写入 ARK_IMAGE_MODEL 失败")
        }
    }

    private func clockString(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    @objc private func menuSelectArkImageModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
        else { return }
        selectArkImageModel(id)
    }

    @objc private func menuRefreshArkImageModels() {
        triggerAlert("正在刷新模型与价格…")
        refreshArkImageModels(force: true, notify: true)
    }

    @objc private func menuOpenArkPricing() {
        guard let url = URL(string: "https://www.volcengine.com/docs/82379/1544106") else { return }
        NSWorkspace.shared.open(url)
    }

    private func triggerAlert(
        _ message: String,
        sound: String = "",
        repeats: Int = 1,
        silent: Bool = false,
        duration: Double = 8
    ) {
        alertText = message
        alertUntil = CACurrentMediaTime() + duration
        updateBubble()
        guard !silent, soundEnabled, !doNotDisturb else { return }
        playSoundRepeated(sound.isEmpty ? soundWaiting : sound, times: repeats)
    }

    private func playSoundRepeated(_ name: String, times: Int = 3, interval: Double = 0.8) {
        for i in 0..<max(times, 1) {
            if i == 0 {
                playSound(name)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) { [weak self] in
                    self?.playSound(name)
                }
            }
        }
    }

    private func updateIdleOpacity() {
        guard panel != nil else { return }
        let busyStates: Set<String> = ["thinking", "bash", "search", "tool", "waiting", "start", "failed"]
        let busy = busyStates.contains(currentState)
            || CACurrentMediaTime() < doneBubbleUntil
            || CACurrentMediaTime() < overrideUntil
        let dim = !busy && !hovered && !draggingPet && !effortShown
        idleDimmed = dim
        let target: CGFloat = dim ? idleOpacity : 1.0
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = target
        }
    }

    private func updateBubble() {
        guard bubblePanel != nil, !petHidden else { return }
        guard showBubble, let content = bubbleContent() else {
            bubbleCache = ""
            if bubbleShown {
                bubbleShown = false
                bubblePanel.orderOut(nil)
                layoutOverlays()
            }
            return
        }
        let maxWidth: CGFloat = 300 * fontScale
        let maxLines = hovered ? 5 : 3
        var cache = "\(content.prefix ?? "")|\(content.time ?? "")|\(content.title)|\(content.detail ?? "")|\(Int(maxWidth))|\(maxLines)"
        if !content.rows.isEmpty {
            cache += "|" + content.rows.map { $0.name + $0.state + ($0.time ?? "") + ($0.pct ?? "") }.joined(separator: ";")
        }
        if bubbleShown && cache == bubbleCache { return }
        bubbleCache = cache

        let size = bubbleView.fit(content, maxWidth: maxWidth, maxLines: maxLines)
        bubbleSize = size
        bubbleView.show(content, frame: NSRect(origin: .zero, size: size), maxLines: maxLines)
        bubblePanel.setFrame(NSRect(origin: bubblePanel.frame.origin, size: size), display: true)
        if !bubbleShown {
            bubbleShown = true
            bubblePanel.orderFront(nil)
        }
        layoutOverlays()
    }

    private func updateBadge() {
        guard badgePanel != nil, !petHidden else { return }
        guard showBadge, hovered else {
            badgeCache = ""
            if badgeShown {
                badgeShown = false
                badgePanel.orderOut(nil)
                layoutOverlays()
            }
            return
        }

        let (attributed, key, minWidth) = badgeAttributed()
        if badgeShown && key == badgeCache { return }
        badgeCache = key

        let size = badgeView.fit(attributed, maxWidth: 380 * fontScale, minWidth: minWidth)
        badgeSize = size
        badgeView.show(attributed, frame: NSRect(origin: .zero, size: size))
        badgePanel.setFrame(NSRect(origin: badgePanel.frame.origin, size: size), display: true)
        if !badgeShown {
            badgeShown = true
            badgePanel.orderFront(nil)
        }
        layoutOverlays()
    }

    private func syncHoverFromPointer() {
        guard let panel, !petHidden, !draggingPet else { return }
        setHover(panel.frame.contains(NSEvent.mouseLocation))
    }

    private func setHover(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        if inside {
            refreshTranscript(force: true)
            lastUsageRead = 0
            refreshUsages()
            lastTokenScan = 0
            refreshTodayTokens()
            refreshTitles()
            refreshBalance(force: true)
            refreshVolcBalance(force: true)
        }
        updateBubble()
        updateBadge()
        updateIdleOpacity()
    }

    private func layoutOverlays() {
        guard panel != nil, bubblePanel != nil, badgePanel != nil else { return }
        let petFrame = panel.frame
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var bottom = petFrame.maxY + 5
        if bubbleShown {
            var x = petFrame.midX - bubbleSize.width / 2
            x = min(max(x, vf.minX + 6), vf.maxX - bubbleSize.width - 6)
            var y = bottom
            if y + bubbleSize.height > vf.maxY {
                y = max(vf.minY, vf.maxY - bubbleSize.height)
            }
            let origin = NSPoint(x: x, y: y)
            bubblePanel.setFrame(NSRect(origin: origin, size: bubbleSize), display: true)
            bottom = origin.y + bubbleSize.height + 6
        }
        if badgeShown {
            var x = petFrame.midX - badgeSize.width / 2
            x = min(max(x, vf.minX + 6), vf.maxX - badgeSize.width - 6)
            let y = bottom
            if y + badgeSize.height > vf.maxY {
                badgePanel.setFrame(
                    NSRect(origin: NSPoint(x: x, y: max(vf.minY, vf.maxY - badgeSize.height)),
                           size: badgeSize),
                    display: true
                )
            } else {
                badgePanel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: badgeSize), display: true)
                bottom = y + badgeSize.height + 6
            }
        }
        if effortShown {
            var x = petFrame.midX - effortSize.width / 2
            x = min(max(x, vf.minX + 6), vf.maxX - effortSize.width - 6)
            var y = petFrame.maxY + (effortOffsetY ?? 5)
            if y + effortSize.height > vf.maxY {
                y = max(vf.minY, vf.maxY - effortSize.height)
            }
            effortPanel.setFrame(
                NSRect(origin: NSPoint(x: x, y: y), size: effortSize),
                display: true
            )
        }
    }

    @objc private func gcSessions() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: runDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var live = 0
        var pidIDs = Set<String>()

        for url in entries where url.pathExtension == "pid" {
            let id = url.deletingPathExtension().lastPathComponent
            pidIDs.insert(id)
            // pet.pid is this process's own singleton lock, not a session
            guard id != "pet" else { continue }
            let raw = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = Int32(raw) ?? -1
            if pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) {
                live += 1
            } else {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".json"))
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".term"))
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".restartable"))
            }
        }

        for url in entries where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !pidIDs.contains(id) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mtime, Date().timeIntervalSince(mtime) > 7200 {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".term"))
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".restartable"))
            } else {
                live += 1
            }
        }

        for url in entries where url.pathExtension == "term" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !pidIDs.contains(id),
                  !fm.fileExists(atPath: runDir.appendingPathComponent(id + ".json").path)
            else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mtime, Date().timeIntervalSince(mtime) > 7200 {
                try? fm.removeItem(at: url)
            }
        }

        if live == 0 {
            if let since = emptySince {
                if Date().timeIntervalSince(since) >= 8 { NSApp.terminate(nil) }
            } else {
                emptySince = Date()
            }
        } else {
            emptySince = nil
        }
    }

    private func claimSingleton() -> Bool {
        let url = runDir.appendingPathComponent("pet.pid")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(), kill(pid, 0) == 0,
           processName(pid) == "CodexPet" {
            return false
        }
        try? String(getpid()).write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private func releaseSingleton() {
        guard claimedSingleton else { return }
        claimedSingleton = false
        try? FileManager.default.removeItem(at: runDir.appendingPathComponent("pet.pid"))
    }

    private func focusTerminal() {
        guard let id = primaryID else { return }
        focusTerminal(id: id)
    }

    private func terminalTarget(for id: String) -> (term: String, tty: String) {
        let url = runDir.appendingPathComponent(id + ".term")
        let raw = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return ("Apple_Terminal", raw)
    }

    private func focusTerminal(id: String) {
        let target = terminalTarget(for: id)
        activateTerminal(term: target.term, tty: target.tty)
    }

    private func activateTerminal(term: String, tty: String) {
        let ttyValid = tty.range(
            of: "^/dev/tty[a-z]*[0-9]+$",
            options: .regularExpression
        ) != nil
        let script: String
        if term == "iTerm.app" {
            script = ttyValid ? """
            tell application "iTerm2"
                activate
                set targetTTY to "\(tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is targetTTY then
                                set miniaturized of w to false
                                select t
                                select s
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """ : "tell application \"iTerm2\" to activate"
        } else {
            script = ttyValid ? """
            tell application "Terminal"
                activate
                set targetTTY to "\(tty)"
                repeat with w in windows
                    repeat with i from 1 to (count of tabs of w)
                        set t to tab i of w
                        if tty of t is targetTTY then
                            set miniaturized of w to false
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """ : "tell application \"Terminal\" to activate"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func sendTerminalText(
        _ text: String,
        term: String,
        tty: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard tty.range(of: "^/dev/tty[a-z]*[0-9]+$", options: .regularExpression) != nil else {
            completion(false)
            return
        }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if term == "iTerm.app" {
            script = """
            tell application "iTerm2"
                set targetTTY to "\(tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is targetTTY then
                                tell s to write text "\(escaped)"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        } else {
            script = """
            tell application "Terminal"
                set targetTTY to "\(tty)"
                repeat with w in windows
                    repeat with i from 1 to (count of tabs of w)
                        set t to tab i of w
                        if tty of t is targetTTY then
                            do script "\(escaped)" in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        }
        runAppleScript(script) { result in
            completion(result == "ok")
        }
    }

    private func runAppleScript(_ script: String, completion: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(finished.terminationStatus == 0 ? (output ?? "") : nil)
            }
        }
        do {
            try process.run()
        } catch {
            completion(nil)
        }
    }

    private func playNextCheer() {
        let pool = cheer.filter { $0 != index }
        guard let target = (pool.isEmpty ? cheer : pool).randomElement() else { return }
        applyMotion(index: target, loop: false)
        overrideUntil = CACurrentMediaTime() + motions[target].total + 0.1
    }

    private static let hotKeyCallback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        Unmanaged<PetApp>.fromOpaque(userData).takeUnretainedValue().togglePetVisible()
        return noErr
    }

    private func applyHotKeySetting() {
        if hotKeyEnabled {
            registerHotKey()
        } else {
            unregisterHotKey()
            if petHidden { togglePetVisible() }
        }
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        hotKeyFailed = false
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            PetApp.hotKeyCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        var status = installed
        if installed == noErr {
            let hotKeyID = EventHotKeyID(signature: OSType(0x43585054), id: 1)
            status = RegisterEventHotKey(
                UInt32(kVK_ANSI_P),
                UInt32(cmdKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
        }
        guard status != noErr else { return }
        // another app already owns the shortcut; leave the feature visibly off
        if let handler = hotKeyHandler {
            RemoveEventHandler(handler)
            hotKeyHandler = nil
        }
        hotKeyFailed = true
        hotKeyEnabled = false
        saveState()
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = hotKeyHandler {
            RemoveEventHandler(handler)
            hotKeyHandler = nil
        }
    }

    private func togglePetVisible() {
        petHidden.toggle()
        if petHidden {
            FileManager.default.createFile(atPath: hiddenFlagURL.path, contents: nil)
            hideStats()
            bubbleShown = false
            badgeShown = false
            bubbleCache = ""
            badgeCache = ""
            bubblePanel?.orderOut(nil)
            badgePanel?.orderOut(nil)
            effortShown = false
            effortOffsetY = nil
            effortPanel?.orderOut(nil)
            panel?.orderOut(nil)
            frameTimer?.invalidate()
            frameTimer = nil
        } else {
            try? FileManager.default.removeItem(at: hiddenFlagURL)
            try? FileManager.default.removeItem(at: showFlagURL)
            try? FileManager.default.removeItem(at: hideFlagURL)
            scheduleFrame(after: 0.01)
            panel?.orderFrontRegardless()
            refreshTitles()
            updateBubble()
            updateBadge()
            updateIdleOpacity()
        }
    }

    private func dragRide(_ dir: Int) {
        draggingPet = true
        updateIdleOpacity()
        setMotion(dir > 0 ? "running-right" : "running-left", loop: true)
    }

    private func endDragRide() {
        draggingPet = false
        followStateMotion()
        updateIdleOpacity()
    }

    private func setScale(_ value: CGFloat) {
        savedCenterX = panel.frame.midX
        savedBottomY = panel.frame.minY
        scale = min(max(value, 0.15), 1.5)
        applyMotion(index: index, loop: loop)
        saveState()
    }

    private func setOnTop(_ value: Bool) {
        onTop = value
        let level: NSWindow.Level = value ? .floating : .normal
        panel.level = level
        bubblePanel?.level = level
        badgePanel?.level = level
        statsPanel?.level = level
        effortPanel?.level = level
        saveState()
    }

    private func saveState() {
        guard panel != nil else { return }
        let state = PetState(
            centerX: Double(panel.frame.midX),
            bottomY: Double(panel.frame.minY),
            scale: Double(scale),
            onTop: onTop,
            showBubble: showBubble,
            locked: lockedPet,
            speed: speed,
            showBadge: showBadge,
            sound: soundEnabled,
            currentOnly: currentOnly,
            soundDone: soundDone,
            soundFailed: soundFailed,
            soundWaiting: soundWaiting,
            soundBalance: soundBalance,
            soundTool: soundTool,
            soundVolume: soundVolume,
            motionMap: motionMap.isEmpty ? nil : motionMap,
            dnd: doNotDisturb,
            fontScale: Double(fontScale),
            hotkey: hotKeyEnabled,
            idleOpacity: Double(idleOpacity),
            pinnedSession: pinnedSessionID,
            effortBySession: effortBySession.isEmpty ? nil : effortBySession,
            mutedSessions: mutedSessions.isEmpty ? nil : mutedSessions.sorted(),
            toolTimeout: toolTimeoutOverride
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func loadReviewOff() {
        guard let text = try? String(contentsOf: reviewOffURL, encoding: .utf8) else {
            reviewOffIDs = []
            return
        }
        reviewOffIDs = Set(text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    private func saveReviewOff() {
        let text = reviewOffIDs.sorted().joined(separator: "\n")
            + (reviewOffIDs.isEmpty ? "" : "\n")
        try? text.write(to: reviewOffURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: reviewOffURL.path)
    }

    private func showMenu(_ event: NSEvent) {
        hideEffortCard()
        let menu = NSMenu()

        let idleItem = NSMenuItem(
            title: "回到待机",
            action: #selector(menuIdle),
            keyEquivalent: ""
        )
        idleItem.target = self
        menu.addItem(idleItem)

        let hideItem = NSMenuItem(
            title: "隐藏宠物",
            action: #selector(menuHidePet),
            keyEquivalent: hotKeyEnabled ? "p" : ""
        )
        hideItem.keyEquivalentModifierMask = [.command, .option]
        hideItem.toolTip = "隐藏后用 ⌥⌘P 或 petctl.sh show 恢复"
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())

        let animationItem = NSMenuItem(title: "动画", action: nil, keyEquivalent: "")
        let animationMenu = NSMenu()
        for (i, motion) in motions.enumerated() {
            let item = NSMenuItem(
                title: motion.name,
                action: #selector(menuMotion(_:)),
                keyEquivalent: ""
            )
            item.tag = i
            item.target = self
            if i == index { item.state = .on }
            animationMenu.addItem(item)
        }
        animationMenu.addItem(.separator())

        let stateItem = NSMenuItem(title: "状态动画", action: nil, keyEquivalent: "")
        let stateMenu = NSMenu()
        for group in stateMotionGroups {
            let entry = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            let currentKey = motionKey(for: group.rep)
            for (i, motion) in motions.enumerated() {
                let item = NSMenuItem(
                    title: motion.name,
                    action: #selector(menuStateMotion(_:)),
                    keyEquivalent: ""
                )
                item.tag = i
                item.representedObject = group.key
                item.target = self
                if motion.key == currentKey { item.state = .on }
                choices.addItem(item)
            }
            entry.submenu = choices
            stateMenu.addItem(entry)
        }
        stateMenu.addItem(.separator())
        let resetStates = NSMenuItem(
            title: "恢复默认",
            action: #selector(menuResetStateMotion),
            keyEquivalent: ""
        )
        resetStates.target = self
        stateMenu.addItem(resetStates)
        stateItem.submenu = stateMenu
        animationMenu.addItem(stateItem)
        animationItem.submenu = animationMenu
        menu.addItem(animationItem)

        let sessionsItem = NSMenuItem(title: "会话", action: nil, keyEquivalent: "")
        let sessionsMenu = NSMenu()
        menuSessionIDs = sessions.map { $0.id }
        let newSessionItem = NSMenuItem(
            title: "新建会话…",
            action: #selector(menuNewSession),
            keyEquivalent: ""
        )
        newSessionItem.target = self
        sessionsMenu.addItem(newSessionItem)
        let recentItem = NSMenuItem(title: "最近对话", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recent = loadRecentConversations(limit: 8)
        recentConversationIDs = recent.map { $0.id }
        recentConversationProjects = recent.map { $0.project }
        if recent.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无最近对话", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for (i, conversation) in recent.enumerated() {
                let item = NSMenuItem(
                    title: recentConversationTitle(conversation),
                    action: #selector(menuOpenRecentConversation(_:)),
                    keyEquivalent: ""
                )
                item.tag = i
                item.target = self
                item.toolTip = conversation.prompt + "\n" + conversation.project
                    + "\n" + conversation.id
                recentMenu.addItem(item)
            }
        }
        recentItem.submenu = recentMenu
        sessionsMenu.addItem(recentItem)
        let timeoutItem = NSMenuItem(title: "工具超时阈值", action: nil, keyEquivalent: "")
        let timeoutMenu = NSMenu()
        let timeoutPresets = [0, 5, 10, 15, 30, 60]
        if !timeoutPresets.contains(where: { abs(toolTimeout - Double($0) * 60) < 0.5 }) {
            let custom = NSMenuItem(
                title: "自定义（\(String(format: "%g", toolTimeout / 60)) 分钟）",
                action: nil,
                keyEquivalent: ""
            )
            custom.state = .on
            custom.isEnabled = false
            timeoutMenu.addItem(custom)
            timeoutMenu.addItem(.separator())
        }
        for minutes in timeoutPresets {
            let item = NSMenuItem(
                title: minutes == 0 ? "关闭" : "\(minutes) 分钟",
                action: #selector(menuToolTimeout(_:)),
                keyEquivalent: ""
            )
            item.tag = minutes
            item.target = self
            if abs(toolTimeout - Double(minutes) * 60) < 0.5 { item.state = .on }
            timeoutMenu.addItem(item)
        }
        timeoutItem.submenu = timeoutMenu
        sessionsMenu.addItem(timeoutItem)
        sessionsMenu.addItem(.separator())
        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "无活跃会话", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            sessionsMenu.addItem(emptyItem)
        } else {
            let recentModels = collectRecentModels()
            let psSnapshot = processEntries()
            for (i, session) in sessions.enumerated() {
                let item = NSMenuItem(
                    title: displayName(session) + " · " + stateLabel(session.state),
                    action: nil,
                    keyEquivalent: ""
                )
                item.tag = i
                if session.id == primaryID { item.state = .on }
                let sub = NSMenu()
                let contextItem = NSMenuItem(
                    title: sessionContextLabel(session),
                    action: nil,
                    keyEquivalent: ""
                )
                contextItem.isEnabled = false
                sub.addItem(contextItem)
                let modelItem = NSMenuItem(
                    title: "模型 " + (modelBySession[session.id] ?? "--"),
                    action: nil,
                    keyEquivalent: ""
                )
                modelItem.isEnabled = false
                sub.addItem(modelItem)
                let effortRow = NSMenuItem(
                    title: "思考力度 " + effortLabel(effortLevel(for: session, entries: psSnapshot)),
                    action: nil,
                    keyEquivalent: ""
                )
                effortRow.isEnabled = false
                sub.addItem(effortRow)
                let effortAction = NSMenuItem(
                    title: "调整思考力度…",
                    action: #selector(menuShowEffort(_:)),
                    keyEquivalent: ""
                )
                effortAction.tag = i
                effortAction.target = self
                effortAction.isEnabled = session.resumeID != nil
                sub.addItem(effortAction)
                if let turnText = sessionTurnLabel(session) {
                    let turnItem = NSMenuItem(title: turnText, action: nil, keyEquivalent: "")
                    turnItem.isEnabled = false
                    sub.addItem(turnItem)
                }
                sub.addItem(.separator())
                let focus = NSMenuItem(
                    title: "聚焦终端",
                    action: #selector(menuFocusSession(_:)),
                    keyEquivalent: ""
                )
                focus.tag = i
                focus.target = self
                focus.isEnabled = session.tty != nil
                sub.addItem(focus)
                let openFolder = NSMenuItem(
                    title: "在 Finder 中打开目录",
                    action: #selector(menuOpenSessionFolder(_:)),
                    keyEquivalent: ""
                )
                openFolder.tag = i
                openFolder.target = self
                openFolder.isEnabled = !session.cwd.isEmpty
                sub.addItem(openFolder)
                let copyID = NSMenuItem(
                    title: "复制会话 UUID",
                    action: #selector(menuCopySessionID(_:)),
                    keyEquivalent: ""
                )
                copyID.tag = i
                copyID.target = self
                copyID.isEnabled = session.resumeID != nil
                sub.addItem(copyID)
                let copyCommand = NSMenuItem(
                    title: "复制恢复命令",
                    action: nil,
                    keyEquivalent: ""
                )
                copyCommand.isEnabled = !session.cwd.isEmpty && session.resumeID != nil
                let copyMenu = NSMenu()
                func addCopyModel(_ model: String?) {
                    let item = NSMenuItem(
                        title: model ?? "默认模型",
                        action: #selector(menuCopyResumeCommand(_:)),
                        keyEquivalent: ""
                    )
                    item.tag = i
                    item.representedObject = model
                    item.target = self
                    copyMenu.addItem(item)
                }
                addCopyModel(nil)
                recentModels.forEach { addCopyModel($0) }
                let copyOfficial = providerModels.filter { !recentModels.contains($0) }
                if !copyOfficial.isEmpty {
                    copyMenu.addItem(.separator())
                    let header = NSMenuItem(title: "官方模型", action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    copyMenu.addItem(header)
                    copyOfficial.forEach { addCopyModel($0) }
                }
                copyCommand.submenu = copyMenu
                sub.addItem(copyCommand)
                let pin = NSMenuItem(
                    title: "置顶会话",
                    action: #selector(menuTogglePinSession(_:)),
                    keyEquivalent: ""
                )
                pin.tag = i
                pin.target = self
                pin.isEnabled = session.resumeID != nil
                if let rid = session.resumeID, rid == pinnedSessionID { pin.state = .on }
                sub.addItem(pin)
                let mute = NSMenuItem(
                    title: "静音提醒",
                    action: #selector(menuToggleSessionMute(_:)),
                    keyEquivalent: ""
                )
                mute.tag = i
                mute.target = self
                mute.isEnabled = session.resumeID != nil
                mute.toolTip = "只关闭该会话的提示音，右上角红点照常"
                if sessionIsMuted(session) { mute.state = .on }
                sub.addItem(mute)
                sub.addItem(.separator())
                let resume = NSMenuItem(
                    title: "默认模型",
                    action: #selector(menuResumeSession(_:)),
                    keyEquivalent: ""
                )
                resume.tag = i
                resume.target = self
                resume.isEnabled = !session.cwd.isEmpty && session.resumeID != nil
                sub.addItem(resume)
                func addResumeModel(_ model: String) {
                    let modelItem = NSMenuItem(
                        title: model,
                        action: #selector(menuResumeSession(_:)),
                        keyEquivalent: ""
                    )
                    modelItem.tag = i
                    modelItem.representedObject = model
                    modelItem.target = self
                    modelItem.isEnabled = !session.cwd.isEmpty && session.resumeID != nil
                    sub.addItem(modelItem)
                }
                recentModels.forEach(addResumeModel)
                let officialModels = providerModels.filter { !recentModels.contains($0) }
                if !officialModels.isEmpty {
                    sub.addItem(.separator())
                    let officialHeader = NSMenuItem(title: "官方模型", action: nil, keyEquivalent: "")
                    officialHeader.isEnabled = false
                    sub.addItem(officialHeader)
                    officialModels.forEach(addResumeModel)
                }
                sub.addItem(.separator())
                let reviewItem = NSMenuItem(
                    title: "个人审查",
                    action: #selector(menuToggleSessionReview(_:)),
                    keyEquivalent: ""
                )
                reviewItem.tag = i
                reviewItem.target = self
                reviewItem.isEnabled = session.resumeID != nil
                if let rid = session.resumeID, reviewOffIDs.contains(rid) {
                    reviewItem.state = .off
                } else {
                    reviewItem.state = .on
                }
                sub.addItem(reviewItem)
                item.submenu = sub
                sessionsMenu.addItem(item)
            }
        }
        sessionsItem.submenu = sessionsMenu
        menu.addItem(sessionsItem)

        let arkItem = NSMenuItem(title: "生图模型", action: nil, keyEquivalent: "")
        let arkMenu = NSMenu()
        refreshArkImageModels()
        refreshArkImagePrices()
        let selectedModel = arkEnvValue("ARK_IMAGE_MODEL")
        arkImageModel = selectedModel
        if arkImageModels.isEmpty {
            let status = NSMenuItem(
                title: arkImageModelsFailures > 0 ? "获取失败，稍后自动重试" : "正在获取…",
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            arkMenu.addItem(status)
        }
        for model in arkImageModels {
            let price = Self.arkPrice(prices: arkImagePrices, id: model.id)
            let suffix = model.status == "Retiring" ? "（下线中）" : ""
            let item = NSMenuItem(
                title: model.id + " · " + price + suffix,
                action: #selector(menuSelectArkImageModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = model.id
            item.target = self
            if model.id == selectedModel { item.state = .on }
            arkMenu.addItem(item)
        }
        arkMenu.addItem(.separator())
        let stampItem = NSMenuItem(
            title: arkImageModelsAt > 0 ? "模型更新于 " + clockString(arkImageModelsAt) : "尚未获取模型列表",
            action: nil,
            keyEquivalent: ""
        )
        stampItem.isEnabled = false
        arkMenu.addItem(stampItem)
        let refreshArk = NSMenuItem(
            title: "刷新模型与价格",
            action: #selector(menuRefreshArkImageModels),
            keyEquivalent: ""
        )
        refreshArk.target = self
        arkMenu.addItem(refreshArk)
        let pricingItem = NSMenuItem(
            title: "查看官方定价 ↗",
            action: #selector(menuOpenArkPricing),
            keyEquivalent: ""
        )
        pricingItem.target = self
        arkMenu.addItem(pricingItem)
        arkItem.submenu = arkMenu
        menu.addItem(arkItem)

        let appearanceMenu = NSMenu()
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        let soundMenu = NSMenu()
        let soundItem = NSMenuItem(title: "声音", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let statsMenu = NSMenu()
        let statsMenuItem = NSMenuItem(title: "统计", action: nil, keyEquivalent: "")
        statsMenuItem.submenu = statsMenu
        menu.addItem(statsMenuItem)

        let windowMenu = NSMenu()
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for value in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] {
            let item = NSMenuItem(
                title: String(format: "%.0f%%", value * 100),
                action: #selector(menuScale(_:)),
                keyEquivalent: ""
            )
            item.tag = Int(value * 100)
            item.target = self
            if abs(scale - CGFloat(value)) < 0.01 { item.state = .on }
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        appearanceMenu.addItem(sizeItem)

        let fontItem = NSMenuItem(title: "字号", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        let fontChoices: [(Double, String)] = [
            (0.85, "小"), (1.0, "标准"), (1.15, "大"), (1.3, "特大"),
        ]
        for (value, label) in fontChoices {
            let item = NSMenuItem(
                title: label,
                action: #selector(menuFontScale(_:)),
                keyEquivalent: ""
            )
            item.tag = Int((value * 100).rounded())
            item.target = self
            if abs(fontScale - CGFloat(value)) < 0.01 { item.state = .on }
            fontMenu.addItem(item)
        }
        fontItem.submenu = fontMenu
        appearanceMenu.addItem(fontItem)

        let speedItem = NSMenuItem(title: "动画速度", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        let speedChoices: [(Double, String)] = [
            (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1×"),
            (1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×"),
        ]
        for (value, label) in speedChoices {
            let item = NSMenuItem(
                title: label,
                action: #selector(menuSpeed(_:)),
                keyEquivalent: ""
            )
            item.tag = Int(value * 100)
            item.target = self
            if abs(speed - value) < 0.01 { item.state = .on }
            speedMenu.addItem(item)
        }
        speedItem.submenu = speedMenu
        appearanceMenu.addItem(speedItem)

        let opacityItem = NSMenuItem(title: "空闲透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [0.25, 0.4, 0.6, 0.75, 0.9, 1.0] {
            let item = NSMenuItem(
                title: String(format: "%.0f%%", value * 100),
                action: #selector(menuIdleOpacity(_:)),
                keyEquivalent: ""
            )
            item.tag = Int((value * 100).rounded())
            item.target = self
            if abs(idleOpacity - CGFloat(value)) < 0.01 { item.state = .on }
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        appearanceMenu.addItem(opacityItem)
        appearanceMenu.addItem(.separator())

        let bubbleItem = NSMenuItem(
            title: "显示气泡",
            action: #selector(menuBubble),
            keyEquivalent: ""
        )
        bubbleItem.target = self
        bubbleItem.state = showBubble ? .on : .off
        appearanceMenu.addItem(bubbleItem)

        let badgeItem = NSMenuItem(
            title: "显示悬停徽章",
            action: #selector(menuBadge),
            keyEquivalent: ""
        )
        badgeItem.target = self
        badgeItem.state = showBadge ? .on : .off
        appearanceMenu.addItem(badgeItem)

        let soundToggle = NSMenuItem(
            title: "启用提示音",
            action: #selector(menuSound),
            keyEquivalent: ""
        )
        soundToggle.target = self
        soundToggle.state = soundEnabled ? .on : .off
        soundMenu.addItem(soundToggle)
        soundMenu.addItem(.separator())
        let soundChoices: [(String, Selector, String)] = [
            ("完成", #selector(menuSoundDone(_:)), soundDone),
            ("失败", #selector(menuSoundFailed(_:)), soundFailed),
            ("等待回复", #selector(menuSoundWaiting(_:)), soundWaiting),
            ("余额不足", #selector(menuSoundBalance(_:)), soundBalance),
            ("工具超时", #selector(menuSoundTool(_:)), soundTool),
        ]
        for (title, action, selected) in soundChoices {
            let targetItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for (i, sound) in alertSounds.enumerated() {
                let item = NSMenuItem(
                    title: sound.label,
                    action: action,
                    keyEquivalent: ""
                )
                item.tag = i
                item.target = self
                if sound.id == selected { item.state = .on }
                choices.addItem(item)
            }
            targetItem.submenu = choices
            soundMenu.addItem(targetItem)
        }
        soundMenu.addItem(.separator())
        let volumeItem = NSMenuItem(title: "音量", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        var volumeChoices: [Double] = Array(stride(from: 0.1, through: 1.0, by: 0.1))
        volumeChoices += [1.2, 1.5, 2.0]
        for value in volumeChoices {
            let item = NSMenuItem(
                title: String(format: "%.0f%%", value * 100),
                action: #selector(menuSoundVolume(_:)),
                keyEquivalent: ""
            )
            item.tag = Int((value * 100).rounded())
            item.target = self
            if abs(soundVolume - value) < 0.01 { item.state = .on }
            volumeMenu.addItem(item)
        }
        volumeItem.submenu = volumeMenu
        soundMenu.addItem(volumeItem)
        soundMenu.addItem(.separator())
        let dndItem = NSMenuItem(
            title: "勿扰模式（静音提醒）",
            action: #selector(menuDND),
            keyEquivalent: ""
        )
        dndItem.target = self
        dndItem.state = doNotDisturb ? .on : .off
        soundMenu.addItem(dndItem)

        let currentItem = NSMenuItem(
            title: "只显示当前会话",
            action: #selector(menuCurrentOnly),
            keyEquivalent: ""
        )
        currentItem.target = self
        currentItem.state = currentOnly ? .on : .off
        appearanceMenu.addItem(currentItem)

        let lockItem = NSMenuItem(
            title: "锁定位置",
            action: #selector(menuLock),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.state = lockedPet ? .on : .off
        windowMenu.addItem(lockItem)

        let topItem = NSMenuItem(
            title: "始终置顶",
            action: #selector(menuTop),
            keyEquivalent: ""
        )
        topItem.target = self
        topItem.state = onTop ? .on : .off
        windowMenu.addItem(topItem)

        let hotKeyItem = NSMenuItem(
            title: hotKeyFailed ? "⌥⌘P 显示/隐藏宠物（注册失败）" : "⌥⌘P 显示/隐藏宠物",
            action: #selector(menuHotKey),
            keyEquivalent: ""
        )
        hotKeyItem.target = self
        hotKeyItem.state = hotKeyEnabled ? .on : .off
        windowMenu.addItem(hotKeyItem)

        windowMenu.addItem(.separator())
        let resetItem = NSMenuItem(
            title: "重置位置",
            action: #selector(menuResetPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        windowMenu.addItem(resetItem)

        let reloadItem = NSMenuItem(
            title: "重新载入素材",
            action: #selector(menuReloadAssets),
            keyEquivalent: ""
        )
        reloadItem.target = self
        windowMenu.addItem(reloadItem)

        let dataItem = NSMenuItem(
            title: "打开数据目录",
            action: #selector(menuOpenDataDir),
            keyEquivalent: ""
        )
        dataItem.target = self
        windowMenu.addItem(dataItem)

        let statsItem = NSMenuItem(
            title: "今日统计",
            action: #selector(menuStats),
            keyEquivalent: ""
        )
        statsItem.target = self
        statsMenu.addItem(statsItem)

        let historyItem = NSMenuItem(
            title: "近 7 天统计",
            action: #selector(menuStatsHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        statsMenu.addItem(historyItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    private func sessionContextLabel(_ session: Session) -> String {
        guard let used = usageBySession[session.id], used > 0 else { return "上下文 --" }
        let percent = Int((Double(used) / Double(max(contextWindow, 1)) * 100).rounded())
        return "上下文 \(percent)% · \(formatTokens(used)) / \(formatTokens(contextWindow))"
    }

    private func turnElapsedLabel(for session: Session) -> String? {
        let activeStates: Set<String> = ["thinking", "bash", "search", "tool", "waiting", "start"]
        guard activeStates.contains(session.state),
              let start = session.turnStart ?? turnStartBySession[session.id] else { return nil }
        let elapsed = Date().timeIntervalSince1970 - start
        guard elapsed >= 0 else { return nil }
        return formatClock(elapsed)
    }

    private func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func sessionTurnLabel(_ session: Session) -> String? {
        let activeStates: Set<String> = ["thinking", "bash", "search", "tool", "waiting", "start"]
        let now = Date().timeIntervalSince1970
        if activeStates.contains(session.state),
           let start = session.turnStart ?? turnStartBySession[session.id], now >= start {
            return "本轮已运行 " + formatDuration(now - start)
        }
        if let duration = turnDurationBySession[session.id] {
            return "上轮用时 " + formatDuration(duration)
        }
        return nil
    }

    @objc private func menuIdle() {
        overrideUntil = 0
        applyMotion(index: idleIndex, loop: true)
    }

    @objc private func menuHidePet() {
        togglePetVisible()
    }

    @objc private func menuMotion(_ sender: NSMenuItem) {
        overrideUntil = 0
        applyMotion(index: sender.tag, loop: true)
    }

    @objc private func menuStateMotion(_ sender: NSMenuItem) {
        guard motions.indices.contains(sender.tag),
              let group = sender.representedObject as? String else { return }
        let key = motions[sender.tag].key
        for part in group.split(separator: ",") {
            motionMap[String(part)] = key
        }
        overrideUntil = 0
        saveState()
        followStateMotion()
    }

    @objc private func menuResetStateMotion() {
        motionMap.removeAll()
        overrideUntil = 0
        saveState()
        followStateMotion()
    }

    @objc private func menuScale(_ sender: NSMenuItem) {
        setScale(CGFloat(sender.tag) / 100.0)
    }

    @objc private func menuFontScale(_ sender: NSMenuItem) {
        fontScale = min(max(CGFloat(sender.tag) / 100.0, 0.85), 1.3)
        BubbleView.scale = fontScale
        bubbleCache = ""
        badgeCache = ""
        updateBubble()
        updateBadge()
        if statsShown { showStats(mode: statsMode) }
        saveState()
    }

    @objc private func menuSpeed(_ sender: NSMenuItem) {
        speed = Double(sender.tag) / 100.0
        saveState()
    }

    @objc private func menuIdleOpacity(_ sender: NSMenuItem) {
        idleOpacity = min(max(CGFloat(sender.tag) / 100.0, 0.1), 1.0)
        updateIdleOpacity()
        saveState()
    }

    @objc private func menuBubble() {
        showBubble.toggle()
        updateBubble()
        saveState()
    }

    @objc private func menuLock() {
        lockedPet.toggle()
        petView.locked = lockedPet
        saveState()
    }

    @objc private func menuBadge() {
        showBadge.toggle()
        updateBadge()
        saveState()
    }

    @objc private func menuDND() {
        doNotDisturb.toggle()
        saveState()
    }

    @objc private func menuHotKey() {
        hotKeyEnabled.toggle()
        applyHotKeySetting()
        saveState()
    }

    @objc private func menuSound() {
        soundEnabled.toggle()
        if soundEnabled { playSound(soundDone) }
        saveState()
    }

    @objc private func menuSoundDone(_ sender: NSMenuItem) {
        guard alertSounds.indices.contains(sender.tag) else { return }
        soundDone = alertSounds[sender.tag].id
        playSound(soundDone)
        saveState()
    }

    @objc private func menuSoundFailed(_ sender: NSMenuItem) {
        guard alertSounds.indices.contains(sender.tag) else { return }
        soundFailed = alertSounds[sender.tag].id
        playSound(soundFailed)
        saveState()
    }

    @objc private func menuSoundWaiting(_ sender: NSMenuItem) {
        guard alertSounds.indices.contains(sender.tag) else { return }
        soundWaiting = alertSounds[sender.tag].id
        playSound(soundWaiting)
        saveState()
    }

    @objc private func menuSoundBalance(_ sender: NSMenuItem) {
        guard alertSounds.indices.contains(sender.tag) else { return }
        soundBalance = alertSounds[sender.tag].id
        playSoundRepeated(soundBalance)
        saveState()
    }

    @objc private func menuSoundTool(_ sender: NSMenuItem) {
        guard alertSounds.indices.contains(sender.tag) else { return }
        soundTool = alertSounds[sender.tag].id
        playSound(soundTool)
        saveState()
    }

    @objc private func menuToolTimeout(_ sender: NSMenuItem) {
        let minutes = max(0, sender.tag)
        toolTimeoutOverride = Double(minutes)
        toolTimeout = Double(minutes) * 60
        toolRunStart.removeAll()
        toolRunAlerted.removeAll()
        triggerAlert(
            minutes == 0 ? "工具超时提醒已关闭" : "工具超时提醒：\(minutes) 分钟",
            silent: true,
            duration: 2.5
        )
        saveState()
    }

    @objc private func menuSoundVolume(_ sender: NSMenuItem) {
        soundVolume = min(max(Double(sender.tag) / 100.0, 0), 3)
        playSound(soundDone)
        saveState()
    }

    private func soundFileURL(_ name: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Sounds/\(name)"),
            home.appendingPathComponent("Library/Sounds/\(name).wav"),
            home.appendingPathComponent("Library/Sounds/\(name).aiff"),
            URL(fileURLWithPath: "/Library/Sounds/\(name).aiff"),
            URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func boostedSoundURL(_ url: URL, gain: Double) -> URL? {
        let fm = FileManager.default
        let cacheDir = petRoot.appendingPathComponent("cache")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let out = cacheDir.appendingPathComponent(
            "\(base)-\(Int((gain * 100).rounded())).caf"
        )
        if fm.fileExists(atPath: out.path) { return out }
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let g = Float(gain)
        for ch in 0..<Int(file.processingFormat.channelCount) {
            let samples = channels[ch]
            for i in 0..<frames {
                samples[i] = min(max(samples[i] * g, -1), 1)
            }
        }
        guard let writer = try? AVAudioFile(
            forWriting: out,
            settings: file.processingFormat.settings
        ) else { return nil }
        do {
            try writer.write(from: buffer)
        } catch {
            return nil
        }
        return out
    }

    private func playSound(_ name: String) {
        guard let base = soundFileURL(name) else { return }
        var url = base
        if soundVolume > 1.001 {
            guard let boosted = boostedSoundURL(base, gain: soundVolume) else { return }
            url = boosted
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = Float(min(soundVolume, 1.0))
        sound.play()
    }

    @objc private func menuCurrentOnly() {
        currentOnly.toggle()
        refreshFrontTTY()
        pollSessions()
        saveState()
    }

    @objc private func menuOpenDataDir() {
        NSWorkspace.shared.open(petRoot)
    }

    @objc private func menuFocusSession(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag) else { return }
        focusTerminal(id: menuSessionIDs[sender.tag])
    }

    @objc private func menuOpenSessionFolder(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              !session.cwd.isEmpty
        else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
    }

    @objc private func menuToggleSessionMute(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let rid = session.resumeID
        else { return }
        if mutedSessions.contains(rid) {
            mutedSessions.remove(rid)
            triggerAlert("已取消静音 " + displayName(session), silent: true, duration: 2.5)
        } else {
            mutedSessions.insert(rid)
            triggerAlert("已静音 " + displayName(session) + " 的提醒", silent: true, duration: 2.5)
        }
        saveState()
    }

    @objc private func menuToggleSessionReview(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let rid = session.resumeID
        else { return }
        let turningOff: Bool
        if reviewOffIDs.contains(rid) {
            reviewOffIDs.remove(rid)
            turningOff = false
        } else {
            reviewOffIDs.insert(rid)
            turningOff = true
        }
        saveReviewOff()
        let reason = turningOff
            ? "已关闭该会话的个人审查（仅影响该会话），需要重启该会话才能生效。"
            : "已恢复该会话的个人审查（仅影响该会话），需要重启该会话才能生效。"
        let restarted = restartSession(
            session,
            effort: explicitEffort(for: session),
            model: modelBySession[session.id],
            skip: turningOff,
            reason: reason
        )
        if restarted {
            triggerAlert(turningOff ? "已关闭个人审查，正在重启…" : "已恢复个人审查，正在重启…",
                         silent: true, duration: 4)
        } else {
            triggerAlert("个人审查已切换；仅影响该会话，下次恢复时生效", silent: true, duration: 3.5)
        }
    }

    @objc private func menuShowEffort(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] })
        else { return }
        showEffortCard(for: session)
    }

    private func showEffortCard(for session: Session) {
        guard let rid = session.resumeID, effortPanel != nil, !petHidden else { return }
        hideEffortCard()
        effortView.onCommit = { [weak self] index in
            guard let self else { return }
            let index = max(0, min(Int(index), effortLevels.count - 1))
            self.hideEffortCard()
            self.applyEffort(effortLevels[index].id, petID: session.id, resumeID: rid)
        }
        effortView.onCancel = { [weak self] in self?.hideEffortCard() }
        effortView.configure(name: displayName(session), level: effortLevel(for: session))
        effortSize = effortView.cardSize()
        var bottom = panel.frame.maxY + 5
        if bubbleShown { bottom = max(bottom, bubblePanel.frame.maxY + 6) }
        if badgeShown { bottom = max(bottom, badgePanel.frame.maxY + 6) }
        effortOffsetY = bottom - panel.frame.maxY
        effortShown = true
        layoutOverlays()
        effortPanel.orderFront(nil)
    }

    private func hideEffortCard() {
        guard effortShown else { return }
        effortShown = false
        effortOffsetY = nil
        effortPanel?.orderOut(nil)
        layoutOverlays()
    }

    private func applyEffort(_ level: String, petID: String, resumeID: String) {
        guard effortLevels.contains(where: { $0.id == level }) else { return }
        guard let session = sessions.first(where: { $0.id == petID }),
              session.resumeID == resumeID else {
            showNotice("无法应用思考力度", "该会话已经不在运行。")
            return
        }
        guard session.state != "waiting" else {
            showNotice(
                "暂不能切换思考力度",
                "该会话正在等待权限确认或计划审批，请先在终端处理对话框后再试。"
            )
            return
        }
        let target = terminalTarget(for: session.id)
        sendTerminalText("/effort " + level, term: target.term, tty: target.tty) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.showNotice(
                    "无法切换思考力度",
                    "没有找到该会话对应的终端标签。请手动在会话中输入 /effort \(level)。"
                )
                return
            }
            self.effortBySession[resumeID] = level
            self.saveState()
            self.triggerAlert(
                "思考力度已切换为「\(effortLabel(level))」",
                silent: true,
                duration: 3
            )
        }
    }

    private func explicitEffort(for session: Session, entries: [ProcessEntry]? = nil) -> String? {
        // /effort changes the live level without touching argv; prefer our record.
        if let rid = session.resumeID,
           let stored = effortBySession[rid],
           effortLevels.contains(where: { $0.id == stored }) {
            return stored
        }
        if let proc = claudeProcess(forPetID: session.id, entries: entries),
           let value = effortArgument(proc.args),
           effortLevels.contains(where: { $0.id == value }) {
            return value
        }
        return nil
    }

    private func effortLevel(for session: Session, entries: [ProcessEntry]? = nil) -> String {
        explicitEffort(for: session, entries: entries) ?? defaultEffortLevel() ?? "high"
    }

    private func defaultEffortLevel() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var value = root["effortLevel"] as? String
        if value == nil, let env = root["env"] as? [String: Any] {
            value = env["CLAUDE_CODE_EFFORT_LEVEL"] as? String
        }
        guard let value, effortLevels.contains(where: { $0.id == value }) else { return nil }
        return value
    }

    private func wrapperShellPID(_ petID: String) -> Int32? {
        let pidURL = runDir.appendingPathComponent(petID + ".pid")
        guard let raw = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return pid
    }

    private func isClaudeProcess(_ entry: ProcessEntry) -> Bool {
        if (entry.comm as NSString).lastPathComponent == "claude" { return true }
        let args = entry.args
        return args == "claude"
            || args.hasPrefix("claude ")
            || args.contains("/claude ")
            || args.hasSuffix("/claude")
    }

    // claude runs inside the wrapper's restart-loop subshell, so it is a
    // grandchild of the shell PID rather than a direct child.
    private func claudeProcess(forPetID petID: String, entries: [ProcessEntry]? = nil) -> ProcessEntry? {
        guard let shell = wrapperShellPID(petID) else { return nil }
        let all = entries ?? processEntries()
        var level: [Int32] = [shell]
        var seen: Set<Int32> = [shell]
        for _ in 0..<4 {
            var next: [Int32] = []
            for parent in level {
                for child in all where child.ppid == parent && seen.insert(child.pid).inserted {
                    if isClaudeProcess(child) { return child }
                    next.append(child.pid)
                }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }

    private func canAutoRestart(_ petID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: runDir.appendingPathComponent(petID + ".restartable").path
        )
    }

    @discardableResult
    private func restartSession(
        _ session: Session,
        effort: String?,
        model: String?,
        skip: Bool,
        reason: String
    ) -> Bool {
        guard let rid = session.resumeID,
              rid.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            showNotice("无法自动重启", "该会话缺少有效的恢复 UUID，请手动恢复。")
            return false
        }
        guard canAutoRestart(session.id) else {
            showNotice(
                "无法自动重启",
                "该会话由旧版包装函数启动，重启后不能自动恢复。请新开一个终端会话后再试；"
                    + "个人审查的更改仍会在下次恢复该会话时生效。"
            )
            return false
        }
        guard let proc = claudeProcess(forPetID: session.id) else {
            showNotice(
                "无法自动重启",
                "没有找到由包装函数启动的 Claude 进程，无法在同一终端自动恢复。\n\n"
                    + "请在终端退出后手动运行 claude --resume \(rid)。"
            )
            return false
        }
        var cleanModel: String?
        if let model, !model.isEmpty {
            guard model.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil else {
                return false
            }
            cleanModel = model
        }
        var cleanEffort: String?
        if let effort {
            guard effortLevels.contains(where: { $0.id == effort }) else { return false }
            cleanEffort = effort
        }
        let alert = NSAlert()
        alert.messageText = "重启会话并恢复对话？"
        var command = "claude --resume " + rid
        if let cleanModel { command += " --model " + cleanModel }
        if let cleanEffort { command += " --effort " + cleanEffort }
        if skip { command += " --dangerously-skip-permissions" }
        alert.informativeText = reason + "\n\n将结束当前 Claude 进程，并在同一终端自动运行：\n"
            + command + "\n\n对话记录已保存，恢复后从原处继续。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        var lines = ["resume=" + rid]
        if let cleanModel { lines.append("model=" + cleanModel) }
        if let cleanEffort { lines.append("effort=" + cleanEffort) }
        lines.append("skip=" + (skip ? "1" : "0"))
        let restartURL = runDir.appendingPathComponent(session.id + ".restart")
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: restartURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: restartURL.path
            )
        } catch {
            showNotice("无法自动重启", "写入重启标记失败：\(error.localizedDescription)")
            return false
        }
        markRestarting(session.id)
        kill(proc.pid, SIGTERM)
        triggerAlert("正在重启会话并恢复…", silent: true, duration: 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.focusTerminal(id: session.id)
        }
        return true
    }

    private func markRestarting(_ petID: String) {
        let url = runDir.appendingPathComponent(petID + ".json")
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        object["state"] = "start"
        object["event"] = "Restart"
        object["ts"] = Date().timeIntervalSince1970
        object["tool"] = ""
        object["detail"] = ""
        object["message"] = "正在重启并恢复会话…"
        object.removeValue(forKey: "turnStart")
        guard let output = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? output.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func showNotice(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func menuCopySessionID(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let id = session.resumeID
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
    }

    @objc private func menuCopyResumeCommand(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let id = session.resumeID
        else { return }
        guard id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
        let model = sender.representedObject as? String
        if let model,
           model.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) == nil {
            return
        }
        let cwd = session.cwd.isEmpty ? NSHomeDirectory() : session.cwd
        var line = "cd " + shellQuote(cwd) + " && claude --resume " + shellQuote(id)
        if let model { line += " --model " + shellQuote(model) }
        if reviewOffIDs.contains(id) { line += " --dangerously-skip-permissions" }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)
        triggerAlert("已复制恢复命令", silent: true, duration: 2.5)
    }

    @objc private func menuTogglePinSession(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let rid = session.resumeID
        else { return }
        if pinnedSessionID == rid {
            pinnedSessionID = nil
            triggerAlert("已取消置顶", silent: true, duration: 2.5)
        } else {
            pinnedSessionID = rid
            triggerAlert("已置顶 " + displayName(session), silent: true, duration: 2.5)
        }
        saveState()
        pollSessions()
    }

    @objc private func menuResumeSession(_ sender: NSMenuItem) {
        guard menuSessionIDs.indices.contains(sender.tag),
              let session = sessions.first(where: { $0.id == menuSessionIDs[sender.tag] }),
              let id = session.resumeID
        else { return }
        guard id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
        let model = sender.representedObject as? String
        if let model,
           model.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) == nil {
            return
        }
        let noReview = reviewOffIDs.contains(id)
        let skipFlag = noReview ? " --dangerously-skip-permissions" : ""
        let command = (model.map { "claude --resume \(id) --model \($0)" }
            ?? "claude --resume \(id)") + skipFlag
        let alert = NSAlert()
        alert.messageText = "在新终端恢复该会话？"
        alert.informativeText = "将新开终端窗口运行：\n\(command)\n\n"
            + (noReview ? "该会话已关闭个人审查，启动后将直接执行，不再逐次确认。\n\n" : "")
            + "建议先在旧终端退出当前对话，避免两个进程同时写入同一会话记录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cwd = session.cwd.isEmpty ? NSHomeDirectory() : session.cwd
        var line = "cd " + shellQuote(cwd) + " && claude --resume " + shellQuote(id)
        if let model { line += " --model " + shellQuote(model) }
        if noReview { line += " --dangerously-skip-permissions" }
        let term = session.term ?? frontmostTerminalHint() ?? runningTerminalHint() ?? "Apple_Terminal"
        openTerminalWindow(term: term, command: line)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func preferredTerminal() -> String {
        frontmostTerminalHint()
            ?? sessions.max(by: { $0.ts < $1.ts })?.term
            ?? runningTerminalHint()
            ?? "Apple_Terminal"
    }

    @objc private func menuOpenRecentConversation(_ sender: NSMenuItem) {
        guard recentConversationIDs.indices.contains(sender.tag),
              recentConversationProjects.indices.contains(sender.tag) else { return }
        let id = recentConversationIDs[sender.tag]
        guard id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
        let command = "cd " + shellQuote(recentConversationProjects[sender.tag])
            + " && claude --resume " + shellQuote(id)
        openTerminalTab(term: preferredTerminal(), command: command)
    }

    @objc private func menuNewSession() {
        // Resolve before the panel activates the pet, otherwise the frontmost
        // app is CodexPet and the target terminal falls back to a running one.
        let term = preferredTerminal()
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "在此启动"
        picker.message = "选择新 Claude 会话的工作目录"
        if let cwd = sessions.first(where: { $0.id == primaryID })?.cwd, !cwd.isEmpty {
            picker.directoryURL = URL(fileURLWithPath: cwd)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let command = "cd " + shellQuote(url.path) + " && claude"
        openTerminalTab(term: term, command: command)
    }

    private func openTerminalTab(term: String, command: String) {
        if term == "iTerm.app" {
            openTerminalWindow(term: term, command: command)
            return
        }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            if (count of windows) > 0 then
                do script "\(escaped)" in front window
            else
                do script "\(escaped)"
            end if
        end tell
        """
        runTerminalScript(script)
    }

    private func runTerminalScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard proc.terminationStatus != 0 else { return }
                self?.triggerAlert("无法打开终端，请检查自动化权限", silent: true, duration: 4)
            }
        }
        try? process.run()
    }

    private func openTerminalWindow(term: String, command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if term == "iTerm.app" {
            script = """
            tell application "iTerm2"
                activate
                create window with default profile command "\(escaped)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                set targetWindow to make new window
                do script "\(escaped)" in targetWindow
            end tell
            """
        }
        runTerminalScript(script)
    }

    private func collectRecentModels() -> [String] {
        prefetchRecentModels()
        prefetchProviderModels()
        return sessionModelsCache
    }

    private func prefetchProviderModels() {
        let now = Date().timeIntervalSince1970
        guard !providerModelsRefreshing, now - providerModelsCacheAt >= 600 else { return }
        guard let cred = apiCredentials() else {
            providerModelsCacheAt = now
            return
        }
        var components = URLComponents(url: cred.base, resolvingAgainstBaseURL: false)
        components?.path = "/v1/models"
        components?.query = nil
        guard let url = components?.url else {
            providerModelsCacheAt = now
            return
        }
        providerModelsRefreshing = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if cred.host.contains("anthropic") {
            request.setValue(cred.token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer " + cred.token, forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var models: [String] = []
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if statusOK, let data,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = root["data"] as? [[String: Any]] {
                for item in items {
                    guard let id = item["id"] as? String,
                          !id.isEmpty,
                          id.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil,
                          !models.contains(id)
                    else { continue }
                    models.append(id)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.providerModelsRefreshing = false
                self.providerModelsCacheAt = Date().timeIntervalSince1970
                if !models.isEmpty { self.providerModels = models }
            }
        }.resume()
    }

    private func prefetchRecentModels() {
        let now = Date().timeIntervalSince1970
        guard !sessionModelsRefreshing, now - sessionModelsCacheAt >= 60 else { return }
        sessionModelsRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let models = Self.scanRecentModels()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessionModelsRefreshing = false
                guard !models.isEmpty else { return }
                self.sessionModelsCache = models
                self.sessionModelsCacheAt = Date().timeIntervalSince1970
            }
        }
    }

    private static func scanRecentModels() -> [String] {
        let now = Date().timeIntervalSince1970
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var files: [(URL, Double)] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                guard now - modified < 14 * 86400 else { continue }
                files.append((url, modified))
            }
        }
        files.sort { $0.1 > $1.1 }
        var models: [String] = []
        func absorb(_ text: String, reversed: Bool) -> Bool {
            guard !text.isEmpty else { return false }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for line in (reversed ? lines.reversed() : lines) {
                guard line.contains("\"model\""),
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      !model.isEmpty, model != "<synthetic>", !models.contains(model)
                else { continue }
                models.append(model)
                if models.count >= 8 { return true }
            }
            return false
        }
        for (url, _) in files.prefix(40) {
            if absorb(readTail(url, bytes: 96 * 1024), reversed: true) { break }
            if absorb(Self.readHead(url, bytes: 96 * 1024), reversed: false) { break }
        }
        return models
    }

    private static func readHead(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @objc private func menuStats() {
        showStats(mode: .today)
    }

    @objc private func menuStatsHistory() {
        showStats(mode: .history)
    }

    private func showStats(mode: StatsMode = .today) {
        guard statsPanel != nil, !petHidden else { return }
        statsMode = mode
        lastUsageRead = 0
        refreshUsages()
        lastTokenScan = 0
        refreshTodayTokens()
        if !statsShown {
            statsShown = true
            statsPanel.orderFront(nil)
        }
        refreshStatsCard()
        statsHideTimer?.invalidate()
        let timer = Timer(timeInterval: mode == .history ? 10 : 6, repeats: false) { [weak self] _ in
            self?.hideStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsHideTimer = timer
    }

    private func refreshStatsCard() {
        guard statsShown, statsPanel != nil else { return }
        let text = statsAttributed(mode: statsMode)
        let maxWidth: CGFloat = statsMode == .history ? 380 * fontScale : 340 * fontScale
        let minWidth: CGFloat = statsMode == .history ? 220 * fontScale : 190
        let size = statsView.fit(text, maxWidth: maxWidth, minWidth: minWidth)
        statsSize = size
        statsView.show(text, frame: NSRect(origin: .zero, size: size))
        statsPanel.setFrame(NSRect(origin: statsPanel.frame.origin, size: size), display: true)
        positionStats()
    }

    private func hideStats() {
        statsHideTimer?.invalidate()
        statsHideTimer = nil
        guard statsShown else { return }
        statsShown = false
        statsPanel.orderOut(nil)
    }

    private func positionStats() {
        guard panel != nil, statsPanel != nil else { return }
        let petFrame = panel.frame
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var bottom = petFrame.maxY + 5
        if bubbleShown { bottom = max(bottom, bubblePanel.frame.maxY + 6) }
        if badgeShown { bottom = max(bottom, badgePanel.frame.maxY + 6) }
        var x = petFrame.midX - statsSize.width / 2
        x = min(max(x, vf.minX + 6), vf.maxX - statsSize.width - 6)
        var y = bottom
        if y + statsSize.height > vf.maxY {
            y = max(vf.minY, vf.maxY - statsSize.height)
        }
        statsPanel.setFrame(
            NSRect(x: x, y: y, width: statsSize.width, height: statsSize.height),
            display: true
        )
    }

    private func statsAttributed(mode: StatsMode = .today) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5 * fontScale
        let text = NSMutableAttributedString(string: mode == .history ? "近 7 天统计" : "今日统计", attributes: [
            .font: NSFont.systemFont(ofSize: 12 * fontScale, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.97),
            .paragraphStyle: paragraph,
        ])
        var lines: [String]
        if mode == .history {
            let entries = Array((stats.history + [PetDayRecord(from: stats)]).suffix(7)).reversed()
            let done = entries.reduce(0) { $0 + $1.done }
            let failed = entries.reduce(0) { $0 + $1.failed }
            let tokens = entries.reduce(0) { $0 + $1.tokens }
            lines = ["合计 完成 \(done) · 失败 \(failed) · Token " + formatTokens(tokens), ""]
            for record in entries {
                let label = record.day.count >= 10 ? String(record.day.suffix(5)) : record.day
                lines.append(label
                    + "   完成 " + String(format: "%3d", record.done)
                    + " · 失败 " + String(format: "%2d", record.failed)
                    + " · " + formatTokens(record.tokens))
            }
            if stats.history.isEmpty {
                lines.append("（历史数据从明天起逐日归档）")
            }
        } else {
            lines = [
                "会话 \(stats.seen.count) · 完成 \(stats.done) · 失败 \(stats.failed)",
                "活跃时长 " + formatDuration(stats.activeSeconds),
                "Token 消耗 " + formatTokens(stats.tokens),
            ]
            if !stats.history.isEmpty {
                let recent = Array((stats.history + [PetDayRecord(from: stats)]).suffix(7))
                lines.append("近 \(recent.count) 天完成 " + sparkline(recent.map { $0.done }))
            }
        }
        for line in lines {
            text.append(NSAttributedString(string: "\n" + line, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * fontScale, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func formatTokens(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }

    private func sparkline(_ values: [Int]) -> String {
        let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let peak = max(values.max() ?? 0, 1)
        return String(values.map { value in
            let index = Int((Double(value) / Double(peak) * Double(blocks.count - 1)).rounded())
            return blocks[max(0, min(index, blocks.count - 1))]
        })
    }

    private func loadStats() {
        let key = todayKey()
        if let data = try? Data(contentsOf: statsURL),
           let saved = try? JSONDecoder().decode(PetStats.self, from: data) {
            if saved.day == key {
                stats = saved
                statsSeen = Set(saved.seen)
            } else {
                stats = PetStats(day: key)
                stats.history = archiveStats(saved)
                statsSeen = []
                statsDirty = true
            }
        } else {
            stats = PetStats(day: key)
            statsSeen = []
        }
    }

    private func archiveStats(_ old: PetStats) -> [PetDayRecord] {
        guard old.done > 0 || old.failed > 0 || old.tokens > 0 || old.activeSeconds > 0 else {
            return old.history
        }
        var history = old.history
        if !history.contains(where: { $0.day == old.day }) {
            history.append(PetDayRecord(from: old))
        }
        if history.count > 30 { history.removeFirst(history.count - 30) }
        return history
    }

    private func saveStats() {
        guard !stats.day.isEmpty else { return }
        statsDirty = false
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }

    private func trackTurnEvents(_ loaded: [Session]) {
        let liveIDs = Set(loaded.map { $0.id })
        turnStartBySession = turnStartBySession.filter { liveIDs.contains($0.key) }
        turnDurationBySession = turnDurationBySession.filter { liveIDs.contains($0.key) }
        let activeStates: Set<String> = ["thinking", "bash", "search", "tool", "waiting", "start"]
        for session in loaded {
            guard session.ts > 0 else { continue }
            switch session.event {
            case "UserPromptSubmit":
                turnStartBySession[session.id] = session.ts
            case "Stop":
                if let start = session.turnStart ?? turnStartBySession[session.id],
                   session.ts >= start {
                    turnDurationBySession[session.id] = session.ts - start
                    turnStartBySession.removeValue(forKey: session.id)
                }
            default:
                // a fast PreToolUse can overwrite UserPromptSubmit before the next
                // poll; the status carries the prompt time so the turn still starts
                // at submission
                if turnStartBySession[session.id] == nil, activeStates.contains(session.state) {
                    turnStartBySession[session.id] = session.turnStart ?? session.ts
                }
            }
        }
    }

    private func trackSessionStates(_ loaded: [Session]) {
        newlyEnteredStates = []
        for session in loaded {
            if !statsSeen.contains(session.id) {
                statsSeen.insert(session.id)
                stats.seen.append(session.id)
                statsDirty = true
            }
            if let prev = prevSessionStates[session.id], prev != session.state {
                newlyEnteredStates.insert(session.id)
                if session.state == "done" {
                    stats.done += 1
                    statsDirty = true
                } else if session.state == "failed" {
                    stats.failed += 1
                    statsDirty = true
                }
            }
            prevSessionStates[session.id] = session.state
        }
    }

    @objc private func tickStats() {
        let key = todayKey()
        if stats.day != key {
            let history = archiveStats(stats)
            stats = PetStats(day: key)
            stats.history = history
            statsSeen = []
            prevSessionStates = [:]
            statsDirty = true
        }
        let activeStates: Set<String> = ["thinking", "bash", "search", "tool", "waiting", "start"]
        if sessions.contains(where: { activeStates.contains($0.state) }) {
            stats.activeSeconds += 5
            statsDirty = true
        }
        if sessions.contains(where: { $0.transcript != nil }) {
            lastUsageRead = 0
            refreshUsages()
        }
        refreshBalance()
        refreshVolcBalance()
        refreshArkImageModels()
        refreshTodayTokens()
        if statsDirty {
            saveStats()
        }
    }

    @objc private func menuResetPosition() {
        savedCenterX = nil
        savedBottomY = nil
        positioned = false
        applyMotion(index: index, loop: loop)
        updateBubble()
        updateBadge()
        saveState()
    }

    @objc private func menuReloadAssets() {
        guard let loaded = loadMotionSpecs() else { return }
        let currentKey = motions.indices.contains(index) ? motions[index].key : "idle"
        motions = loaded
        idleIndex = motions.firstIndex(where: { $0.key == "idle" }) ?? 0
        cheer = motions.indices.filter { $0 != idleIndex }
        index = motions.firstIndex(where: { $0.key == currentKey }) ?? idleIndex
        loop = true
        overrideUntil = 0
        applyMotion(index: index, loop: loop)
        followStateMotion()
    }

    @objc private func menuTop() {
        setOnTop(!onTop)
    }

    @objc private func menuQuit() {
        saveState()
        NSApp.terminate(nil)
    }
}

@main
private struct CodexPetMain {
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("""
            CodexPet — transparent floating pet for Claude Code

            Usage: CodexPet [--motion idle] [--scale 0.4] [--context-window 200000]

              --motion NAME       start with a motion key (idle, waving, jumping, ...)
              --scale N           window scale, 0.15–1.5 (default 0.4)
              --context-window N  token budget used for the context percentage

            One pet follows every session in ~/.claude/pet/run and exits
            shortly after the last Claude Code session ends.

            Left click: play the next motion once. Drag to move.
            Hover: show all sessions and their conversation length. Right click: menu.
            """)
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PetApp()
        app.delegate = delegate
        app.run()
    }
}
