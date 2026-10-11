import SwiftUI

/// 一段与渲染框架无关的路径指令。T2 图形与横向字标的路径数据只在这里转录一次，
/// SwiftUI（`Path`）与 AppKit（`CGContext`）消费同一批 segment，禁止第二份手抄。
public enum ClaudioPathSegment: Equatable, Sendable {
    case moveTo(CGPoint)
    case lineTo(CGPoint)
    case curveTo(end: CGPoint, control1: CGPoint, control2: CGPoint)
    case closeSubpath
}

/// T2 × C1 品牌几何的单一真相源（claudi0-basic-kit v1.0）。
///
/// 所有数值逐字转录自品牌包 SVG：T2 图形（母空间 64×64，`-45°` 旋转后墨迹盒
/// viewBox `11.2 11.2 41.6 41.6`）与横向字标（viewBox `0 0 504 144`，T2 图形经
/// `translate(76,72) scale(1.9250970100987266) translate(-32,-32)` 落位为
/// 以 x=36 起点、80 见方的墨迹，字母组经 `translate(153,38)` 落位，笔画 5.2、
/// 圆头圆角）。不重排、不拆分、不改字距。
public enum ClaudioT2Geometry {
    // MARK: T2 图形

    /// 官方母空间边长。
    public static let glyphDesignSize: CGFloat = 64
    /// 官方墨迹盒：`viewBox 11.2 11.2 41.6 41.6`，即 -45° 旋转后的外包盒。
    public static let glyphInkBox = CGRect(x: 11.2, y: 11.2, width: 41.6, height: 41.6)
    /// 官方旋转角（SVG `rotate(-45 32 32)`，屏幕坐标系下逆时针 45°）。
    public static let glyphRotationDegrees: CGFloat = -45

    /// 两段填充路径，逐字转录自品牌包 SVG（旋转前的局部坐标）。
    public static let glyphSegments: [ClaudioPathSegment] = [
        // M21 19H29V31H35V45H21C13.8203 45 8 39.1797 8 32C8 24.8203 13.8203 19 21 19Z
        .moveTo(CGPoint(x: 21, y: 19)),
        .lineTo(CGPoint(x: 29, y: 19)),
        .lineTo(CGPoint(x: 29, y: 31)),
        .lineTo(CGPoint(x: 35, y: 31)),
        .lineTo(CGPoint(x: 35, y: 45)),
        .lineTo(CGPoint(x: 21, y: 45)),
        .curveTo(
            end: CGPoint(x: 8, y: 32),
            control1: CGPoint(x: 13.8203, y: 45),
            control2: CGPoint(x: 8, y: 39.1797)),
        .curveTo(
            end: CGPoint(x: 21, y: 19),
            control1: CGPoint(x: 8, y: 24.8203),
            control2: CGPoint(x: 13.8203, y: 19)),
        .closeSubpath,
        // M33 19H43C50.1797 19 56 24.8203 56 32C56 39.1797 50.1797 45 43 45H39V27H33Z
        .moveTo(CGPoint(x: 33, y: 19)),
        .lineTo(CGPoint(x: 43, y: 19)),
        .curveTo(
            end: CGPoint(x: 56, y: 32),
            control1: CGPoint(x: 50.1797, y: 19),
            control2: CGPoint(x: 56, y: 24.8203)),
        .curveTo(
            end: CGPoint(x: 43, y: 45),
            control1: CGPoint(x: 56, y: 39.1797),
            control2: CGPoint(x: 50.1797, y: 45)),
        .lineTo(CGPoint(x: 39, y: 45)),
        .lineTo(CGPoint(x: 39, y: 27)),
        .lineTo(CGPoint(x: 33, y: 27)),
        .closeSubpath,
    ]

    // MARK: 横向字标（504×144）

    public static let wordmarkViewBox = CGRect(x: 0, y: 0, width: 504, height: 144)
    public static let wordmarkAspect: CGFloat = 504 / 144
    public static let wordmarkStrokeWidth: CGFloat = 5.2

    /// 官方 T2 落位：`translate(76,72) scale(1.9250970100987266) translate(-32,-32)`。
    public static let wordmarkGlyphScale: CGFloat = 1.9250970100987266
    public static let wordmarkGlyphCenter = CGPoint(x: 76, y: 72)
    /// 官方 T2 墨迹在横向组合里的起点 x（实测 36）——侧栏「墨迹对齐图标列」的几何依据。
    public static let wordmarkInkOriginX: CGFloat = 36
    /// 字母组官方平移：`translate(153,38)`。
    public static let wordmarkLettersOffset = CGPoint(x: 153, y: 38)

    /// 七个字母（c l a u d i 0）的路径，逐字转录自品牌包 SVG 的字母组（组内局部坐标）。
    /// 官方每字母另有 `transform="translate(N,0)"` 平移，见 ``wordmarkLetterOffsets``。
    public static let wordmarkLetterSegments: [[ClaudioPathSegment]] = [
        // c: M39 23C34 20 28 18 22 18C9 18 0 28 0 41C0 54 9 64 22 64C29 64 34 61 39 57
        [
            .moveTo(CGPoint(x: 39, y: 23)),
            .curveTo(
                end: CGPoint(x: 22, y: 18),
                control1: CGPoint(x: 34, y: 20),
                control2: CGPoint(x: 28, y: 18)),
            .curveTo(
                end: CGPoint(x: 0, y: 41),
                control1: CGPoint(x: 9, y: 18),
                control2: CGPoint(x: 0, y: 28)),
            .curveTo(
                end: CGPoint(x: 22, y: 64),
                control1: CGPoint(x: 0, y: 54),
                control2: CGPoint(x: 9, y: 64)),
            .curveTo(
                end: CGPoint(x: 39, y: 57),
                control1: CGPoint(x: 29, y: 64),
                control2: CGPoint(x: 34, y: 61)),
        ],
        // l: M8 6V53C8 61 11 64 17 64
        [
            .moveTo(CGPoint(x: 8, y: 6)),
            .lineTo(CGPoint(x: 8, y: 53)),
            .curveTo(
                end: CGPoint(x: 17, y: 64),
                control1: CGPoint(x: 8, y: 61),
                control2: CGPoint(x: 11, y: 64)),
        ],
        // a: M46 41C46 54 36 64 23 64C10 64 0 54 0 41C0 28 10 18 23 18C36 18 46 28 46 41M46 18V64
        [
            .moveTo(CGPoint(x: 46, y: 41)),
            .curveTo(
                end: CGPoint(x: 23, y: 64),
                control1: CGPoint(x: 46, y: 54),
                control2: CGPoint(x: 36, y: 64)),
            .curveTo(
                end: CGPoint(x: 0, y: 41),
                control1: CGPoint(x: 10, y: 64),
                control2: CGPoint(x: 0, y: 54)),
            .curveTo(
                end: CGPoint(x: 23, y: 18),
                control1: CGPoint(x: 0, y: 28),
                control2: CGPoint(x: 10, y: 18)),
            .curveTo(
                end: CGPoint(x: 46, y: 41),
                control1: CGPoint(x: 36, y: 18),
                control2: CGPoint(x: 46, y: 28)),
            .moveTo(CGPoint(x: 46, y: 18)),
            .lineTo(CGPoint(x: 46, y: 64)),
        ],
        // u: M0 18V42C0 56 8 64 21 64C34 64 42 56 42 42V18
        [
            .moveTo(CGPoint(x: 0, y: 18)),
            .lineTo(CGPoint(x: 0, y: 42)),
            .curveTo(
                end: CGPoint(x: 21, y: 64),
                control1: CGPoint(x: 0, y: 56),
                control2: CGPoint(x: 8, y: 64)),
            .curveTo(
                end: CGPoint(x: 42, y: 42),
                control1: CGPoint(x: 34, y: 64),
                control2: CGPoint(x: 42, y: 56)),
            .lineTo(CGPoint(x: 42, y: 18)),
        ],
        // d: M44 6V41C44 54 35 64 22 64C9 64 0 54 0 41C0 28 9 18 22 18C27 18 32 20 36 22
        [
            .moveTo(CGPoint(x: 44, y: 6)),
            .lineTo(CGPoint(x: 44, y: 41)),
            .curveTo(
                end: CGPoint(x: 22, y: 64),
                control1: CGPoint(x: 44, y: 54),
                control2: CGPoint(x: 35, y: 64)),
            .curveTo(
                end: CGPoint(x: 0, y: 41),
                control1: CGPoint(x: 9, y: 64),
                control2: CGPoint(x: 0, y: 54)),
            .curveTo(
                end: CGPoint(x: 22, y: 18),
                control1: CGPoint(x: 0, y: 28),
                control2: CGPoint(x: 9, y: 18)),
            .curveTo(
                end: CGPoint(x: 36, y: 22),
                control1: CGPoint(x: 27, y: 18),
                control2: CGPoint(x: 32, y: 20)),
        ],
        // i: M4 18V64
        [
            .moveTo(CGPoint(x: 4, y: 18)),
            .lineTo(CGPoint(x: 4, y: 64)),
        ],
        // 0: M22 8C8 8 0 20 0 36V38C0 54 8 65 22 65C36 65 44 54 44 38V35C44 19 36 8 22 8Z
        [
            .moveTo(CGPoint(x: 22, y: 8)),
            .curveTo(
                end: CGPoint(x: 0, y: 36),
                control1: CGPoint(x: 8, y: 8),
                control2: CGPoint(x: 0, y: 20)),
            .lineTo(CGPoint(x: 0, y: 38)),
            .curveTo(
                end: CGPoint(x: 22, y: 65),
                control1: CGPoint(x: 0, y: 54),
                control2: CGPoint(x: 8, y: 65)),
            .curveTo(
                end: CGPoint(x: 44, y: 38),
                control1: CGPoint(x: 36, y: 65),
                control2: CGPoint(x: 44, y: 54)),
            .lineTo(CGPoint(x: 44, y: 35)),
            .curveTo(
                end: CGPoint(x: 22, y: 8),
                control1: CGPoint(x: 44, y: 19),
                control2: CGPoint(x: 36, y: 8)),
            .closeSubpath,
        ],
    ]

    /// 官方逐字母平移（SVG 里每个 path 的 `transform="translate(N,0)"`，组内局部坐标）：
    /// c=0, l=43, a=75, u=135, d=192, i=247, 0=267。漏掉这组偏移，七个字母会叠画在同一处。
    public static let wordmarkLetterOffsets: [CGFloat] = [0, 43, 75, 135, 192, 247, 267]

    /// i 的点：品牌包 SVG 中字母组内的圆（组内坐标 (251,5)，半径 3.2）。
    public static let wordmarkDotCenter = CGPoint(x: 404, y: 43)
    public static let wordmarkDotRadius: CGFloat = 3.2

    // MARK: 路径构建（SwiftUI 与 AppKit 共用同一批 segment）

    /// 把 segment 逐点经 `transforms` 链（先应用的在前）写入 `path`。
    public static func append(
        _ segments: [ClaudioPathSegment],
        to path: CGMutablePath,
        transforms: [CGAffineTransform]
    ) {
        func place(_ point: CGPoint) -> CGPoint {
            transforms.reduce(point) { partial, transform in
                partial.applying(transform)
            }
        }
        for segment in segments {
            switch segment {
            case .moveTo(let point):
                path.move(to: place(point))
            case .lineTo(let point):
                path.addLine(to: place(point))
            case .curveTo(let end, let control1, let control2):
                path.addCurve(
                    to: place(end),
                    control1: place(control1),
                    control2: place(control2))
            case .closeSubpath:
                path.closeSubpath()
            }
        }
    }

    /// 官方旋转+缩放+落位合成：`p → translation + scale · R · (p − center)`，
    /// 与 SVG `translate(T) scale(s) translate(−c) rotate(deg, c)` 变换列同序。
    public static func glyphPlacement(
        scale: CGFloat,
        rotationDegrees: CGFloat,
        translation: CGPoint
    ) -> CGAffineTransform {
        let radians = rotationDegrees * .pi / 180
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        let center = glyphDesignSize / 2
        let rotatedCenterX = center * cosValue - center * sinValue
        let rotatedCenterY = center * sinValue + center * cosValue
        return CGAffineTransform(
            a: scale * cosValue,
            b: scale * sinValue,
            c: -scale * sinValue,
            d: scale * cosValue,
            tx: translation.x - scale * rotatedCenterX,
            ty: translation.y - scale * rotatedCenterY)
    }

    /// T2 图形铺满 `rect`：官方把 SVG viewBox 裁到墨迹盒（`11.2 11.2 41.6 41.6`），
    /// **元素尺寸即墨迹尺寸**——本函数同约定：`rect` 即目标墨迹大小（菜单栏 11.5pt、
    /// 面板头 14pt、关于页 60pt 都是墨迹值，不是 64 母空间值）。
    public static func glyphPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        append(glyphSegments, to: path, transforms: [
            glyphPlacement(
                scale: min(rect.width, rect.height) / glyphInkBox.width,
                rotationDegrees: glyphRotationDegrees,
                translation: CGPoint(x: rect.midX, y: rect.midY))
        ])
        return path
    }

    /// 横向组合里的 T2 图形（504×144 设计空间；墨迹起点 x=36、80 见方）。
    public static func wordmarkGlyphPath(extraTransform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        append(glyphSegments, to: path, transforms: [
            glyphPlacement(
                scale: wordmarkGlyphScale,
                rotationDegrees: glyphRotationDegrees,
                translation: wordmarkGlyphCenter),
            extraTransform,
        ])
        return path
    }

    /// 横向组合的字母笔画（504×144 设计空间，未描边；调用方负责 stroke 宽度与圆头）。
    public static func wordmarkLettersPath(extraTransform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        for (letter, offset) in zip(wordmarkLetterSegments, wordmarkLetterOffsets) {
            append(letter, to: path, transforms: [
                CGAffineTransform(
                    translationX: wordmarkLettersOffset.x + offset,
                    y: wordmarkLettersOffset.y),
                extraTransform,
            ])
        }
        return path
    }

    /// i 的点（504×144 设计空间）。
    public static func wordmarkDotPath(extraTransform: CGAffineTransform = .identity) -> CGPath {
        let rect = CGRect(
            x: wordmarkDotCenter.x - wordmarkDotRadius,
            y: wordmarkDotCenter.y - wordmarkDotRadius,
            width: wordmarkDotRadius * 2,
            height: wordmarkDotRadius * 2)
        // 该 SDK 的 CoreGraphics overlay 把这个初始化器的 transform 导入成指针类型。
        return withUnsafePointer(to: extraTransform) { pointer in
            CGPath(ellipseIn: rect, transform: pointer)
        }
    }

    /// 把 504×144 设计空间等比落进 `rect`（居中，不裁切）。
    public static func designTransform(for rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / wordmarkViewBox.width, rect.height / wordmarkViewBox.height)
        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: rect.midX - wordmarkViewBox.midX * scale,
            ty: rect.midY - wordmarkViewBox.midY * scale)
    }
}

/// T2 图形本体（无容器）：官方双路径经 -45° 旋转后的墨迹形状，调用方决定颜色。
public struct ClaudioT2Mark: View {
    public let size: CGFloat
    public let color: Color

    public init(size: CGFloat, color: Color) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        ClaudioT2MarkShape()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ClaudioT2MarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ClaudioT2Geometry.glyphPath(in: rect))
    }
}

/// T2 的 App 用法：酸柠容器 + 深墨图形（图形占比约 63%），深浅主题同一资产。
/// 容器边缘以 16% 深墨发丝线界定——酸柠对暖白底色仅 ≈1.1:1，无边线会在浅色窗口里融掉。
public struct ClaudioT2Badge: View {
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public let glyphSize: CGFloat
    public let dropShadow: Bool

    public init(
        size: CGFloat,
        cornerRadius: CGFloat,
        glyphSize: CGFloat,
        dropShadow: Bool = false
    ) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.glyphSize = glyphSize
        self.dropShadow = dropShadow
    }

    public var body: some View {
        ClaudioT2Mark(size: glyphSize, color: ClaudioTheme.brandInk)
            .frame(width: size, height: size)
            .background(badgeSurface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius - 0.5, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(ClaudioTheme.brandInk.opacity(0.16), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private var badgeSurface: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(ClaudioTheme.brandLime)
            .shadow(
                color: dropShadow ? Color.black.opacity(0.12) : .clear,
                radius: 1,
                y: 1)
    }
}

/// claudi0 官方横向字标（T2 图形 + claudi0 路径笔画，非系统字体重排）。
/// 颜色只经 ``ClaudioTheme/brandWord(_:)``：浅底深墨单色、深底酸柠；不重排、不改字距、不加阴影。
public struct ClaudioT2Wordmark: View {
    public let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(height: CGFloat = 38) {
        self.height = height
    }

    public var body: some View {
        let color = ClaudioTheme.brandWord(colorScheme)
        let scale = height / ClaudioT2Geometry.wordmarkViewBox.height
        return ZStack {
            ClaudioT2WordmarkGlyphShape().fill(color)
            ClaudioT2WordmarkLettersShape()
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: ClaudioT2Geometry.wordmarkStrokeWidth * scale,
                        lineCap: .round,
                        lineJoin: .round))
            ClaudioT2WordmarkDotShape().fill(color)
        }
        .frame(width: height * ClaudioT2Geometry.wordmarkAspect, height: height)
        .fixedSize()
        // 整个字标是一个视觉字形，不拆成 T2/字母/点的多个装饰节点。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("claudi0")
    }
}

private struct ClaudioT2WordmarkGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ClaudioT2Geometry.wordmarkGlyphPath(extraTransform: ClaudioT2Geometry.designTransform(for: rect)))
    }
}

private struct ClaudioT2WordmarkLettersShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ClaudioT2Geometry.wordmarkLettersPath(extraTransform: ClaudioT2Geometry.designTransform(for: rect)))
    }
}

private struct ClaudioT2WordmarkDotShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ClaudioT2Geometry.wordmarkDotPath(extraTransform: ClaudioT2Geometry.designTransform(for: rect)))
    }
}
