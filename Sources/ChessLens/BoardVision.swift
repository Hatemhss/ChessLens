import CoreGraphics
import Foundation

/// A screenshot represented in chess-square order (a1 = 0, h8 = 63).
/// These appearances are session-local: only a confirmed position supplies their labels.
struct BoardObservation: Sendable {
    let squares: [[Float]]
}

/// Removes square backgrounds before comparing pieces. In particular, a yellow last-move
/// square should look like the same piece on a green or cream square, not a new piece.
struct BoardVision {
    private static let rasterSize = 48
    private static let featureSize = 24

    func observe(image: CGImage, whiteAtBottom: Bool) -> BoardObservation? {
        guard image.width >= 64, image.height >= 64 else { return nil }
        var squares = Array(repeating: [Float](), count: 64)
        for row in 0..<8 {
            for column in 0..<8 {
                // Fractional boundaries avoid drifting a pixel per square on scaled boards.
                let left = column * image.width / 8
                let top = row * image.height / 8
                let right = (column + 1) * image.width / 8
                let bottom = (row + 1) * image.height / 8
                guard let square = image.cropping(to: CGRect(
                    x: left, y: top, width: right - left, height: bottom - top
                )), let feature = appearance(square) else { return nil }
                let file = whiteAtBottom ? column : 7 - column
                let rank = whiteAtBottom ? 7 - row : row
                squares[rank * 8 + file] = feature
            }
        }
        return BoardObservation(squares: squares)
    }

    /// Mean squared appearance error. Zero means identical; invalid features never match.
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 1 }
        var sum = 0.0
        for index in lhs.indices {
            let difference = Double(lhs[index] - rhs[index])
            sum += difference * difference
        }
        return sum / Double(lhs.count)
    }

    private func appearance(_ image: CGImage) -> [Float]? {
        let size = Self.rasterSize
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return nil }

        // Estimate the dominant border color rather than averaging corners: corners often
        // contain board coordinates or the website's move-quality/book badge.
        var bins = [Int: [Int]]()
        for y in 0..<size {
            for x in 0..<size {
                let atBorder = x < 3 || x >= size - 3 || y < 3 || y >= size - 3
                guard atBorder, !isCorner(x, y) else { continue }
                let index = (y * size + x) * 4
                let key = (Int(bytes[index]) / 16) * 256
                    + (Int(bytes[index + 1]) / 16) * 16 + Int(bytes[index + 2]) / 16
                bins[key, default: []].append(index)
            }
        }
        guard let backgroundSamples = bins.max(by: { $0.value.count < $1.value.count })?.value else {
            return nil
        }
        var background = [Float](repeating: 0, count: 3)
        for index in backgroundSamples {
            for channel in 0..<3 { background[channel] += Float(bytes[index + channel]) / 255 }
        }
        for channel in 0..<3 { background[channel] /= Float(backgroundSamples.count) }

        // Flood from the outside through background-colored pixels. Closed piece outlines
        // retain their interior, even when a white piece nearly matches a cream square.
        var passable = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let pixel = y * size + x
                var error: Float = 0
                for channel in 0..<3 {
                    let delta = Float(bytes[pixel * 4 + channel]) / 255 - background[channel]
                    error += delta * delta
                }
                // Mask corners only after filling: erasing a piece's broad base here
                // would open its contour and leak background into a light piece.
                passable[pixel] = error / 3 < 0.011
            }
        }
        var exterior = [Bool](repeating: false, count: size * size)
        var queue = [Int]()
        func seed(_ index: Int) {
            if passable[index], !exterior[index] {
                exterior[index] = true
                queue.append(index)
            }
        }
        for coordinate in 0..<size {
            seed(coordinate)
            seed((size - 1) * size + coordinate)
            seed(coordinate * size)
            seed(coordinate * size + size - 1)
        }
        var cursor = 0
        while cursor < queue.count {
            let pixel = queue[cursor]
            cursor += 1
            let x = pixel % size
            let y = pixel / size
            if x > 0 { seed(pixel - 1) }
            if x + 1 < size { seed(pixel + 1) }
            if y > 0 { seed(pixel - size) }
            if y + 1 < size { seed(pixel + size) }
        }

        // Fixed output slots avoid allocating a three-element color array and a
        // mapped temporary for every cell (36,864 cells per board observation).
        var feature = [Float](repeating: 0, count: Self.featureSize * Self.featureSize * 4)
        for y in 0..<Self.featureSize {
            for x in 0..<Self.featureSize {
                var occupancy: Float = 0
                var red: Float = 0, green: Float = 0, blue: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sourceX = x * 2 + dx
                        let sourceY = y * 2 + dy
                        let pixel = sourceY * size + sourceX
                        guard !isCorner(sourceX, sourceY), !exterior[pixel] else { continue }
                        occupancy += 0.25
                        red += Float(bytes[pixel * 4]) / 255 * 0.25
                        green += Float(bytes[pixel * 4 + 1]) / 255 * 0.25
                        blue += Float(bytes[pixel * 4 + 2]) / 255 * 0.25
                    }
                }
                // Shape and actual foreground color are both retained; subtracting background
                // RGB would make the same white pawn change identity as it moves squares.
                let index = (y * Self.featureSize + x) * 4
                feature[index] = occupancy
                feature[index + 1] = red * 0.75
                feature[index + 2] = green * 0.75
                feature[index + 3] = blue * 0.75
            }
        }
        return feature
    }

    private func isCorner(_ x: Int, _ y: Int) -> Bool {
        let edge = 17
        return (x < edge || x >= Self.rasterSize - edge)
            && (y < edge || y >= Self.rasterSize - edge)
    }
}
