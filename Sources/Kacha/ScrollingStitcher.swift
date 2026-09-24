import CoreGraphics

struct ScrollingStitcher {
    enum Result: Equatable {
        case started
        case appended(Int)
        case unchanged
        case unmatched
        case limitReached
    }

    private(set) var image: CGImage?
    private var lastFrame: CGImage?
    private let maxHeight = 24_000
    private let maxBytes = 160_000_000

    mutating func append(_ frame: CGImage) -> Result {
        guard let previous = lastFrame, let image else {
            self.image = frame
            lastFrame = frame
            return .started
        }
        guard frame.width == previous.width, frame.height == previous.height,
              let previousPixels = pixels(of: previous), let currentPixels = pixels(of: frame) else {
            return .unmatched
        }
        let width = frame.width
        let height = frame.height
        let columns = stride(from: min(4, width / 2), to: width, by: max(1, width / 32)).map { $0 }
        guard !columns.isEmpty else { return .unmatched }
        var fixedHeader = 0
        for y in 0..<(height / 3) {
            let distance = columns.reduce(0) { sum, x in
                let offset = (y * width + x) * 4
                return sum + abs(Int(previousPixels[offset]) - Int(currentPixels[offset]))
            }
            guard distance < columns.count * 3 else { break }
            fixedHeader += 1
        }

        func difference(at shift: Int) -> Double {
            let overlap = height - shift
            guard overlap - fixedHeader >= height / 8 else { return .infinity }
            let rowStep = max(1, (overlap - fixedHeader) / 48)
            var total: Double = 0
            var count = 0
            for y in stride(from: fixedHeader, to: overlap, by: rowStep) {
                for x in columns {
                    let a = ((y + shift) * width + x) * 4
                    let b = (y * width + x) * 4
                    for channel in 0..<3 {
                        total += Double(abs(Int(previousPixels[a + channel]) - Int(currentPixels[b + channel])))
                        count += 1
                    }
                }
            }
            return total / Double(count)
        }

        if difference(at: 0) < 2 { return .unchanged }
        let maximumShift = min(height * 3 / 4, maxHeight - image.height)
        guard maximumShift >= 4 else { return .limitReached }
        var bestShift = 0
        var bestScore = Double.infinity
        for shift in 4...maximumShift {
            let score = difference(at: shift)
            if score < bestScore {
                bestScore = score
                bestShift = shift
            }
        }
        guard bestScore < 8 else { return .unmatched }
        let newHeight = image.height + bestShift
        guard newHeight <= maxHeight, width * newHeight * 4 <= maxBytes,
              let context = CGContext(data: nil, width: width, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .limitReached
        }
        context.draw(image, in: CGRect(x: 0, y: bestShift, width: width, height: image.height))
        if let suffix = frame.cropping(to: CGRect(x: 0, y: height - bestShift, width: width, height: bestShift)) {
            context.draw(suffix, in: CGRect(x: 0, y: 0, width: width, height: bestShift))
        } else {
            return .unmatched
        }
        guard let result = context.makeImage() else { return .unmatched }
        self.image = result
        lastFrame = frame
        return .appended(bestShift)
    }

    private func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
