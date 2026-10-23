// whale-mini helper —— 桌面上一张始终置顶的小卡片：Q 版鲸鱼娘 + 它此刻在想什么。
//
// 启动：读 ~/.dsh/whale-mini/config.json（图片、宽高），把 DeepSeek Harness 隐藏。
// 运行：每 0.4s 读一次 state.json，把宿主攒的 reasoning 文字滚到卡片右侧。
// 交互：拖 = 移动（松手记位置）；单击 = 回主窗口并退出；右键 = 展开 / 退出。
// 层级：level = .floating + canJoinAllSpaces，全屏应用上也盖得住。
import AppKit

/// 状态目录：--dir 参数优先，其次 WHALE_MINI_DIR，最后真实家目录。
func stateDirectory() -> String {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--dir"), index + 1 < args.count, !args[index + 1].isEmpty {
        return args[index + 1]
    }
    if let env = ProcessInfo.processInfo.environment["WHALE_MINI_DIR"], !env.isEmpty {
        return env
    }
    return NSHomeDirectory() + "/.dsh/whale-mini"
}
let stateDir = stateDirectory()
let configPath = stateDir + "/config.json"
let statePath = stateDir + "/state.json"
let posPath = stateDir + "/pos.json"

struct HelperConfig: Decodable {
    var image: String?
    var width: Double?
    var height: Double?
    var hide: Bool?
}

struct SavedPoint: Decodable {
    var x: Double
    var y: Double
}

func decodeFile<T: Decodable>(_ path: String) -> T? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// 一行诊断日志，落在状态目录的 helper.log（用 open 拉起时 stdout 会被丢掉）。
func log(_ message: String) {
    let line = "[whale-mini] " + message + "\n"
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: stateDir + "/helper.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSWindow?
    private var imageView: NSImageView?
    private var textView: NSTextField?
    private var captionView: NSTextField?
    private var shouldHide = true
    private var lastRendered = ""

    private var pressMouse = NSPoint.zero
    private var pressOrigin = NSPoint.zero
    private var dragging = false
    private var poller: Timer?
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(to: URL(fileURLWithPath: stateDir + "/helper.pid"), atomically: true, encoding: .utf8)
        buildPanel()
        startPolling()
        installMouseMonitor()
        hideHarness()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        hideHarness()
        return true
    }

    // ── 卡片 ────────────────────────────────────────────────────────────────
    private func buildPanel() {
        let config = decodeFile(configPath) as HelperConfig? ?? HelperConfig(image: nil, width: nil, height: nil, hide: nil)
        let width = CGFloat(config.width ?? 232)
        let height = CGFloat(config.height ?? 96)
        let start = restoredOrigin(width: width, height: height) ?? defaultOrigin(width: width, height: height)
        shouldHide = config.hide ?? true

        let panel = NSWindow(
            contentRect: NSRect(x: start.x, y: start.y, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true

        // 毛玻璃底：圆角 + 一层细边，明暗壁纸上都读得清
        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        root.addSubview(effect)

        let border = NSView(frame: root.bounds)
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.cornerRadius = 18
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        root.addSubview(border)

        // Q 版立绘：正方形、靠左
        let side = height - 16
        let picture = NSImageView(frame: NSRect(x: 8, y: 8, width: side, height: side))
        picture.imageScaling = .scaleProportionallyUpOrDown
        if let path = config.image, !path.isEmpty {
            picture.image = NSImage(contentsOfFile: path)
        }
        root.addSubview(picture)

        // 右上角状态小字 + 右下思考正文
        let textX = side + 16
        let textWidth = width - textX - 12
        let caption = NSTextField(labelWithString: "空闲中")
        caption.frame = NSRect(x: textX, y: height - 26, width: textWidth, height: 14)
        caption.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        caption.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        caption.lineBreakMode = .byTruncatingTail
        root.addSubview(caption)

        let text = NSTextField(wrappingLabelWithString: "点我回窗口")
        text.frame = NSRect(x: textX, y: 10, width: textWidth, height: height - 40)
        text.font = NSFont.systemFont(ofSize: 10.5)
        text.textColor = NSColor(calibratedWhite: 1, alpha: 0.86)
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        text.isSelectable = false
        root.addSubview(text)

        panel.contentView = root
        panel.orderFrontRegardless()

        self.panel = panel
        self.imageView = picture
        self.textView = text
        self.captionView = caption
        log("card shown \(Int(width))x\(Int(height)) at (\(Int(start.x)),\(Int(start.y))) image=\(picture.image != nil) hide=\(shouldHide) dir=\(stateDir)")
    }

    private func defaultOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - width - 24, y: visible.minY + 96)
    }

    private func restoredOrigin(width: CGFloat, height: CGFloat) -> NSPoint? {
        guard let saved = decodeFile(posPath) as SavedPoint? else { return nil }
        let point = NSPoint(x: saved.x, y: saved.y)
        let probe = NSRect(origin: point, size: NSSize(width: width, height: height))
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) else { return nil }
        return point
    }

    // ── 思考过程 ────────────────────────────────────────────────────────────
    private func startPolling() {
        refreshState()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func refreshState() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let status = (object["status"] as? String) ?? "idle"
        let raw = (object["text"] as? String) ?? ""
        // 只取最后 ~44 个字：正好四行，且结尾就是最新想到的那一句
        let tail = String(raw.suffix(44))
        let rendered = tail.isEmpty ? placeholder(for: status) : "…" + tail
        guard rendered != lastRendered else {
            captionView?.stringValue = caption(for: status)
            return
        }
        lastRendered = rendered
        textView?.stringValue = rendered
        captionView?.stringValue = caption(for: status)
    }

    private func caption(for status: String) -> String {
        switch status {
        case "thinking": return "正在想"
        case "writing": return "正在写"
        case "tool": return "在跑工具"
        default: return "空闲中"
        }
    }

    private func placeholder(for status: String) -> String {
        switch status {
        case "thinking": return "（正在想…）"
        case "writing": return "（正在写…）"
        case "tool": return "（在跑工具…）"
        default: return "点我回窗口"
        }
    }

    // ── 鼠标：拖 = 移动，单击 = 回窗口 ──────────────────────────────────────
    private func installMouseMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self = self, event.window === self.panel else { return event }
            switch event.type {
            case .leftMouseDown:
                self.pressMouse = NSEvent.mouseLocation
                self.pressOrigin = self.panel?.frame.origin ?? .zero
                self.dragging = false
                return nil
            case .leftMouseDragged:
                let now = NSEvent.mouseLocation
                let dx = now.x - self.pressMouse.x
                let dy = now.y - self.pressMouse.y
                if !self.dragging && (abs(dx) > 2 || abs(dy) > 2) { self.dragging = true }
                guard self.dragging, let panel = self.panel else { return nil }
                panel.setFrameOrigin(NSPoint(x: self.pressOrigin.x + dx, y: self.pressOrigin.y + dy))
                return nil
            case .leftMouseUp:
                if self.dragging {
                    self.storePosition()
                } else {
                    self.restoreHarness()
                }
                self.dragging = false
                return nil
            default:
                self.showMenu(with: event)
                return nil
            }
        }
    }

    private func showMenu(with event: NSEvent) {
        guard let view = panel?.contentView else { return }
        let menu = NSMenu()
        let expand = NSMenuItem(title: "展开 DeepSeek Harness", action: #selector(activateNow), keyEquivalent: "")
        expand.target = self
        menu.addItem(expand)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出小卡片", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func activateNow() { restoreHarness() }
    @objc private func quitNow() { NSApp.terminate(nil) }

    private func storePosition() {
        guard let panel = panel else { return }
        let frame = panel.frame
        let payload: [String: Double] = ["x": Double(frame.origin.x), "y": Double(frame.origin.y)]
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: URL(fileURLWithPath: posPath))
        }
    }

    // ── 主窗口 ──────────────────────────────────────────────────────────────
    private func harnessApp() -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek.dsh").first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "") == "DeepSeek Harness" }
    }

    private func hideHarness() {
        guard shouldHide else {
            log("hide skipped by config")
            return
        }
        guard let app = harnessApp() else {
            log("harness app not found")
            return
        }
        _ = app.hide()
        Thread.sleep(forTimeInterval: 0.25)
        log("harness hidden=\(app.isHidden)")
    }

    private func restoreHarness() {
        panel?.orderOut(nil)
        // unhide + activate 在 macOS 14+ 不再保证把别的 app 顶到前台；
        // NSWorkspace.openApplication 等于 Finder 里双击，必定解除隐藏并激活。
        let target = harnessApp()
        let url = target?.bundleURL ?? URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error { log("restore failed: \(error.localizedDescription)") }
        }
        log("restore requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
