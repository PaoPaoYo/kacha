import SwiftUI

/// 单屏框选视图：冻结帧 + 35% 黑遮罩挖洞 + 1pt 白边 + 毛玻璃尺寸胶囊
struct SelectionView: View {
    let frame: ScreenFrame
    /// 松开时回调：屏幕局部 point 选区（有效性已过滤）
    let onConfirm: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let selection = currentSelection

            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: frame.image, size: frame.screenPointSize))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                // 35% 黑遮罩，选区处挖洞（evenOdd 填充）
                DimmingMask(selection: selection)
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if let selection, SelectionGeometry.isValid(selection) {
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)

                    SizeBadge(rect: selection)
                        .position(
                            x: min(selection.midX, geo.size.width - 60),
                            y: max(selection.minY - 28, 26)
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0：原地点击也走 onEnded → 无效选区 → 取消
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil }
                        let rect = SelectionGeometry.normalize(from: value.startLocation, to: value.location)
                        guard SelectionGeometry.isValid(rect) else {
                            onCancel()
                            return
                        }
                        onConfirm(rect)
                    }
            )
            .onAppear {
                NSCursor.crosshair.push()
                NSLog("Kacha SelectionView onAppear: screenPointSize=%@, imagePixelSize=%@, geoSize=%@", NSStringFromSize(frame.screenPointSize), NSStringFromSize(frame.imagePixelSize), NSStringFromSize(geo.size))
            }
            .onDisappear { NSCursor.pop() }
        }
        .onExitCommand(perform: onCancel)
    }

    private var currentSelection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return SelectionGeometry.normalize(from: dragStart, to: dragCurrent)
    }
}

/// 整屏矩形挖去选区的遮罩形状（配合 eoFill 挖洞）
private struct DimmingMask: Shape {
    let selection: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Rectangle().path(in: rect)
        if let selection {
            path.addRect(selection)
        }
        return path
    }
}

/// 毛玻璃尺寸胶囊（macOS 系统玻璃材质）
private struct SizeBadge: View {
    let rect: CGRect

    var body: some View {
        Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
