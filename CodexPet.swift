import AppKit
import AVFoundation
import Carbon.HIToolbox
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
    var soundVolume: Double?
    var motionMap: [String: String]?
    var dnd: Bool?
    var fontScale: Double?
    var hotkey: Bool?
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
    var contextAlert: Double?
}

private struct PetStatus: Decodable {
    var state: String
    var event: String?
    var ts: Double?
    var transcript: String?
    var cwd: String?
    var tool: String?
    var detail: String?
    var message: String?
    var prompt: String?
    var last: String?
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
            onDoubleClick?()
        } else {
            onClick?()
        }
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
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
    static var titleFont: NSFont { NSFont.systemFont(ofSize: 12 * scale, weight: .semibold) }
    static var detailFont: NSFont { NSFont.systemFont(ofSize: 11 * scale) }
    static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 10.5 * scale, weight: .regular) }
    static var prefixFont: NSFont { NSFont.systemFont(ofSize: 10 * scale, weight: .medium) }

    struct Row {
        var name: String
        var state: String
        var color: NSColor
    }

    struct Content {
        var prefix: String?
        var title: String
        var detail: String?
        var mono: Bool
        var rows: [Row] = []
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let hPad: CGFloat = 12
    private let vPad: CGFloat = 9
    private let tailHeight: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.maximumNumberOfLines = 5
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func attributed(_ content: Content) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString()
        if !content.rows.isEmpty {
            paragraph.lineSpacing = 3.5
            for (i, row) in content.rows.enumerated() {
                text.append(NSAttributedString(string: "[" + row.name + "]", attributes: [
                    .font: BubbleView.prefixFont,
                    .foregroundColor: NSColor(srgbRed: 0.52, green: 0.76, blue: 1.0, alpha: 0.9),
                    .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: "  " + row.state, attributes: [
                    .font: BubbleView.titleFont,
                    .foregroundColor: row.color,
                    .paragraphStyle: paragraph,
                ]))
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
        text.append(NSAttributedString(string: content.title, attributes: [
            .font: BubbleView.titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.97),
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
        let limit = max(160, maxWidth - hPad * 2)
        // boundingRect under-reports mixed-font wrapped text; the layout manager
        // gives the height NSTextField actually needs to draw every line
        let storage = NSTextStorage(attributedString: attributed(content))
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: limit, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let lineHeight = ceil(BubbleView.titleFont.boundingRectForFont.height) + (content.rows.isEmpty ? 2 : 6)
        let textHeight = min(ceil(used.height) + 4, lineHeight * CGFloat(maxLines))
        let width = min(maxWidth, max(150, ceil(used.width) + hPad * 2 + 4))
        let height = max(textHeight, lineHeight) + vPad * 2 + tailHeight
        return NSSize(width: width, height: height)
    }

    func show(_ content: Content, frame: NSRect, maxLines: Int) {
        self.frame = frame
        label.maximumNumberOfLines = maxLines
        label.cell?.truncatesLastVisibleLine = true
        label.attributedStringValue = attributed(content)
        label.frame = NSRect(
            x: hPad,
            y: tailHeight + vPad,
            width: frame.width - hPad * 2,
            height: frame.height - tailHeight - vPad * 2
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.90)
        let body = NSRect(
            x: 0.5,
            y: tailHeight,
            width: bounds.width - 1,
            height: bounds.height - tailHeight - 0.5
        )
        let path = NSBezierPath(roundedRect: body, xRadius: 9, yRadius: 9)
        background.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        let cx = bounds.midX
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - 6, y: tailHeight + 0.5))
        tail.line(to: NSPoint(x: cx, y: 0.8))
        tail.line(to: NSPoint(x: cx + 6, y: tailHeight + 0.5))
        tail.close()
        background.setFill()
        tail.fill()
    }
}

private final class BadgeView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let hPad: CGFloat = 12
    private let vPad: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.maximumNumberOfLines = 9
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = false
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func fit(_ text: NSAttributedString, maxWidth: CGFloat, minWidth: CGFloat) -> NSSize {
        let limit = max(80, maxWidth - hPad * 2)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: limit, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let content = max(ceil(used.width), minWidth)
        // usedRect for mixed-size, tabbed text runs a few points short;
        // without slack the final line (API balance) is silently clipped.
        return NSSize(width: min(maxWidth, content + hPad * 2 + 8), height: ceil(used.height) + vPad * 2 + 8)
    }

    func show(_ text: NSAttributedString, frame: NSRect) {
        self.frame = frame
        label.attributedStringValue = text
        label.frame = NSRect(
            x: hPad,
            y: vPad,
            width: frame.width - hPad * 2,
            height: frame.height - vPad * 2
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(12, bounds.height / 2)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
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
    private var statsShown = false
    private enum StatsMode { case today, history }
    private var statsMode = StatsMode.today
    private var statsSize = NSSize.zero
    private var statsHideTimer: Timer?
    private var statsTimer: Timer?
    private var stats = PetStats(day: "")
    private var statsSeen = Set<String>()
    private var prevSessionStates: [String: String] = [:]
    private var statsDirty = false
    private var menuSessionIDs: [String] = []
    private var motionMap: [String: String] = [:]
    private var alertDot: AlertDotView!

    private var motions: [Motion] = []
    private var index = 0
    private var idleIndex = 0
    private var cheer: [Int] = []
    private var cheerPos = 0
    private var loop = true
    private var frameIndex = 0
    private var motionStart = CACurrentMediaTime()
    private var frameTimer: Timer?
    private var frameInterval: TimeInterval = 1.0 / 60.0
    private var statusTimer: Timer?
    private var gcTimer: Timer?
    private var titlesTimer: Timer?
    private var frontTimer: Timer?
    private var titlesByTTY: [String: String] = [:]
    private var titlesBusy = false
    private var sessions: [Session] = []
    private var primaryID: String?
    private var usageBySession: [String: Int] = [:]
    private var emptySince: Date?
    private var lastUsageRead: Double = 0
    private var idleDimmed = false
    private var balanceAlertThreshold = 5.0
    private var contextAlertThreshold = 0.8
    private var balanceLow = false
    private var contextHighSessions = Set<String>()
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
    private var scale: CGFloat = 0.4
    private var onTop = true
    private var savedCenterX: CGFloat?
    private var savedBottomY: CGFloat?
    private var positioned = false

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
        guard claimSingleton() else {
            exit(0)
        }
        claimedSingleton = true
        loadState()
        loadConfig()
        loadStats()
        loadMotions()
        makePanel()
        applyHotKeySetting()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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
            if let value = state.soundVolume { soundVolume = min(max(value, 0), 3) }
            if let value = state.fontScale { fontScale = min(max(CGFloat(value), 0.85), 1.3) }
            if let value = state.dnd { doNotDisturb = value }
            if let value = state.hotkey { hotKeyEnabled = value }
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
            if let value = config.contextAlert, value > 0, value <= 1 { contextAlertThreshold = value }
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
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            anchorX = vf.maxX - size.width / 2 - 28
            bottom = vf.minY + 24
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

    private func startFrameTimer(interval: TimeInterval) {
        frameTimer?.invalidate()
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func updateFrameRate() {
        let idle = currentState == "idle"
            && !draggingPet
            && CACurrentMediaTime() >= overrideUntil
        let target = idle ? 1.0 / 15.0 : 1.0 / 60.0
        guard abs(target - frameInterval) > 0.001 else { return }
        frameInterval = target
        startFrameTimer(interval: target)
    }

    private func startTimers() {
        startFrameTimer(interval: frameInterval)

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

    @objc private func refreshFrontTTY() {
        guard currentOnly, !frontBusy else { return }
        frontBusy = true
        let script = """
        tell application "Terminal"
        if (count of windows) = 0 then return ""
        return tty of selected tab of front window
        end tell
        """
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
                if !text.isEmpty, text.hasPrefix("/dev/") {
                    self.frontTTY = text
                }
            }
        }
    }

    @objc private func refreshTitles() {
        guard !titlesBusy, sessions.contains(where: { $0.tty != nil }) else { return }
        titlesBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let script = """
            tell application "Terminal"
            set out to ""
            repeat with w in windows
            repeat with i from 1 to count of tabs of w
            set t to tab i of w
            set out to out & (tty of t) & "~~" & (custom title of t) & linefeed
            end repeat
            end repeat
            return out
            end tell
            """
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
        guard !motions.isEmpty else { return }
        updateFrameRate()
        let motion = motions[index]
        let total = motion.total
        guard total > 0 else { return }

        let elapsed = (CACurrentMediaTime() - motionStart) * speed
        let repeats = max(motionRepeats, 1)
        let span = total * (loop ? 1 : Double(repeats))
        if !loop && elapsed >= span {
            let wasOverride = overrideUntil > 0
            overrideUntil = 0
            if wasOverride {
                if currentState == "idle" || currentState == "done" {
                    setMotion("idle", loop: true)
                } else {
                    followStateMotion()
                }
            } else if currentState == "failed" {
                setMotion(motionKey(for: "thinking"), loop: true)
            } else {
                setMotion("idle", loop: true)
            }
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
    }

    @objc private func pollSessions() {
        var loaded = loadSessions()
        trackSessionStates(loaded)
        trackTurnEvents(loaded)
        if currentOnly, let tty = frontTTY {
            let focused = loaded.filter { $0.tty == tty }
            if !focused.isEmpty { loaded = focused }
        }
        let hadSessions = !sessions.isEmpty
        sessions = loaded
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
            includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [Session] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let status = try? JSONDecoder().decode(PetStatus.self, from: data) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            var tty: String?
            if let raw = try? String(contentsOf: runDir.appendingPathComponent(id + ".term"), encoding: .utf8) {
                let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let value = parts.count == 2 ? String(parts[1]) : raw
                if value.hasPrefix("/dev/") { tty = value }
            }
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
                tty: tty
            ))
        }
        return result.sorted { a, b in
            let pa = statePriority(a.state)
            let pb = statePriority(b.state)
            if pa != pb { return pa > pb }
            return a.ts > b.ts
        }
    }

    private func refreshUsages() {
        let now = CACurrentMediaTime()
        guard now - lastUsageRead > 0.6 else { return }
        lastUsageRead = now
        var next: [String: Int] = [:]
        for session in sessions {
            guard let path = session.transcript else { continue }
            let info = readTranscript(path: path, thinkingAfter: nil, wantThinking: false)
            if let used = info.used, used > 0 {
                next[session.id] = used
                if stats.usage[session.id] != used {
                    stats.usage[session.id] = used
                    statsDirty = true
                }
            }
        }
        usageBySession = next
        evaluateContextAlert()
    }

    private func refreshTodayTokens() {
        let now = CACurrentMediaTime()
        guard now - lastTokenScan > 4 else { return }
        lastTokenScan = now
        let day = todayKey()
        if tokenScanDay != day {
            tokenScanDay = day
            tokenFileStates.removeAll()
            tokenFileMtimes.removeAll()
        }
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var total = 0
        var caughtUp = true
        var live = Set<String>()
        let nowDate = Date()
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = values.contentModificationDate,
                      Calendar.current.isDate(mtime, inSameDayAs: nowDate) else { continue }
                let path = file.path
                live.insert(path)
                var state = tokenFileStates[path] ?? TranscriptUsageState()
                let size = UInt64(values.fileSize ?? 0)
                if size < state.offset {
                    state = TranscriptUsageState()
                }
                if tokenFileMtimes[path] != mtime || size > state.offset {
                    scanUsageFile(path: path, state: &state)
                    tokenFileMtimes[path] = mtime
                }
                tokenFileStates[path] = state
                if state.offset + 65536 < size { caughtUp = false }
                total += state.tokens
            }
        }
        for path in tokenFileStates.keys where !live.contains(path) {
            tokenFileStates.removeValue(forKey: path)
            tokenFileMtimes.removeValue(forKey: path)
        }
        if caughtUp && stats.tokens != total {
            stats.tokens = total
            statsDirty = true
            updateBadge()
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
                state.offset += UInt64(chunk.count)
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
        if soundEnabled && !doNotDisturb {
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
        lastTranscriptRead = now
        let info = readTranscript(
            path: path,
            thinkingAfter: currentState == "thinking" ? thinkingFloor : nil
        )
        let scanned = scanAssistantText(path: path)
        if !scanned.isEmpty {
            lastAssistantText = scanned
        } else if let text = info.text, !text.isEmpty {
            lastAssistantText = text
        }
        if currentState == "thinking", let thinking = info.thinking, !thinking.isEmpty {
            lastThinking = thinking
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
        do {
            try handle.seek(toOffset: state.offset)
            let data = handle.readDataToEndOfFile()
            guard let newline = data.lastIndex(of: 0x0A) else { return state.text }
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
                let total = input + created + cached
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
            return BubbleView.Content(prefix: "⚠", title: alertText, detail: nil, mono: false)
        }
        let narration = lastAssistantText.isEmpty ? nil : "⏺ " + headSnippet(lastAssistantText, 220)
        if !hovered, sessions.count >= 2 {
            let running = sessions.filter { $0.state != "idle" && $0.state != "done" }
            guard !running.isEmpty else { return nil }
            return BubbleView.Content(
                prefix: nil,
                title: "",
                detail: narration,
                mono: false,
                rows: running.map { session in
                    BubbleView.Row(
                        name: shortName(displayName(session), limit: 16),
                        state: stateLabel(session.state),
                        color: stateColor(session.state)
                    )
                }
            )
        }
        let prefix: String? = {
            guard let id = primaryID,
                  let primary = sessions.first(where: { $0.id == id }) else { return nil }
            return "[" + shortName(displayName(primary), limit: 14) + "]"
        }()
        switch currentState {
        case "thinking":
            return BubbleView.Content(
                prefix: prefix,
                title: "思考中",
                detail: narration ?? (lastThinking.isEmpty ? nil : tailSnippet(lastThinking, 200)),
                mono: false
            )
        case "bash", "search", "tool":
            let name = statusTool.isEmpty ? "工具" : statusTool
            return BubbleView.Content(
                prefix: prefix,
                title: "正在运行 " + name,
                detail: narration,
                mono: false
            )
        case "waiting":
            return BubbleView.Content(
                prefix: prefix,
                title: "等待你的操作",
                detail: statusMessage.isEmpty ? nil : statusMessage,
                mono: false
            )
        case "failed":
            let suffix = statusTool.isEmpty ? "" : " · " + statusTool
            return BubbleView.Content(
                prefix: prefix,
                title: "工具执行失败" + suffix,
                detail: statusMessage.isEmpty ? nil : statusMessage,
                mono: false
            )
        case "done":
            guard CACurrentMediaTime() < doneBubbleUntil else { return nil }
            let duration = primaryID.flatMap { turnDurationBySession[$0] }
            let title = duration.map { "完成 · 用时 " + formatDuration($0) } ?? "完成"
            return BubbleView.Content(prefix: prefix, title: title, detail: narration, mono: false)
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
        let subFont = NSFont.systemFont(ofSize: 10.5 * fontScale, weight: .regular)
        let dim = NSColor.white.withAlphaComponent(0.55)
        let body = NSColor.white.withAlphaComponent(0.92)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byTruncatingTail

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
            guard let balance = balanceLine else { return }
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n", attributes: [.font: subFont]))
            }
            text.append(NSAttributedString(string: balance + " · 今日 " + formatTokens(stats.tokens) + " tokens", attributes: [
                .font: subFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                .paragraphStyle: paragraph,
            ]))
        }

        if sessions.count == 1, let session = sessions.first {
            var percent = "--"
            var usage = ""
            if let used = usageBySession[session.id], used > 0 {
                percent = "\(Int((Double(used) / Double(max(contextWindow, 1)) * 100).rounded()))%"
                usage = " · \(formatTokens(used)) / \(formatTokens(contextWindow))"
            }
            text.append(NSAttributedString(string: "对话长度 ", attributes: [
                .font: stateFont, .foregroundColor: body,
            ]))
            text.append(NSAttributedString(string: percent, attributes: [
                .font: pctFont, .foregroundColor: stateColor(session.state),
            ]))
            text.append(NSAttributedString(string: usage, attributes: [
                .font: pctFont, .foregroundColor: dim,
            ]))
            key = "1|\(percent)|\(usage)"
        } else {
            struct Row {
                var name: String
                var state: String
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
                rows.append(Row(
                    name: name,
                    state: stateLabel(session.state),
                    percent: percent,
                    color: stateColor(session.state)
                ))
            }

            let gap: CGFloat = 16
            func width(_ value: String, _ font: NSFont) -> CGFloat {
                (value as NSString).size(withAttributes: [.font: font]).width
            }
            let nameW = rows.map { width($0.name, nameFont) }.max() ?? 0
            let stateW = rows.map { width($0.state, stateFont) }.max() ?? 0
            let pctW = rows.map { width($0.percent, pctFont) }.max() ?? 0
            let stateCol = ceil(nameW) + gap
            let totalW = stateCol + ceil(stateW) + gap + ceil(pctW)
            minWidth = totalW
            paragraph.tabStops = [
                NSTextTab(textAlignment: .left, location: stateCol, options: [:]),
                NSTextTab(textAlignment: .right, location: totalW, options: [:]),
            ]

            for row in rows {
                text.append(NSAttributedString(string: row.name + "\t", attributes: [
                    .font: nameFont, .foregroundColor: body, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: row.state + "\t", attributes: [
                    .font: stateFont, .foregroundColor: row.color, .paragraphStyle: paragraph,
                ]))
                text.append(NSAttributedString(string: row.percent + "\n", attributes: [
                    .font: pctFont, .foregroundColor: dim, .paragraphStyle: paragraph,
                ]))
                key += "\(row.name)|\(row.state)|\(row.percent);"
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
        key += "|\(balanceLine ?? "")|\(stats.tokens)"
        return (text, key, minWidth)
    }

    private func apiCredentials() -> (token: String, host: String)? {
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
        return (token, host)
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

    private func evaluateContextAlert() {
        guard contextWindow > 0 else { return }
        contextHighSessions.formIntersection(Set(sessions.map { $0.id }))
        var newlyHigh: [(id: String, percent: Int)] = []
        for session in sessions {
            guard let used = usageBySession[session.id], used > 0 else { continue }
            let ratio = Double(used) / Double(contextWindow)
            if ratio >= contextAlertThreshold {
                if !contextHighSessions.contains(session.id) {
                    contextHighSessions.insert(session.id)
                    newlyHigh.append((session.id, Int((ratio * 100).rounded())))
                }
            } else if ratio < max(contextAlertThreshold - 0.05, 0.1) {
                contextHighSessions.remove(session.id)
            }
        }
        guard let first = newlyHigh.first else { return }
        if newlyHigh.count == 1,
           let session = sessions.first(where: { $0.id == first.id }) {
            let name = shortName(displayName(session), limit: 12)
            triggerAlert("「\(name)」上下文已达 \(first.percent)%，建议 /compact")
        } else {
            let percent = newlyHigh.map { $0.percent }.max() ?? Int((contextAlertThreshold * 100).rounded())
            triggerAlert("\(newlyHigh.count) 个会话上下文已达 \(percent)% 以上，建议 /compact")
        }
    }

    private func triggerAlert(_ message: String, sound: String = "", repeats: Int = 1) {
        alertText = message
        alertUntil = CACurrentMediaTime() + 8
        updateBubble()
        guard soundEnabled, !doNotDisturb else { return }
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
        let dim = !busy && !hovered && !draggingPet
        idleDimmed = dim
        let target: CGFloat = dim ? 0.45 : 1.0
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
        let maxWidth = max(260, min(420, panel.frame.width * 3.2))
        let maxLines: Int
        if content.rows.isEmpty {
            maxLines = hovered ? 5 : 3
        } else {
            maxLines = content.rows.count + (content.detail == nil ? 0 : 2)
        }
        var cache = "\(content.prefix ?? "")|\(content.title)|\(content.detail ?? "")|\(Int(maxWidth))|\(maxLines)"
        if !content.rows.isEmpty {
            cache += "|" + content.rows.map { $0.name + $0.state }.joined(separator: ";")
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

    private func setHover(_ inside: Bool) {
        hovered = inside
        if inside {
            refreshTranscript(force: true)
            lastUsageRead = 0
            refreshUsages()
            refreshBalance(force: true)
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
            var y = bottom
            if y + badgeSize.height > vf.maxY {
                y = max(vf.minY, vf.maxY - badgeSize.height)
            }
            badgePanel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: badgeSize), display: true)
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
            let raw = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = Int32(raw) ?? -1
            if pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) {
                live += 1
            } else {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: runDir.appendingPathComponent(id + ".json"))
            }
        }

        for url in entries where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !pidIDs.contains(id) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mtime, Date().timeIntervalSince(mtime) > 7200 {
                try? fm.removeItem(at: url)
            } else {
                live += 1
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

    private func focusTerminal(id: String) {
        var term = "Apple_Terminal"
        var tty = ""
        let url = runDir.appendingPathComponent(id + ".term")
        let raw = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            term = String(parts[0])
            tty = String(parts[1])
        } else if !raw.isEmpty {
            tty = raw
        }
        activateTerminal(term: term, tty: tty)
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

    private func playNextCheer() {
        guard !cheer.isEmpty else { return }
        let target = cheer[cheerPos % cheer.count]
        cheerPos += 1
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
            hideStats()
            bubbleShown = false
            badgeShown = false
            bubbleCache = ""
            badgeCache = ""
            bubblePanel?.orderOut(nil)
            badgePanel?.orderOut(nil)
            panel?.orderOut(nil)
        } else {
            panel?.orderFrontRegardless()
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
            soundVolume: soundVolume,
            motionMap: motionMap.isEmpty ? nil : motionMap,
            dnd: doNotDisturb,
            fontScale: Double(fontScale),
            hotkey: hotKeyEnabled
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()

        let idleItem = NSMenuItem(
            title: "回到待机",
            action: #selector(menuIdle),
            keyEquivalent: ""
        )
        idleItem.target = self
        menu.addItem(idleItem)
        menu.addItem(.separator())

        let motionsItem = NSMenuItem(title: "动作", action: nil, keyEquivalent: "")
        let motionMenu = NSMenu()
        for (i, motion) in motions.enumerated() {
            let item = NSMenuItem(
                title: motion.name,
                action: #selector(menuMotion(_:)),
                keyEquivalent: ""
            )
            item.tag = i
            item.target = self
            if i == index { item.state = .on }
            motionMenu.addItem(item)
        }
        motionsItem.submenu = motionMenu
        menu.addItem(motionsItem)

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
        stateItem.submenu = stateMenu
        menu.addItem(stateItem)

        let sessionsItem = NSMenuItem(title: "会话", action: nil, keyEquivalent: "")
        let sessionsMenu = NSMenu()
        menuSessionIDs = sessions.map { $0.id }
        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "无活跃会话", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            sessionsMenu.addItem(emptyItem)
        } else {
            for (i, session) in sessions.enumerated() {
                let item = NSMenuItem(
                    title: displayName(session) + " · " + stateLabel(session.state),
                    action: #selector(menuFocusSession(_:)),
                    keyEquivalent: ""
                )
                item.tag = i
                item.target = self
                item.isEnabled = session.tty != nil
                if session.id == primaryID { item.state = .on }
                sessionsMenu.addItem(item)
            }
        }
        sessionsItem.submenu = sessionsMenu
        menu.addItem(sessionsItem)

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
        menu.addItem(sizeItem)

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
        menu.addItem(fontItem)

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
        menu.addItem(speedItem)

        let bubbleItem = NSMenuItem(
            title: "显示气泡",
            action: #selector(menuBubble),
            keyEquivalent: ""
        )
        bubbleItem.target = self
        bubbleItem.state = showBubble ? .on : .off
        menu.addItem(bubbleItem)

        let badgeItem = NSMenuItem(
            title: "显示悬停徽章",
            action: #selector(menuBadge),
            keyEquivalent: ""
        )
        badgeItem.target = self
        badgeItem.state = showBadge ? .on : .off
        menu.addItem(badgeItem)

        let dndItem = NSMenuItem(
            title: "勿扰模式（静音提醒）",
            action: #selector(menuDND),
            keyEquivalent: ""
        )
        dndItem.target = self
        dndItem.state = doNotDisturb ? .on : .off
        menu.addItem(dndItem)

        let soundItem = NSMenuItem(title: "提示音", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
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
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let currentItem = NSMenuItem(
            title: "只显示当前会话",
            action: #selector(menuCurrentOnly),
            keyEquivalent: ""
        )
        currentItem.target = self
        currentItem.state = currentOnly ? .on : .off
        menu.addItem(currentItem)

        let lockItem = NSMenuItem(
            title: "锁定位置",
            action: #selector(menuLock),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.state = lockedPet ? .on : .off
        menu.addItem(lockItem)

        let hotKeyItem = NSMenuItem(
            title: hotKeyFailed ? "⌥⌘P 显示/隐藏宠物（注册失败）" : "⌥⌘P 显示/隐藏宠物",
            action: #selector(menuHotKey),
            keyEquivalent: ""
        )
        hotKeyItem.target = self
        hotKeyItem.state = hotKeyEnabled ? .on : .off
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())
        let resetItem = NSMenuItem(
            title: "重置位置",
            action: #selector(menuResetPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let reloadItem = NSMenuItem(
            title: "重新载入素材",
            action: #selector(menuReloadAssets),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let dataItem = NSMenuItem(
            title: "打开数据目录",
            action: #selector(menuOpenDataDir),
            keyEquivalent: ""
        )
        dataItem.target = self
        menu.addItem(dataItem)

        let statsItem = NSMenuItem(
            title: "今日统计",
            action: #selector(menuStats),
            keyEquivalent: ""
        )
        statsItem.target = self
        menu.addItem(statsItem)

        let historyItem = NSMenuItem(
            title: "近 7 天统计",
            action: #selector(menuStatsHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let topItem = NSMenuItem(
            title: "始终置顶",
            action: #selector(menuTop),
            keyEquivalent: ""
        )
        topItem.target = self
        topItem.state = onTop ? .on : .off
        menu.addItem(topItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    @objc private func menuIdle() {
        overrideUntil = 0
        applyMotion(index: idleIndex, loop: true)
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
        let text = statsAttributed(mode: mode)
        let maxWidth: CGFloat = mode == .history ? 380 * fontScale : 340 * fontScale
        let minWidth: CGFloat = mode == .history ? 220 * fontScale : 190
        let size = statsView.fit(text, maxWidth: maxWidth, minWidth: minWidth)
        statsSize = size
        statsView.show(text, frame: NSRect(origin: .zero, size: size))
        statsPanel.setFrame(NSRect(origin: statsPanel.frame.origin, size: size), display: true)
        if !statsShown {
            statsShown = true
            statsPanel.orderFront(nil)
        }
        positionStats()
        statsHideTimer?.invalidate()
        let timer = Timer(timeInterval: mode == .history ? 10 : 6, repeats: false) { [weak self] _ in
            self?.hideStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsHideTimer = timer
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
        paragraph.lineSpacing = 3.5
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
                if let start = turnStartBySession[session.id], session.ts >= start {
                    turnDurationBySession[session.id] = session.ts - start
                    turnStartBySession.removeValue(forKey: session.id)
                }
            default:
                // a fast PreToolUse can overwrite UserPromptSubmit before the next
                // poll, so fall back to the first active status we observe
                if turnStartBySession[session.id] == nil, activeStates.contains(session.state) {
                    turnStartBySession[session.id] = session.ts
                }
            }
        }
    }

    private func trackSessionStates(_ loaded: [Session]) {
        for session in loaded {
            if !statsSeen.contains(session.id) {
                statsSeen.insert(session.id)
                stats.seen.append(session.id)
                statsDirty = true
            }
            if let prev = prevSessionStates[session.id], prev != session.state {
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
