import Foundation

/// 在复制帧和创建 Task 之前限流：整个应用管线最多一帧在途，忙时丢弃新帧。
/// NSLock 保护跨 SCK 回调队列、拼接 actor 与 MainActor 使用的状态。
final class ScrollingFrameAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var closed = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !busy else { return false }
        busy = true
        return true
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        busy = false
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}
