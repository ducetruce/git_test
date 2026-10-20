import NarwalKit
import SwiftUI

/// Top-down drawings of furniture, like a floor plan. The back of the piece
/// (a sofa's back, a bed's headboard) is the top edge before rotation.
struct FurnitureArt {
    /// The filled silhouette.
    var base = Path()
    /// Lines drawn over it: cushions, pillows, doors, burners.
    var detail = Path()

    init(_ item: Furniture, in r: CGRect) {
        let w = r.width, h = r.height, m = min(w, h)
        switch item.type {
        case 1, 2, 3: bed(r, pillows: item.type == 2 ? 2 : 1, cot: item.type == 3)
        case 14: sofa(r, seats: max(2, min(4, Int((w / h).rounded() + 1))))
        case 13, 16: sofa(r, seats: 1)
        case 15: lSofa(r, mirrored: item.isMirrored)
        case 30: uSofa(r)
        case 17:
            base.addRoundedRect(in: r.insetBy(dx: w * 0.1, dy: h * 0.1), cornerSize: corner(m * 0.12))
            detail.addRect(CGRect(x: r.minX + w * 0.1, y: r.minY + h * 0.1, width: w * 0.8, height: h * 0.18))
        case 18:
            base.addEllipse(in: r.insetBy(dx: w * 0.1, dy: h * 0.1))
            detail.addEllipse(in: r.insetBy(dx: w * 0.3, dy: h * 0.3))
        case 4: diningTable(r)
        case 5: roundTable(r)
        case 7:
            base.addEllipse(in: r)
            detail.addEllipse(in: r.insetBy(dx: w * 0.15, dy: h * 0.15))
        case 6, 8, 9, 31:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.1))
            detail.addRoundedRect(in: r.insetBy(dx: m * 0.15, dy: m * 0.15), cornerSize: corner(m * 0.05))
        case 10, 11, 12: cabinet(r, doors: max(1, min(4, Int((w / max(h, 1)).rounded()))) )
        case 22:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.12))
            detail.addRect(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.18))
            detail.addEllipse(in: CGRect(x: r.midX - m * 0.3, y: r.midY - m * 0.2, width: m * 0.6, height: m * 0.6))
        case 23:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.08))
            detail.addRect(CGRect(x: r.minX, y: r.maxY - h * 0.15, width: w, height: h * 0.15))
            detail.move(to: CGPoint(x: r.midX, y: r.maxY - h * 0.15))
            detail.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        case 24:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.15))
            for i in 1...3 { line(r, fromX: 0.12, toX: 0.88, y: 0.25 + 0.15 * CGFloat(i)) }
        case 25:
            base.addEllipse(in: r)
            for i in 0..<3 {
                let a = CGFloat(i) * 2 * .pi / 3
                detail.move(to: CGPoint(x: r.midX, y: r.midY))
                detail.addLine(to: CGPoint(x: r.midX + cos(a) * w * 0.4, y: r.midY + sin(a) * h * 0.4))
            }
        case 26: plant(r)
        case 27:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.1))
            detail.addRoundedRect(in: r.insetBy(dx: m * 0.2, dy: m * 0.2), cornerSize: corner(m * 0.05))
        case 28: toilet(r)
        case 29, 32:
            base.addRoundedRect(in: r, cornerSize: corner(item.type == 32 ? m * 0.45 : m * 0.08))
            let keys = CGRect(x: r.minX, y: r.maxY - h * 0.25, width: w, height: h * 0.25)
            detail.addRect(keys)
            for i in 1..<12 {
                let x = keys.minX + keys.width * CGFloat(i) / 12
                detail.move(to: CGPoint(x: x, y: keys.minY))
                detail.addLine(to: CGPoint(x: x, y: keys.maxY))
            }
        case 33:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.12))
            detail.addEllipse(in: CGRect(x: r.minX + w * 0.2, y: r.minY + h * 0.25, width: w * 0.6, height: h * 0.6))
        case 34:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.08))
            for (fx, fy) in [(0.28, 0.3), (0.72, 0.3), (0.28, 0.72), (0.72, 0.72)] {
                let c = CGPoint(x: r.minX + w * fx, y: r.minY + h * fy)
                detail.addEllipse(in: CGRect(x: c.x - m * 0.16, y: c.y - m * 0.16, width: m * 0.32, height: m * 0.32))
            }
        case 20:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.3))
            detail.addEllipse(in: CGRect(x: r.minX + w * 0.08, y: r.midY - m * 0.3, width: w * 0.38, height: m * 0.6))
            detail.addEllipse(in: CGRect(x: r.midX + w * 0.04, y: r.midY - m * 0.3, width: w * 0.38, height: m * 0.6))
        case 19, 21, 75, 76:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.25))
            detail.addEllipse(in: r.insetBy(dx: w * 0.2, dy: h * 0.2))
        default:
            base.addRoundedRect(in: r, cornerSize: corner(m * 0.12))
        }
    }

    private func corner(_ c: CGFloat) -> CGSize { CGSize(width: c, height: c) }

    private mutating func line(_ r: CGRect, fromX: CGFloat, toX: CGFloat, y: CGFloat) {
        detail.move(to: CGPoint(x: r.minX + r.width * fromX, y: r.minY + r.height * y))
        detail.addLine(to: CGPoint(x: r.minX + r.width * toX, y: r.minY + r.height * y))
    }

    private mutating func bed(_ r: CGRect, pillows: Int, cot: Bool) {
        let w = r.width, h = r.height
        base.addRoundedRect(in: r, cornerSize: corner(min(w, h) * 0.06))
        detail.addRect(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.07))
        let gap = w * 0.06
        let pw = (w - gap * CGFloat(pillows + 1)) / CGFloat(pillows)
        for i in 0..<pillows {
            let x = r.minX + gap + CGFloat(i) * (pw + gap)
            detail.addRoundedRect(in: CGRect(x: x, y: r.minY + h * 0.11, width: pw, height: h * 0.15),
                                  cornerSize: corner(h * 0.04))
        }
        // Duvet with its folded-back edge.
        detail.addRect(CGRect(x: r.minX, y: r.minY + h * 0.34, width: w, height: h * 0.66))
        line(r, fromX: 0, toX: 1, y: 0.42)
        if cot {
            for i in 1..<6 { line(r, fromX: CGFloat(i) / 6 - 0.01, toX: CGFloat(i) / 6 + 0.01, y: 0.04) }
        }
    }

    private mutating func sofa(_ r: CGRect, seats: Int) {
        let w = r.width, h = r.height
        base.addRoundedRect(in: r, cornerSize: corner(min(w, h) * 0.15))
        let arm = min(w * 0.14, h * 0.3)
        let back = h * 0.28
        detail.addRoundedRect(in: CGRect(x: r.minX + arm, y: r.minY + back, width: w - 2 * arm, height: h - back - h * 0.06),
                              cornerSize: corner(h * 0.06))
        line(r, fromX: 0, toX: 1, y: 0.28)
        let seatW = (w - 2 * arm) / CGFloat(seats)
        for i in 1..<max(seats, 1) {
            let x = r.minX + arm + seatW * CGFloat(i)
            detail.move(to: CGPoint(x: x, y: r.minY + back))
            detail.addLine(to: CGPoint(x: x, y: r.maxY - h * 0.06))
        }
    }

    private mutating func lSofa(_ r: CGRect, mirrored: Bool) {
        let w = r.width, h = r.height
        let depth = h * 0.45, chaise = w * 0.35
        let chaiseX = mirrored ? r.minX : r.maxX - chaise
        var shape = Path()
        shape.addRect(CGRect(x: r.minX, y: r.minY, width: w, height: depth))
        shape.addRect(CGRect(x: chaiseX, y: r.minY, width: chaise, height: h))
        base.addPath(shape)
        // Back along the top, seat edge, chaise cushion.
        detail.move(to: CGPoint(x: r.minX, y: r.minY + depth * 0.4))
        detail.addLine(to: CGPoint(x: r.maxX, y: r.minY + depth * 0.4))
        let seats = 3
        let runStart = mirrored ? r.minX + chaise : r.minX
        let runW = w - chaise
        for i in 1..<seats {
            let x = runStart + runW * CGFloat(i) / CGFloat(seats)
            detail.move(to: CGPoint(x: x, y: r.minY + depth * 0.4))
            detail.addLine(to: CGPoint(x: x, y: r.minY + depth))
        }
        detail.move(to: CGPoint(x: chaiseX, y: r.minY + depth))
        detail.addLine(to: CGPoint(x: chaiseX + chaise, y: r.minY + depth))
    }

    private mutating func uSofa(_ r: CGRect) {
        let w = r.width, h = r.height
        let depth = h * 0.4, side = w * 0.25
        base.addRect(CGRect(x: r.minX, y: r.minY, width: w, height: depth))
        base.addRect(CGRect(x: r.minX, y: r.minY, width: side, height: h))
        base.addRect(CGRect(x: r.maxX - side, y: r.minY, width: side, height: h))
        line(r, fromX: 0, toX: 1, y: 0.16)
        detail.move(to: CGPoint(x: r.minX + side * 0.4, y: r.minY + h * 0.16))
        detail.addLine(to: CGPoint(x: r.minX + side * 0.4, y: r.maxY))
        detail.move(to: CGPoint(x: r.maxX - side * 0.4, y: r.minY + h * 0.16))
        detail.addLine(to: CGPoint(x: r.maxX - side * 0.4, y: r.maxY))
    }

    private mutating func diningTable(_ r: CGRect) {
        let w = r.width, h = r.height
        let table = r.insetBy(dx: w * 0.12, dy: h * 0.22)
        base.addRoundedRect(in: table, cornerSize: corner(min(w, h) * 0.05))
        let perSide = max(1, min(4, Int((table.width / max(table.height, 1) * 1.5).rounded())))
        let cw = table.width / CGFloat(perSide) * 0.6
        let ch = h * 0.16
        for i in 0..<perSide {
            let cx = table.minX + table.width * (CGFloat(i) + 0.5) / CGFloat(perSide)
            for y in [r.minY + h * 0.03, r.maxY - h * 0.03 - ch] {
                base.addRoundedRect(in: CGRect(x: cx - cw / 2, y: y, width: cw, height: ch), cornerSize: corner(ch * 0.25))
            }
        }
    }

    private mutating func roundTable(_ r: CGRect) {
        let w = r.width, h = r.height
        base.addEllipse(in: r.insetBy(dx: w * 0.2, dy: h * 0.2))
        let c = min(w, h) * 0.17
        for (fx, fy) in [(0.5, 0.1), (0.5, 0.9), (0.1, 0.5), (0.9, 0.5)] {
            base.addRoundedRect(in: CGRect(x: r.minX + w * fx - c / 2, y: r.minY + h * fy - c / 2, width: c, height: c),
                                cornerSize: corner(c * 0.25))
        }
    }

    private mutating func cabinet(_ r: CGRect, doors: Int) {
        let w = r.width, h = r.height
        base.addRoundedRect(in: r, cornerSize: corner(min(w, h) * 0.06))
        for i in 1..<max(doors, 1) {
            let x = r.minX + w * CGFloat(i) / CGFloat(doors)
            detail.move(to: CGPoint(x: x, y: r.minY))
            detail.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        // Front edge.
        line(r, fromX: 0, toX: 1, y: 0.82)
    }

    private mutating func toilet(_ r: CGRect) {
        let w = r.width, h = r.height
        base.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.3), cornerSize: corner(h * 0.05))
        base.addEllipse(in: CGRect(x: r.minX + w * 0.12, y: r.minY + h * 0.22, width: w * 0.76, height: h * 0.76))
        detail.addEllipse(in: CGRect(x: r.minX + w * 0.27, y: r.minY + h * 0.38, width: w * 0.46, height: h * 0.48))
    }

    private mutating func plant(_ r: CGRect) {
        let w = r.width, h = r.height
        base.addEllipse(in: r.insetBy(dx: w * 0.05, dy: h * 0.05))
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let c = CGPoint(x: r.midX + cos(a) * w * 0.22, y: r.midY + sin(a) * h * 0.22)
            detail.addEllipse(in: CGRect(x: c.x - w * 0.14, y: c.y - h * 0.14, width: w * 0.28, height: h * 0.28))
        }
    }
}

/// One piece of furniture, drawn at its size and rotated into place.
struct FurnitureView: View {
    let item: Furniture
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let art = FurnitureArt(item, in: CGRect(origin: .zero, size: size).insetBy(dx: lineWidth, dy: lineWidth))
            context.fill(art.base, with: .color(.white.opacity(0.85)))
            context.stroke(art.base, with: .color(MapPalette.furnitureLine), lineWidth: lineWidth)
            context.stroke(art.detail, with: .color(MapPalette.furnitureLine.opacity(0.7)), lineWidth: lineWidth * 0.75)
        }
        .accessibilityLabel(item.name)
    }
}
