import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import CryptoKit
import Foundation
import ImageIO
import SoundPacksWindow
import SwiftUI

private let animationRepository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let animationDirectory = animationRepository.appendingPathComponent(
    "gui/Sources/ClaudioGUI/Resources/EventAnimations")

private struct AnimationBoundaryReference: Decodable {
    struct Sample: Decodable {
        let style: EventAnimationStyle
        let action: String
        let elapsedMs: Double
        let frame: Int
        let ended: Bool
    }
    let sourceSHA256: String
    let samples: [Sample]
}

private struct AnimationPixelReference: Decodable {
    struct Sample: Decodable {
        let style: EventAnimationStyle
        let appearance: String
        let action: String
        let frame: Int
        let rgbaSHA256: String
    }
    let sourceSHA256: String
    let samples: [Sample]
}

private func rgbaDigest(_ image: CGImage) -> String? {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let result = bytes.withUnsafeMutableBytes { pointer -> Bool in
        guard
            let context = CGContext(
                data: pointer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return result ? SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() : nil
}

@MainActor
private final class AnimationPlaybackProbeState: ObservableObject {
    @Published var preferences = EventAnimationPreferences(style: .bitcoin)
    @Published var event: Event = .notification
    @Published var action = "notification"
    @Published var isVisible = true
    @Published var reduceMotion = false
    @Published var dark = false
    @Published var size: CGFloat = 32
    @Published var reading = EventNoticeReadingTime(
        sampledUptime: ProcessInfo.processInfo.systemUptime, remaining: 4, isPaused: false,
        budget: 4)
    private(set) var clockReads = 0
    var manualUptime: TimeInterval?

    var currentUptime: TimeInterval { manualUptime ?? ProcessInfo.processInfo.systemUptime }

    func readClock() -> TimeInterval {
        clockReads += 1
        return currentUptime
    }

    func resetReading(remaining: TimeInterval = 4, paused: Bool = false) {
        reading = EventNoticeReadingTime(
            sampledUptime: currentUptime,
            remaining: remaining, isPaused: paused, budget: 4)
    }
}

@MainActor
private struct AnimationPlaybackProbeView: View {
    @ObservedObject var state: AnimationPlaybackProbeState
    let resources: EventAnimationResources

    var body: some View {
        EventAnimationView(
            resources: resources, preferences: state.preferences, event: state.event,
            action: state.action, reading: state.reading, isVisible: state.isVisible,
            size: state.size, uptime: { state.readClock() }
        )
        // The public environment value is read-only. This SDK-provided setter drives the
        // same value that the production renderer reads, without changing system settings.
        .environment(\._accessibilityReduceMotion, state.reduceMotion)
        .environment(\.colorScheme, state.dark ? .dark : .light)
        .frame(width: 64, height: 64)
        .background(state.dark ? Color.black : Color.white)
    }
}

@MainActor
private final class AnimationPlaybackProbe {
    let state = AnimationPlaybackProbeState()
    private let window: NSWindow
    private let hosting: NSHostingView<AnimationPlaybackProbeView>

    init(resources: EventAnimationResources) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless], backing: .buffered, defer: false)
        hosting = NSHostingView(
            rootView: AnimationPlaybackProbeView(state: state, resources: resources))
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    func setAppearance(dark: Bool) {
        state.dark = dark
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    func bitmap() -> CGImage? {
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.cgImage
    }
}

@MainActor
private func animationReferenceBitmap(_ image: CGImage, size: CGFloat, dark: Bool) -> CGImage? {
    let hosting = NSHostingView(
        rootView: Image(decorative: image, scale: 2, orientation: .up)
            .resizable().interpolation(.none).frame(width: size, height: size)
            .frame(width: 64, height: 64).background(dark ? Color.black : Color.white))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.colorSpace = .sRGB
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    window.orderFront(nil)
    defer { window.contentView = nil; window.close() }
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        return nil
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return bitmap.cgImage
}

@MainActor
private func waitForAnimationCondition(
    timeout: TimeInterval = 1, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
private func expectAnimationClockStopped(
    _ state: AnimationPlaybackProbeState, _ description: String
) async {
    // Let a cancelled task finish its current suspension; then observe several genuine frame
    // intervals. A still-running Bitcoin loop calls its injected clock at least four times here.
    try? await Task.sleep(nanoseconds: 120_000_000)
    let before = state.clockReads
    try? await Task.sleep(nanoseconds: 350_000_000)
    expect(state.clockReads == before, description)
}

@MainActor
private func expectAnimationRenderedFrame(
    _ probe: AnimationPlaybackProbe, resources: EventAnimationResources, frame: Int,
    _ description: String
) async {
    let state = probe.state
    guard
        let frames = resources.loaded(state.preferences.style, dark: state.dark),
        let image = frames.image(action: state.action, frame: frame),
        let reference = animationReferenceBitmap(image, size: state.size, dark: state.dark),
        let expected = rgbaDigest(reference)
    else { expect(false, "连续播放的独立帧参考必须可渲染"); return }
    expect(
        await waitForAnimationCondition {
            probe.bitmap().flatMap(rgbaDigest) == expected
        }, description)
}

@MainActor
private final class AnimationControlledFinishDelay {
    private var waits: [CheckedContinuation<Void, Never>?] = []
    private(set) var completed = 0

    var pendingCount: Int { waits.count }

    /// Deliberately ignores cancellation: this reproduces a delay that already succeeded before
    /// its finish task is rescheduled on MainActor after replay cancelled the old task.
    func wait() async {
        await withCheckedContinuation { waits.append($0) }
        completed += 1
    }

    func release(_ index: Int) {
        let continuation = waits[index]
        waits[index] = nil
        continuation?.resume()
    }
}

@MainActor
func runEventAnimationIntegrationSuites() async {
    let resources = EventAnimationResources(directory: animationDirectory)
    for style in EventAnimationStyle.allCases where style != .original {
        for dark in [false, true] { await resources.load(style, dark: dark) }
    }
    suite("事件动画：HTML 时序与全部边界使用生产解析器") {
        do {
            let data = try Data(
                contentsOf: animationRepository.appendingPathComponent(
                    "designs/pixel-motion/samples/playback-reference.json"))
            let reference = try JSONDecoder().decode(AnimationBoundaryReference.self, from: data)
            let html = try Data(
                contentsOf: animationRepository.appendingPathComponent(
                    "designs/pixel-motion/Pixel Motion Prototype.html"))
            let digest = SHA256.hash(data: html).map { String(format: "%02x", $0) }.joined()
            expect(reference.sourceSHA256 == digest, "参考必须绑定当前 HTML，不接受旧参考")
            expect(reference.samples.count == 2_809, "五类事件全部循环，须覆盖完整首轮及后续循环边界")
            for sample in reference.samples {
                guard let frames = resources.loaded(sample.style, dark: false),
                    let timeline = frames.manifest.animations[sample.action]
                else { expect(false, "必须能加载 \(sample.style)/\(sample.action)"); continue }
                let frame = timeline.frame(at: sample.elapsedMs)
                expect(
                    frame.index == sample.frame,
                    "HTML 选帧一致：\(sample.style)/\(sample.action) \(sample.elapsedMs)")
                expect((frame.nextBoundaryMs == nil) == sample.ended, "单次结束停调度，循环不中断")
                expect(
                    timeline.frame(at: sample.elapsedMs, staticExpression: true).index
                        == timeline.reducedMotionFrame,
                    "静态及减少动态效果使用声明帧")
            }
        } catch { expect(false, "时序参考加载失败：\(error)") }
    }
    suite("事件动画：HTML 直接绘制的 480 帧与原生包资源解码一致") {
        do {
            let data = try Data(
                contentsOf: animationRepository.appendingPathComponent(
                    "designs/pixel-motion/samples/pixel-reference.json"))
            let reference = try JSONDecoder().decode(AnimationPixelReference.self, from: data)
            expect(reference.samples.count == 480, "三角色五事件16帧双外观必须齐全")
            for sample in reference.samples {
                guard
                    let frames = resources.loaded(sample.style, dark: sample.appearance == "dark"),
                    let image = frames.image(action: sample.action, frame: sample.frame)
                else { expect(false, "原生图片必须可解码"); continue }
                expect(
                    rgbaDigest(image) == sample.rgbaSHA256,
                    "原生 RGBA 必须匹配 HTML：\(sample.style)/\(sample.action)/\(sample.appearance)/\(sample.frame)"
                )
            }
        } catch { expect(false, "像素参考加载失败：\(error)") }
    }
    suite("事件动画：缺失、损坏与未来偏好 fail closed，直到明确重选才替换") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "animation-preferences-\(UUID()).plist")
        let defaults = SettingsFixtureDefaults(file: file)
        let preferences = ClaudioPreferences(defaults: defaults)
        expect(preferences.eventAnimation == .defaultValue, "升级与新用户默认原版")
        preferences.selectEventAnimationStyle(.bitcoin)
        var next = preferences.eventAnimation
        next.showsCharacter = false; next.usesStaticExpression = true
        preferences.setEventAnimation(next)
        let restored = ClaudioPreferences(defaults: SettingsFixtureDefaults(file: file))
        expect(restored.eventAnimation == next, "新 owner 从磁盘恢复完整偏好")
        expect(
            restored.eventAnimation.effectiveStyle == .original
                && restored.eventAnimation.style == .bitcoin, "关闭时保留选择并生效原版")
        restored.selectEventAnimationStyle(.pixelGhost)
        expect(restored.eventAnimation.showsCharacter, "选择角色开启显示")
        for invalid: Any in [
            "bad",
            Data(
                "{\"style\":\"future\",\"showsCharacter\":true,\"usesStaticExpression\":false}".utf8
            ), Data("{}".utf8),
        ] {
            defaults.set(invalid, forKey: EventAnimationPreferences.defaultsKey)
            let recovered = ClaudioPreferences(defaults: defaults)
            expect(recovered.eventAnimation == .defaultValue, "不支持或损坏偏好回退原版")
            expect(recovered.recoveryIssues.contains(.invalidEventAnimation), "恢复原因可观察")
            if let original = invalid as? Data {
                expect(
                    defaults.object(forKey: EventAnimationPreferences.defaultsKey) as? Data
                        == original, "恢复不改写原始字节")
            } else {
                expect(
                    defaults.object(forKey: EventAnimationPreferences.defaultsKey) as? String
                        == "bad", "恢复保留错误类型值")
            }
            recovered.selectEventAnimationStyle(.original)
            expect(!recovered.recoveryIssues.contains(.invalidEventAnimation), "明确重选原版也修复保存状态")
        }
    }
    suite("事件动画：语义不把普通通知和提问意图伪装为等待") {
        expect(
            EventAnimationTimeline.action(for: .notification, kind: .permission) == "notification",
            "授权使用待响应动作")
        expect(
            EventAnimationTimeline.action(for: .notification, kind: .needsInput) == "notification",
            "明确输入使用待响应动作")
        expect(
            EventAnimationTimeline.action(for: .notification, kind: .transient) == "idle",
            "普通消息和提问意图保持中立静态")
        expect(
            EventAnimationTimeline.action(for: .notification, kind: .review) == "idle",
            "未知原因不推断等待状态")
        let running = EventNoticeReadingTime(
            sampledUptime: 10, remaining: 3, isPaused: false, budget: 4)
        let paused = EventNoticeReadingTime(
            sampledUptime: 11, remaining: 2, isPaused: true, budget: 4)
        expect(running.animationElapsedMs(at: 11) == 2_000, "动画来自已消耗阅读预算")
        expect(paused.animationElapsedMs(at: 80) == 2_000, "悬停和聚焦暂停动画进度")
        let resumed = EventNoticeReadingTime(
            sampledUptime: 80, remaining: 2, isPaused: false, budget: 4)
        expect(resumed.animationElapsedMs(at: 81) == 3_000, "恢复不重置阅读预算")
        for style in EventAnimationStyle.allCases where style != .original {
            let manifest = resources.loaded(style, dark: false)!.manifest
            for event in Event.allCases {
                let timeline = manifest.animations[event.manifestKey]!
                expect(timeline.playback == "loop", "所有角色的五类事件在阅读期间循环")
                let total = Double(timeline.durationMs)
                expect(timeline.frame(at: total - 1).index == 15, "首轮完整播放至末帧")
                expect(
                    timeline.frame(at: total).index == timeline.loopStartFrame,
                    "首轮结束进入声明的循环起始帧")
                expect(
                    timeline.frame(at: total + 1).nextBoundaryMs != nil,
                    "首轮结束后继续调度而非停在末帧")
            }
            expect(manifest.animations["preview"]!.frame(at: 10_000).index == 15, "非产品试听小样仍保留末帧")
            expect(
                manifest.animations["preview"]!.frame(at: 10_000).nextBoundaryMs == nil,
                "单次小样结束停止帧调度")
        }
    }
    suite("事件动画：生产设置会话预览隔离、重播与离页清理") {
        let notices = EventNoticeModel(receiverEpoch: UUID())
        let preferences = ClaudioPreferences(
            defaults: SettingsFixtureDefaults(
                file: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "animation-session-\(UUID()).plist")))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .notifications(.eventAnimation), preferences: preferences,
            eventNoticeModel: notices, eventAnimations: resources)
        let session = fixture.session
        let before = notices.snapshot
        expect(session.animationPreview.isActive, "类型化子路由激活独立预览")
        let revision = session.animationPreview.replayRevision
        for event in Event.allCases { session.animationPreview.select(event) }
        preferences.selectEventAnimationStyle(.bitcoin)
        session.animationPreview.replay()
        expect(session.animationPreview.replayRevision > revision, "选择事件、样式和重播启动独立四秒预览")
        expect(notices.snapshot == before, "预览不写真实通知")
        expect(
            fixture.actionRecorder.actions.isEmpty
                && fixture.actionRecorder.eventAudibilityChangeCount == 0, "预览没有声音、宿主或系统操作")
        _ = session.send(.route(.destination(.notifications)))
        expect(
            !session.animationPreview.isActive && session.animationPreview.reading.isPaused,
            "离页停止预览")
        _ = session.send(.route(.notifications(.eventAnimation)))
        _ = session.send(.windowWillClose)
        expect(!session.animationPreview.isActive, "关闭窗口清理调度")
    }
    await suite("事件动画：生产播放器随可见性、暂停与静态状态停止调度") {
        let probe = AnimationPlaybackProbe(resources: resources)
        defer { probe.close() }
        let state = probe.state
        expect(
            await waitForAnimationCondition { state.clockReads >= 3 },
            "可见比特币循环通过真实 SwiftUI task 持续播放")

        state.isVisible = false
        await expectAnimationClockStopped(state, "不可见时取消循环取时")
        state.isVisible = true
        state.resetReading(paused: true)
        await expectAnimationClockStopped(state, "悬停或焦点暂停时停止帧调度")

        state.resetReading()
        var preferences = state.preferences
        preferences.usesStaticExpression = true
        state.preferences = preferences
        await expectAnimationClockStopped(state, "静态表情不继续调度")
        preferences.usesStaticExpression = false
        state.preferences = preferences
        state.reduceMotion = true
        await expectAnimationClockStopped(state, "系统减少动态效果不继续调度")

        state.reduceMotion = false
        state.action = "idle"
        await expectAnimationClockStopped(state, "中立静态呈现不继续调度")
        state.action = "notification"
        state.resetReading(remaining: 0)
        await expectAnimationClockStopped(state, "四秒阅读预算已结束时停止循环")

        preferences.style = .mechanicalDuck
        state.preferences = preferences
        state.event = .stop
        state.action = "stop"
        state.resetReading(remaining: 1)
        let beforeRepeat = state.clockReads
        expect(
            await waitForAnimationCondition { state.clockReads >= beforeRepeat + 3 },
            "小鸭结束动作首轮结束后，在剩余阅读预算内继续循环调度")

        preferences.style = .bitcoin
        state.preferences = preferences
        state.event = .notification
        state.action = "notification"
        state.resetReading()
        let previousReads = state.clockReads
        expect(
            await waitForAnimationCondition { state.clockReads >= previousReads + 3 },
            "从暂停或静态状态恢复后继续使用生产播放任务")
        probe.close()
        await expectAnimationClockStopped(state, "共享视图卸载后停止循环调度")
    }
    await suite("事件动画：独立四秒预览结束保留静态状态，重播不影响真实通知") {
        let notices = EventNoticeModel(receiverEpoch: UUID())
        let before = notices.snapshot
        let preview = EventAnimationPreviewSession()
        preview.activate()
        let revision = preview.replayRevision
        expect(!preview.reading.isPaused && preview.reading.remaining == 4, "新预览具有独立四秒预算")
        expect(
            await waitForAnimationCondition(timeout: 4.5) { preview.reading.isPaused },
            "四秒结束自动停止预览预算")
        expect(preview.isActive && preview.reading.remaining == 0, "结束后留在页面并保留最终静态画面")
        preview.replay()
        expect(
            preview.replayRevision == revision + 1 && !preview.reading.isPaused
                && preview.reading.remaining == 4, "重播开启新的独立四秒预算")
        expect(notices.snapshot == before, "结束与重播没有创建或更新真实通知")
        preview.deactivate()
    }
    await suite("事件动画：生产播放器连续暂停恢复、外观切换与完整重播及部分循环接缝") {
        let probe = AnimationPlaybackProbe(resources: resources)
        defer { probe.close() }
        let state = probe.state
        state.manualUptime = 1_000
        state.preferences = EventAnimationPreferences(style: .mechanicalDuck)
        state.resetReading()
        guard let duck = resources.loaded(.mechanicalDuck, dark: false),
            let waiting = duck.manifest.animations["notification"],
            let repeating = duck.manifest.animations["stop"],
            let looping = resources.loaded(.bitcoin, dark: false)?.manifest.animations["task_start"]
        else { expect(false, "连续播放必须具有完整的原生时序资源"); return }
        await expectAnimationRenderedFrame(probe, resources: resources, frame: 0, "实际播放从首帧开始")

        state.manualUptime = 1_000.4
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 400).index,
            "真实播放任务根据时间推进到400ms帧")
        state.resetReading(remaining: 3.6, paused: true)
        let pausedReading = state.reading
        await expectAnimationClockStopped(state, "播放中暂停停止取时")
        state.manualUptime = 1_100.4
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 400).index,
            "暂停时外部时间推进仍保留相同帧")
        expect(state.reading == pausedReading, "暂停期间保持原有remaining")
        state.resetReading(remaining: pausedReading.remaining)
        expect(state.reading.remaining == pausedReading.remaining, "恢复使用暂停时的同一remaining")
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 400).index,
            "恢复不重置动作首帧")

        state.manualUptime = 1_101
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 1_000).index,
            "恢复后继续推进动作进度")
        let beforeAppearance = state.reading
        probe.setAppearance(dark: true)
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 1_000).index,
            "播放中切换深色图集仍呈现相同动作进度")
        expect(state.reading == beforeAppearance, "播放中切换外观保留完整reading值")
        probe.setAppearance(dark: false)
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: waiting.frame(at: 1_000).index,
            "播放中切回浅色图集继续相同进度")
        expect(state.reading == beforeAppearance, "切回外观也不重置阅读预算")

        state.event = .stop
        state.action = "stop"
        state.resetReading()
        let repeatStart = state.currentUptime
        await expectAnimationRenderedFrame(probe, resources: resources, frame: 0, "重播动作真实首帧挂载")
        state.manualUptime = repeatStart + Double(repeating.durationMs - 50) / 1_000
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: repeating.frames - 1, "首轮末尾实际呈现停顿帧")
        let readsBeforeEnd = state.clockReads
        state.manualUptime = repeatStart + Double(repeating.durationMs + 1) / 1_000
        expect(
            await waitForAnimationCondition { state.clockReads > readsBeforeEnd },
            "播放任务实际跨过完整重播接缝")
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: 0, "首轮末帧停顿后实际重新播放首帧")
        state.manualUptime =
            repeatStart + Double(repeating.durationMs + repeating.durationsMs[0] + 10) / 1_000
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: 1, "第二轮实际推进下一帧")
        expect(
            state.reading.fraction(at: state.currentUptime) > 0,
            "完整动作重播不重置四秒阅读预算")

        state.preferences = EventAnimationPreferences(style: .bitcoin)
        state.event = .taskStart
        state.action = "task_start"
        state.resetReading()
        let loopStart = state.currentUptime
        await expectAnimationRenderedFrame(probe, resources: resources, frame: 0, "循环动作实际首帧挂载")
        state.manualUptime = loopStart + Double(looping.durationMs - 40) / 1_000
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: looping.frames - 1, "完整首轮实际播放至末帧")
        // A monotonic Double clock cannot represent every millisecond exactly; move one
        // millisecond beyond the seam so the sampled reading budget has actually crossed it.
        state.manualUptime = loopStart + Double(looping.durationMs + 1) / 1_000
        expect(
            state.reading.animationElapsedMs(at: state.currentUptime) > Double(looping.durationMs),
            "受控播放时钟已实际跨过首轮接缝")
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: looping.loopStartFrame!,
            "首轮接缝后进入声明的循环起始帧")
        let seamReads = state.clockReads
        state.manualUptime =
            loopStart
            + Double(looping.durationMs + looping.durationsMs[looping.loopStartFrame!] + 10) / 1_000
        await expectAnimationRenderedFrame(
            probe, resources: resources, frame: looping.loopStartFrame! + 1,
            "接缝后继续推进循环动作帧")
        expect(state.clockReads > seamReads, "首轮结束后循环仍实际调度")
        state.isVisible = false
        await expectAnimationClockStopped(state, "接缝后的循环在不可见时停止")
    }
    await suite("事件动画：旧预览完成回调不能终止重播或重新激活后的新预览") {
        let delay = AnimationControlledFinishDelay()
        let preview = EventAnimationPreviewSession(
            uptime: { ProcessInfo.processInfo.systemUptime },
            finishDelay: { await delay.wait() })
        preview.activate()
        expect(await waitForAnimationCondition { delay.pendingCount == 1 }, "首轮等待已挂起")
        preview.replay()
        let replayReading = preview.reading
        expect(await waitForAnimationCondition { delay.pendingCount == 2 }, "重播有独立完成任务")
        delay.release(0)
        expect(await waitForAnimationCondition { delay.completed == 1 }, "已取消的旧等待仍成功返回")
        expect(preview.reading == replayReading && !preview.reading.isPaused, "旧回调不结束新重播")
        delay.release(1)
        expect(await waitForAnimationCondition { preview.reading.isPaused }, "当前回调正常结束当前预览")
        expect(preview.reading.remaining == 0, "当前预览结束保留末态")

        preview.deactivate()
        preview.activate()
        expect(await waitForAnimationCondition { delay.pendingCount == 3 }, "重新激活首轮已等待")
        preview.deactivate()
        preview.activate()
        let reactivatedReading = preview.reading
        expect(await waitForAnimationCondition { delay.pendingCount == 4 }, "第二次激活有独立等待")
        delay.release(2)
        expect(await waitForAnimationCondition { delay.completed == 3 }, "离页前的旧等待仍成功返回")
        expect(
            preview.reading == reactivatedReading && preview.isActive && !preview.reading.isPaused,
            "离页前旧回调不能结束重新激活的预览")
        delay.release(3)
        expect(await waitForAnimationCondition { preview.reading.isPaused }, "新激活预览正常结束")
        preview.deactivate()
    }
    await suite("事件动画：生产视图在双外观与静态模式呈现声明帧且保留进度") {
        let probe = AnimationPlaybackProbe(resources: resources)
        defer { probe.close() }
        let state = probe.state
        state.preferences = EventAnimationPreferences(style: .mechanicalDuck)
        state.resetReading(remaining: 2.9, paused: true)
        let pausedReading = state.reading
        for size: CGFloat in [32, 64] {
            state.size = size
            for dark in [false, true] {
                probe.setAppearance(dark: dark)
                for mode in ["paused", "static", "reduce-motion"] {
                    state.preferences = EventAnimationPreferences(
                        style: .mechanicalDuck, usesStaticExpression: mode == "static")
                    state.reduceMotion = mode == "reduce-motion"
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard let frames = resources.loaded(.mechanicalDuck, dark: dark),
                        let timeline = frames.manifest.animations["notification"]
                    else { expect(false, "外观图集必须已加载"); continue }
                    let frame =
                        mode == "paused"
                        ? timeline.frame(at: 1_100).index : timeline.reducedMotionFrame
                    guard let expected = frames.image(action: "notification", frame: frame),
                        let reference = animationReferenceBitmap(expected, size: size, dark: dark),
                        let rendered = probe.bitmap()
                    else { expect(false, "原生角色与独立参考必须可渲染"); continue }
                    expect(
                        rgbaDigest(rendered) == rgbaDigest(reference),
                        "真实播放器呈现正确的 \(size)pt/\(dark ? "dark" : "light")/\(mode) 帧")
                    expect(state.reading == pausedReading, "外观、尺寸与静态切换不改写阅读进度")
                    expect(
                        abs(state.reading.animationElapsedMs(at: state.readClock()) - 1_100)
                            < 0.001,
                        "暂停时切换外观仍使用原来的动作进度")
                }
            }
        }
    }
    await suite("事件动画：资源异常回退可观察，修复后显式重试恢复") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "animation-resource-\(UUID())")
        do {
            try FileManager.default.copyItem(at: animationDirectory, to: directory)
            let file = directory.appendingPathComponent("E/sprites.png")
            let original = try Data(contentsOf: file)
            try Data("bad".utf8).write(to: file)
            let broken = EventAnimationResources(directory: directory)
            await broken.load(.mechanicalDuck, dark: false)
            expect(broken.loaded(.mechanicalDuck, dark: false) == nil, "错误图集不进入播放器")
            expect(broken.failure(.mechanicalDuck, dark: false) == .checksumMismatch, "校验失败显示明确原因")
            expect(
                broken.effectiveStyle(
                    for: EventAnimationPreferences(style: .mechanicalDuck), dark: false)
                    == .original,
                "通知总览和预览必须共同报告实际回退样式")
            try original.write(to: file)
            await broken.load(.mechanicalDuck, dark: false, retry: true)
            expect(
                broken.loaded(.mechanicalDuck, dark: false) != nil
                    && broken.failure(.mechanicalDuck, dark: false) == nil, "重试恢复可用资源")
            expect(
                broken.effectiveStyle(
                    for: EventAnimationPreferences(style: .mechanicalDuck), dark: false)
                    == .mechanicalDuck,
                "恢复后立即报告已选角色")
        } catch { expect(false, "异常资源 fixture 失败：\(error)") }
    }
    if CommandLine.arguments.contains("--event-animation-layout") {
        suite("事件动画：生产设置根视图 32 个原生布局组合") {
            for language in ClaudioAppLanguage.allCases {
                for dark in [false, true] {
                    for size in [
                        NSSize(width: 1_240, height: 820), NSSize(width: 960, height: 640),
                    ] {
                        for style in EventAnimationStyle.allCases {
                            let preferences = ClaudioPreferences(
                                defaults: SettingsFixtureDefaults(
                                    file: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("animation-layout-\(UUID()).plist"))
                            )
                            preferences.setLanguage(language)
                            preferences.selectEventAnimationStyle(style)
                            let fixture = SettingsPresentationFixtures.generalLogin(
                                language: language, route: .notifications(.eventAnimation),
                                preferences: preferences, eventAnimations: resources)
                            let probe = SettingsSoundsNativeLayoutProbe(
                                session: fixture.session, size: size,
                                appearance: dark ? .darkAqua : .aqua)
                            defer { probe.close() }
                            let cards = EventAnimationStyle.allCases.compactMap {
                                SoundPacksLayoutRecorder.frames[
                                    "settings.animation.style.\($0.rawValue)"]
                            }
                            expect(cards.count == 4, "四个真实样式控件必须挂载")
                            if let reading = SoundPacksLayoutRecorder.frames[
                                "settings.reading.notifications"]
                            {
                                expect(
                                    cards.allSatisfy {
                                        reading.insetBy(dx: -1, dy: -1).contains($0)
                                    }, "选择卡不裁切或横向溢出")
                            }
                            for pair in zip(cards, cards.dropFirst()) {
                                expect(
                                    pair.0.maxX < pair.1.minX && abs(pair.0.minY - pair.1.minY) < 1,
                                    "A 布局并排且不重叠")
                            }
                            expect(
                                SoundPacksLayoutRecorder.frames["settings.animation.banner-preview"]
                                    != nil, "真实共享横幅内容必须挂载")
                            expect(probe.scrollToEnd(), "最小窗口底部开关与状态必须可达")
                            if let output = ProcessInfo.processInfo.environment[
                                "CLAUDIO_LAYOUT_CAPTURE_DIR"]
                            {
                                let file = URL(fileURLWithPath: output).appendingPathComponent(
                                    "animation-\(style.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                                )
                                expect(probe.saveScreenshot(to: file), "32 个布局必须保存截图供 Codex 检查")
                            }
                        }
                    }
                }
            }
        }
    }
}
