import AppKit
import ClaudioGUIComponents

/// 菜单栏图标 = T2 的 App 用法：18pt 酸柠彩色容器（圆角 4.5pt）+ 11.5pt 深墨 T2 图形。
/// 图形几何与 SwiftUI 视图共用 ``ClaudioT2Geometry`` 的同一段路径数据；颜色经
/// ``ClaudioTheme`` 桥接，不在此处解析 hex。
///
/// 品牌修订（2026-10-11）：坚持酸柠彩色容器，不走 macOS template 单色惯例——
/// 亮暗菜单栏下保持同一资产；高亮与置灰态后续由调用方自定义。
enum MenuBarIcon {
    private static let badgeSize: CGFloat = 18
    private static let glyphSize: CGFloat = 11.5
    private static let cornerRadius: CGFloat = 4.5

    static func make() -> NSImage {
        // flipped: true —— 让绘制回调使用与品牌包 SVG 相同的 y-down 坐标系，
        // 旋转方向与墨迹盒不需要做任何镜像补偿；位图内容即最终显示内容。
        let image = NSImage(
            size: NSSize(width: badgeSize, height: badgeSize),
            flipped: true
        ) { _ in
            drawBadge()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawBadge() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)

        context.addPath(
            CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil))
        context.setFillColor(NSColor(ClaudioTheme.brandLime).cgColor)
        context.fillPath()

        // 容器发丝线：酸柠对暖白底色仅 ≈1.1:1，边缘靠 16% 深墨线界定（原型同值）。
        context.addPath(
            CGPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: cornerRadius - 0.5,
                cornerHeight: cornerRadius - 0.5,
                transform: nil))
        context.setStrokeColor(
            NSColor(ClaudioTheme.brandInk).withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.strokePath()

        context.addPath(
            ClaudioT2Geometry.glyphPath(
                in: CGRect(
                    x: (badgeSize - glyphSize) / 2,
                    y: (badgeSize - glyphSize) / 2,
                    width: glyphSize,
                    height: glyphSize)))
        context.setFillColor(NSColor(ClaudioTheme.brandInk).cgColor)
        context.fillPath()
    }
}
