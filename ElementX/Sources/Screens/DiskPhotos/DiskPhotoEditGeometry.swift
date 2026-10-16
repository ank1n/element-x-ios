// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import UIKit

struct DiskPhotoEditObject {
    let index: Int
    let bounds: CGRect
    let originalBounds: CGRect
    let transform: CGAffineTransform

    func delta(_ delta: CGPoint) -> CGPoint {
        let inverse = transform.inverted()
        let projected = CGPoint(x: inverse.a * delta.x + inverse.c * delta.y, y: inverse.b * delta.x + inverse.d * delta.y)
        return CGPoint(x: max(-originalBounds.minX, min(max(0, 1 - originalBounds.maxX), projected.x)),
                       y: max(-originalBounds.minY, min(max(0, 1 - originalBounds.maxY), projected.y)))
    }
}

enum DiskPhotoEditGeometry {
    static func objects(size: CGSize, operations: [DiskPhotoEditOperation]) -> [DiskPhotoEditObject] {
        var current = size
        var result: [DiskPhotoEditObject] = []
        for (index, op) in operations.enumerated() {
            var bounds: CGRect?
            switch op {
            case let .arrow(a, b, _), let .rectangle(a, b, _), let .redact(a, b):
                bounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            case let .text(at, text, _, size):
                let font = UIFont.systemFont(ofSize: max(8, min(current.width, current.height) * CGFloat(size)), weight: .semibold)
                let measured = (text as NSString).size(withAttributes: [.font: font])
                bounds = CGRect(x: at.x, y: at.y, width: measured.width / current.width, height: measured.height / current.height)
            default: break
            }
            if let bounds {
                var transform = CGAffineTransform.identity
                var stage = current
                for next in operations.dropFirst(index + 1) {
                    var step = CGAffineTransform.identity
                    switch next {
                    case let .rotate(clockwise):
                        step = clockwise ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
                            : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
                    case let .flip(vertical):
                        step = vertical ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
                            : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
                    case let .crop(from, to):
                        let box = DiskPhotoEditRenderer.cropBox(stage, from: from, to: to)
                        step = CGAffineTransform(a: stage.width / box.width, b: 0, c: 0, d: stage.height / box.height,
                                                 tx: -box.minX / box.width, ty: -box.minY / box.height)
                    default: break
                    }
                    transform = transform.concatenating(step)
                    stage = DiskPhotoEditRenderer.size(stage, operations: [next])
                }
                result.append(DiskPhotoEditObject(index: index, bounds: bounds.applying(transform), originalBounds: bounds, transform: transform))
            }
            current = DiskPhotoEditRenderer.size(current, operations: [op])
        }
        return result
    }

    static func moved(_ operation: DiskPhotoEditOperation, by delta: CGPoint) -> DiskPhotoEditOperation {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + delta.x, y: p.y + delta.y)
        }
        switch operation {
        case let .text(at, text, color, size): return .text(at: shift(at), text: text, color: color, size: size)
        case let .arrow(a, b, color): return .arrow(from: shift(a), to: shift(b), color: color)
        case let .rectangle(a, b, color): return .rectangle(from: shift(a), to: shift(b), color: color)
        case let .redact(a, b): return .redact(from: shift(a), to: shift(b))
        default: return operation
        }
    }
}
