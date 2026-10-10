import CoreGraphics
import Foundation

/// 滚动长图拼接器。
///
/// 单次追加的流程：
/// 1. 分析当前帧（行签名 + 行纹理），得到与上一采样帧的**固定区域**（顶栏 / 底栏 / 右侧滚动条）；
/// 2. 在**内容区**内做位移匹配：截尾加权均值打分（抗动画/噪点）+ 次优领先度判歧义 + 预测窗口加速；
/// 3. 只把新露出的内容行增量写入 `RowCanvas`，固定区域绝不写入长图。
///
/// 与旧实现的关键差别：
/// - 旧实现只认顶部固定 header，追加时永远取「新帧最底部 shift 行」。只要单次滚动量小于
///   底部固定栏高度，追加进去的就是固定栏副本（聊天窗口必现）；固定栏还会抬高整体匹配代价，
///   把大滚动直接顶过硬阈值判成失配。
/// - 旧实现用全体均值 + 硬阈值 8，遇到周期内容/动画区没有拒绝机制，会静默追加错误位移。
///
/// 本类型是纯计算、无 UI 依赖的值语义类型，调用方负责把它放到后台执行。
struct ScrollingStitcher {
    enum Result: Equatable {
        case started
        case appended(Int)
        /// 画面没动（含低于最小位移的抖动、整帧静止的大片空白）
        case unchanged
        case unmatched
        /// 帧尺寸变化（窗口缩放/换屏）：不写画布，也不推进参考帧
        case sizeChanged
        case limitReached
    }

    /// 检测到的固定区域（单位：像素行/列）
    struct Bands: Equatable, Sendable {
        var top = 0
        var bottom = 0
        var right = 0
        var confirmed = false

        var isZero: Bool { top == 0 && bottom == 0 && right == 0 }
    }

    // MARK: - 配置

    /// 长图尺寸上限（沿用旧实现：最长 24000px、结果位图最大 160MB）
    var maxHeight = 24_000
    var maxBytes = 160_000_000
    /// 小于该位移视为抖动，不作为一次有效滚动（保留参考帧，位移会累积）
    var minimumShift = 4
    /// 追加时回退若干行由新帧覆盖，掩掉接缝处的亚像素渲染差异（不丢内容）
    var seamOverlap = 2
    /// 匹配置信阈值（行签名 0…255 亮度差尺度）
    var matchThreshold = 10.0
    /// 最优位移必须比非相邻次优好出的幅度，否则判为歧义、丢弃该帧
    var uniquenessMargin = 3.0

    private static let identityThreshold = 1.0
    private static let fixedDifferenceThreshold = 8.0
    /// 一行里"变化像素"占比低于该值也视为静止（容忍固定栏内的光标闪烁、进度条等稀疏动画）
    private static let fixedChangedFraction = 0.02
    private static let maximumBlocks = 16
    private static let maximumRowSamples = 64
    /// 连续失配这么多次后把参考帧重锚到当前帧（否则过大跳变/长期无法对齐会永久失配）
    private static let realignThreshold = 6
    /// 固定区检测时至少保留这么多行可动内容
    private static let minimumMovableRows = 32


    /// 匹配所需的最小重叠行数（内容很高时也要允许 Page Down 这种大跳变）
    private static func minimumOverlap(contentHeight: Int) -> Int {
        max(24, contentHeight / 12)
    }

    // MARK: - 状态

    private(set) var bands = Bands()
    private(set) var lastShift: Int?
    private(set) var consecutiveFailures = 0
    /// 本帧是否因"参考帧落后太久"而重锚（调用方据此提示用户中间可能缺一段）
    private(set) var didRealign = false
    private var canvas: RowCanvas?
    private var previous: FrameAnalysis?
    /// 最近一帧（不管有没有接上）。用来判断"内容本身能不能对齐"：
    /// 参考帧太旧时相邻两帧也许仍然可对齐，那就该立刻重锚而不是长时间静默失配。
    private var latest: FrameAnalysis?
    /// 长图底边对应的帧行号：确定后每次追加都接到这里（保证行号连续）
    private var compositeBottom: Int?
    private var pendingBands: Bands?

    /// 全分辨率长图（零拷贝包装；缓冲区之后仍可能被 `append` 重写，调用方封盘后再导出）
    var image: CGImage? { canvas?.makeImage() }
    /// 降采样预览图
    var preview: CGImage? { canvas?.makePreview(maxWidth: 360) }
    var pixelHeight: Int { canvas?.height ?? 0 }
    var remainingRows: Int { canvas?.remainingRows ?? maxHeight }

    // MARK: - 主流程

    mutating func append(_ frame: CGImage) -> Result {
        guard let analysis = FrameAnalysis(image: frame) else { return .unmatched }

        guard let canvas else {
            let created = RowCanvas(width: analysis.pixels.width,
                                    maxHeight: maxHeight,
                                    maxBytes: maxBytes,
                                    bitmapInfo: analysis.pixels.bitmapInfo,
                                    colorSpace: analysis.pixels.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            guard created.append(analysis.pixels, rows: 0..<analysis.pixels.height, overlap: 0) else {
                return .limitReached
            }
            self.canvas = created
            self.previous = analysis
            self.latest = analysis
            return .started
        }

        // 尺寸变化（窗口缩放/换屏）：不写画布，也不推进参考帧 —— 尺寸恢复后还能接着拼
        guard let previous,
              previous.pixels.width == analysis.pixels.width,
              previous.pixels.height == analysis.pixels.height,
              canvas.pixelWidth == analysis.pixels.width else {
            return .sizeChanged
        }
        defer { latest = analysis }
        guard canvas.remainingRows >= minimumShift else { return .limitReached }

        var resolved = detectBands(previous: previous, current: analysis)
        resolved.confirmed = isBandCandidateStable(resolved)
        pendingBands = resolved

        // 画面没动：这里**不要求纹理配额**，否则大片纯色页连"没动"都判不出来
        if let identity = score(shift: 0, previous: previous, current: analysis, bands: resolved,
                                requiresInformativeRows: false),
           identity.score <= Self.identityThreshold {
            self.previous = analysis
            consecutiveFailures = 0
            didRealign = false
            bands = resolved
            return .unchanged
        }

        var used = resolved
        var match = bestMatch(previous: previous, current: analysis, bands: used)
        if match == nil, !used.isZero {
            // 固定区判定可能被个别帧误导（例如底部恰好有静止区域）：退回全屏匹配再试
            used = Bands()
            match = bestMatch(previous: previous, current: analysis, bands: used)
        }
        if match == nil {
            // 固定栏像素在帧间变化（半透明毛玻璃、宽进度条、跑马灯、视频预览）时，
            // "两帧像素一致"的判据会低估固定区。逐步扩大底部排除范围重试，
            // 命中后按新边界收窄合成范围（少截的部分会随内容上移在后续帧补回）。
            match = retryWithExpandedBottomExclusion(previous: previous, current: analysis,
                                                     resolved: resolved, used: &used)
        }
        guard let match else {
            consecutiveFailures += 1
            bands = resolved
            didRealign = false
            // 参考帧落后太多时（例如中间隔了一大片无特征内容），相邻两帧往往仍然能对齐。
            // 一旦确认"内容本身可对齐"，就立刻重锚到当前帧恢复采集，而不是等满 6 次。
            let adjacentMatches = latest.flatMap {
                bestMatch(previous: $0, current: analysis, bands: resolved)
            } != nil
            if (adjacentMatches && consecutiveFailures >= 2) || consecutiveFailures >= Self.realignThreshold {
                // 代价：从上次接上到现在的这段位移不计入长图（调用方通过 didRealign 提示用户）
                self.previous = analysis
                consecutiveFailures = 0
                didRealign = true
            }
            return .unmatched
        }

        // 位移低于最小位移：保留参考帧让位移累积（推进了的话小步滚动就永远攒不起来）
        guard match.shift >= minimumShift else {
            bands = resolved
            consecutiveFailures = 0
            didRealign = false
            return .unchanged
        }

        // 合成边界：固定底栏变大时同步下移，并把已经画进画布的固定栏行截掉
        let desiredBottom = analysis.pixels.height - used.bottom
        guard desiredBottom > 0 else {
            bands = resolved
            return .unmatched
        }
        if let current = compositeBottom {
            let shrink = current - desiredBottom
            if shrink > 0, shrink <= analysis.pixels.height / 2 {
                canvas.truncate(to: max(0, canvas.height - shrink))
                compositeBottom = desiredBottom
            }
            // desiredBottom > current（固定栏变小/消失）：保守沿用旧边界，避免行号错位
        } else {
            // 首帧整屏写入时含固定底栏：先截回内容区边界，底栏就不会出现在长图中间
            canvas.truncate(to: min(desiredBottom, canvas.height))
            compositeBottom = desiredBottom
        }
        guard let bottom = compositeBottom, bottom <= analysis.pixels.height else {
            bands = resolved
            return .unmatched
        }

        let rewind = min(seamOverlap, canvas.height)
        let start = bottom - match.shift - rewind
        guard start >= 0 else {
            bands = resolved
            return .unmatched
        }
        guard canvas.append(analysis.pixels, rows: start..<bottom, overlap: rewind) else {
            return .limitReached
        }

        lastShift = match.shift
        consecutiveFailures = 0
        didRealign = false
        bands = resolved
        self.previous = analysis
        return .appended(match.shift)
    }

    /// 逐步扩大底部排除范围重试（对付"像素在变的固定栏"）。命中即把增大后的底栏写回 `used`，
    /// 让合成边界同步收窄。
    private func retryWithExpandedBottomExclusion(previous: FrameAnalysis, current: FrameAnalysis,
                                                  resolved: Bands, used: inout Bands) -> Match? {
        let height = current.pixels.height
        for fraction in [0.08, 0.16, 0.25, 0.35] {
            var candidate = resolved
            candidate.bottom = max(candidate.bottom, Int((Double(height) * fraction).rounded()))
            guard (height - candidate.bottom) - candidate.top > Self.minimumMovableRows else { continue }
            if let attempt = bestMatch(previous: previous, current: current, bands: candidate) {
                used = candidate
                return attempt
            }
        }
        return nil
    }

    // MARK: - 固定区域检测

    /// 与上一帧逐行/逐列比对，得出顶部固定行数、底部固定行数、右侧固定列数。
    /// 阈值与既有实现一致（三通道绝对差均值 > 8 视为"变了"）。
    private func detectBands(previous: FrameAnalysis, current: FrameAnalysis) -> Bands {
        let old = previous.pixels
        let new = current.pixels
        guard old.width == new.width, old.height == new.height else { return Bands() }
        let height = new.height
        let width = new.width

        // 右缘：从最外列向内扫，找连续变化的列带（滚动条 / 悬浮控件边缘）
        var right = 0
        let maximumRight = max(4, min(40, width / 8))
        let rowStart = height * 2 / 10
        let rowEnd = max(rowStart + 1, height * 8 / 10)
        let rowStep = max(1, (rowEnd - rowStart) / 40)
        var offset = 0
        while offset < maximumRight {
            let column = width - 1 - offset
            guard column >= 0 else { break }
            var total = 0
            var count = 0
            var row = rowStart
            while row < rowEnd {
                total += new.channelDifference(old, row: row, column: column)
                count += 1
                row += rowStep
            }
            let mean = count > 0 ? Double(total) / Double(count) : .infinity
            if mean > Self.fixedDifferenceThreshold {
                right = offset + 1
            } else if right > 0 {
                break
            }
            offset += 1
        }

        let columnStep = max(1, width / 64)
        let lastColumn = max(1, width - right)
        /// 一行是否算"静止"。只看平均差会被稀疏动画骗到：固定栏里的输入框光标闪烁
        /// 只影响极少数像素，却足以让"从边界连续数静止行"提前中断，于是固定栏被判小、
        /// 底部那截又被追加进长图。因此补一条"变化像素占比"判据。
        func isStaticRow(_ row: Int) -> Bool {
            var total = 0
            var count = 0
            var changed = 0
            var column = 0
            while column < lastColumn {
                let difference = new.channelDifference(old, row: row, column: column)
                total += difference
                count += 1
                if difference > Int(Self.fixedDifferenceThreshold) { changed += 1 }
                column += columnStep
            }
            guard count > 0 else { return false }
            let mean = Double(total) / Double(count)
            let changedFraction = Double(changed) / Double(count)
            return mean <= Self.fixedDifferenceThreshold || changedFraction <= Self.fixedChangedFraction
        }

        // 固定栏 = 从边缘连续的**静止**行构成的游程。三点设计：
        // ① 不设"≤ 视口 1/4"这类硬上限 —— 底栏比 1/4 高时会在底栏内部切一刀，
        //    之后每次追加取到的都是底栏像素，页面内容再也进不了长图；
        // ② 允许游程内部有不超过 maximumStaticGap 行的不静止行 —— 固定栏里的大面积
        //    动画（进度条/跑马灯/缩略图）不应让整条固定栏失去识别；
        // ③ 游程之外至少要留 minimumMovableRows 行可动内容，两侧合计超预算时压回。
        //    已知取舍：底部若是一大片纯色**内容**，它与纯色固定栏在像素上无法区分，
        //    这里按固定栏处理（与 macshot 的 frozen rows 行为一致）—— 代价是长图末尾
        //    可能少若干行（结果仍是理想长图的前缀），不会出现重复或错位。
        let maximumBand = max(1, height - Self.minimumMovableRows)
        let maximumStaticGap = max(8, height / 50)
        func staticRunInnermostRow(fromBottom: Bool) -> Int? {
            var innermost: Int?
            var gap = 0
            var offset = 0
            while offset < maximumBand {
                let row = fromBottom ? height - 1 - offset : offset
                if isStaticRow(row) {
                    gap = 0
                    innermost = row
                } else {
                    gap += 1
                    if gap > maximumStaticGap { break }
                }
                offset += 1
            }
            return innermost
        }
        var top = staticRunInnermostRow(fromBottom: false).map { $0 + 1 } ?? 0
        var bottom = staticRunInnermostRow(fromBottom: true).map { height - $0 } ?? 0

        // 两侧合计吃掉几乎全部可动内容（整帧静止、或上下都是固定栏）：
        // 优先保留较大的一侧，把另一侧压回预算内，剩下的交给"画面没动"判定处理
        let budget = height - Self.minimumMovableRows
        if top + bottom > budget {
            if bottom >= top {
                bottom = max(0, budget - top)
            } else {
                top = max(0, budget - bottom)
            }
        }
        return Bands(top: top, bottom: bottom, right: right)
    }

    /// 固定区域是否连续两对帧结果一致（仅用于状态展示；实际使用始终以当次检测为准）
    private func isBandCandidateStable(_ candidate: Bands) -> Bool {
        guard let pending = pendingBands else { return false }
        return pending.top == candidate.top
            && pending.bottom == candidate.bottom
            && pending.right == candidate.right
    }

    // MARK: - 位移匹配

    private struct Match {
        let shift: Int
        let score: Double
        let runnerUp: Double
    }

    private func bestMatch(previous: FrameAnalysis, current: FrameAnalysis, bands: Bands) -> Match? {
        let height = current.pixels.height
        let contentHeight = (height - bands.bottom) - bands.top
        guard contentHeight > Self.minimumMovableRows else { return nil }
        let maximumShift = min(contentHeight - Self.minimumOverlap(contentHeight: contentHeight),
                               canvas?.remainingRows ?? maxHeight)
        guard maximumShift >= 1 else { return nil }

        // 滚动是连续动作：先在上一帧位移附近找，命中即返回（把全范围扫描降到常数级）
        if let last = lastShift, last >= minimumShift {
            let margin = max(48, last / 2)
            let lower = max(1, last - margin)
            let upper = min(maximumShift, last + margin)
            if lower <= upper,
               let near = scan(lower...upper, previous: previous, current: current, bands: bands),
               isConfident(near, relaxed: true) {
                return near
            }
        }
        guard let full = scan(1...maximumShift, previous: previous, current: current, bands: bands) else {
            return nil
        }
        return isConfident(full, relaxed: false) ? full : nil
    }

    private func isConfident(_ match: Match, relaxed: Bool) -> Bool {
        let threshold = relaxed ? matchThreshold * 0.75 : matchThreshold
        guard match.score <= threshold else { return false }
        return match.runnerUp >= match.score + uniquenessMargin
    }

    private func scan(_ range: ClosedRange<Int>, previous: FrameAnalysis,
                      current: FrameAnalysis, bands: Bands) -> Match? {
        var scores = [Double](repeating: .infinity, count: range.count)
        var best: (shift: Int, score: Double)?
        for shift in range {
            guard let value = score(shift: shift, previous: previous, current: current, bands: bands) else { continue }
            scores[shift - range.lowerBound] = value.score
            if best == nil || value.score < best!.score {
                best = (shift, value.score)
            }
        }
        guard let best else { return nil }
        // 次优只统计"非相邻"的候选：相邻位移天然分数接近，不构成歧义
        let adjacency = max(6, best.shift / 8)
        var runnerUp = Double.infinity
        for shift in range where abs(shift - best.shift) > adjacency {
            let value = scores[shift - range.lowerBound]
            if value < runnerUp { runnerUp = value }
        }
        return Match(shift: best.shift, score: best.score, runnerUp: runnerUp)
    }

    /// 单个候选位移的代价：逐行块签名差的**截尾加权均值**。
    /// 丢掉最差的 25% 行 —— 动画区、噪点、被漏掉的固定区域都会被丢掉，
    /// 而旧实现的全体均值会被它们整体抬过阈值。
    private func score(shift: Int, previous: FrameAnalysis, current: FrameAnalysis, bands: Bands,
                       requiresInformativeRows: Bool = true) -> (score: Double, informative: Int)? {
        let height = current.pixels.height
        let contentHeight = (height - bands.bottom) - bands.top
        let overlap = contentHeight - shift
        guard shift >= 0, overlap >= Self.minimumOverlap(contentHeight: contentHeight) else { return nil }

        let blocks = current.blocks
        guard blocks >= 1, previous.blocks == blocks else { return nil }
        let blockWidth = max(1, current.pixels.width / blocks)
        let excluded = bands.right > 0 ? min(blocks - 1, (bands.right + blockWidth - 1) / blockWidth) : 0
        let activeBlocks = blocks - excluded
        guard activeBlocks >= 1 else { return nil }

        let rowStride = max(1, overlap / Self.maximumRowSamples)
        var samples: [(cost: Double, weight: Double)] = []
        samples.reserveCapacity(Self.maximumRowSamples + 1)
        var informative = 0
        var index = 0
        while index < overlap {
            let currentRow = bands.top + index
            let previousRow = bands.top + index + shift
            var total = 0
            for block in 0..<activeBlocks {
                total += abs(Int(previous.signature[previousRow * blocks + block])
                             - Int(current.signature[currentRow * blocks + block]))
            }
            let cost = Double(total) / Double(activeBlocks)
            // 低纹理行（大片纯色）在任何位移下都"很像"，权重压低
            let texture = max(previous.texture[previousRow], current.texture[currentRow])
            let weight = min(1.0, Double(texture) / 8.0)
            if weight > 0.5 { informative += 1 }
            samples.append((cost, max(weight, 0.05)))
            index += rowStride
        }
        guard samples.count >= 4 else { return nil }
        // 大片纯色页：只要还有少量有纹理的行能定位（阈值放宽到 1/16）就允许匹配
        if requiresInformativeRows, informative < max(3, samples.count / 16) { return nil }

        samples.sort { $0.cost < $1.cost }
        let totalWeight = samples.reduce(0.0) { $0 + $1.weight }
        var keptWeight = 0.0
        var weightedCost = 0.0
        for sample in samples {
            if keptWeight >= totalWeight * 0.75 { break }
            weightedCost += sample.cost * sample.weight
            keptWeight += sample.weight
        }
        guard keptWeight > 0 else { return nil }
        return (weightedCost / keptWeight, informative)
    }
}

// MARK: - 帧分析

extension ScrollingStitcher {
    /// 每帧的行签名（横向切成若干块，每块取若干采样列的亮度均值）与行纹理。
    /// 位移匹配只在签名上做，成本与列数无关。
    struct FrameAnalysis {
        let pixels: FramePixels
        let blocks: Int
        let signature: [UInt8]
        let texture: [UInt8]

        init?(image: CGImage) {
            guard let pixels = FramePixels(image: image) else { return nil }
            let blockCount = max(1, min(ScrollingStitcher.maximumBlocks, pixels.width))
            let columnsPerBlock = max(1, pixels.width / blockCount)

            var blockColumns: [[Int]] = []
            blockColumns.reserveCapacity(blockCount)
            for block in 0..<blockCount {
                let lower = block * columnsPerBlock
                let upper = min(pixels.width, lower + columnsPerBlock)
                guard upper > lower else { continue }
                let columns = max(1, min(6, upper - lower))
                let step = max(1, (upper - lower) / columns)
                var list: [Int] = []
                var column = lower
                while column < upper {
                    list.append(column)
                    column += step
                }
                blockColumns.append(list)
            }
            let blocks = max(1, blockColumns.count)

            var signature = [UInt8](repeating: 0, count: pixels.height * blocks)
            var texture = [UInt8](repeating: 0, count: pixels.height)
            for row in 0..<pixels.height {
                for (block, columns) in blockColumns.enumerated() {
                    var sum = 0
                    for column in columns { sum += pixels.luminance(row: row, column: column) }
                    signature[row * blocks + block] = UInt8(clamping: sum / columns.count)
                }
                if blocks >= 2 {
                    var variation = 0
                    for block in 0..<(blocks - 1) {
                        variation += abs(Int(signature[row * blocks + block + 1]) - Int(signature[row * blocks + block]))
                    }
                    texture[row] = UInt8(clamping: variation / (blocks - 1))
                }
            }

            self.pixels = pixels
            self.blocks = blocks
            self.signature = signature
            self.texture = texture
        }
    }
}
