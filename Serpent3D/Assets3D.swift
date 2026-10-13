import SceneKit
import CoreGraphics
#if os(macOS)
import AppKit
typealias PColor = NSColor
#else
import UIKit
typealias PColor = UIColor
#endif

// MARK: - Vector math

func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
func * (a: SCNVector3, k: Float) -> SCNVector3 {
    SCNVector3(a.x * SCNFloat(k), a.y * SCNFloat(k), a.z * SCNFloat(k))
}
#if os(macOS)
typealias SCNFloat = CGFloat
#else
typealias SCNFloat = Float
#endif

// MARK: - Materials

enum Mat {
    static func pbr(_ c: PColor, rough: CGFloat, metal: CGFloat = 0, emission: PColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = metal
        if let e = emission { m.emission.contents = e }
        return m
    }
    static let stone: SCNMaterial = {
        let m = pbr(.white, rough: 0.85)
        m.diffuse.contents = Tex.noise(PColor(red: 0.55, green: 0.52, blue: 0.48, alpha: 1), PColor(red: 0.70, green: 0.67, blue: 0.62, alpha: 1))
        return m
    }()
    static let wood: SCNMaterial = {
        let m = pbr(.white, rough: 0.7)
        m.diffuse.contents = Tex.crate()
        return m
    }()
}

// MARK: - Procedural textures

enum Tex {
    static func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static func checker() -> CGImage {
        image(64, 64) { c in
            c.setFillColor(PColor(red: 0.42, green: 0.70, blue: 0.30, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            c.setFillColor(PColor(red: 0.36, green: 0.63, blue: 0.26, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 32, height: 32)); c.fill(CGRect(x: 32, y: 32, width: 32, height: 32))
        }
    }

    static func sky() -> CGImage {
        image(4, 256) { c in
            let cols = [PColor(red: 0.98, green: 0.93, blue: 0.80, alpha: 1).cgColor,
                        PColor(red: 0.62, green: 0.80, blue: 0.95, alpha: 1).cgColor,
                        PColor(red: 0.25, green: 0.50, blue: 0.85, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.45, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        }
    }

    static func noise(_ a: PColor, _ b: PColor) -> CGImage {
        image(128, 128) { c in
            c.setFillColor(a.cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            var g = SystemRandomNumberGenerator()
            for _ in 0..<500 {
                c.setFillColor(b.withAlphaComponent(CGFloat.random(in: 0.2...0.8, using: &g)).cgColor)
                let s = CGFloat.random(in: 2...9, using: &g)
                c.fillEllipse(in: CGRect(x: .random(in: 0...128, using: &g), y: .random(in: 0...128, using: &g), width: s, height: s))
            }
        }
    }

    static func crate() -> CGImage {
        image(128, 128) { c in
            c.setFillColor(PColor(red: 0.62, green: 0.42, blue: 0.22, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            c.setStrokeColor(PColor(red: 0.40, green: 0.25, blue: 0.12, alpha: 1).cgColor)
            c.setLineWidth(3)
            for y in stride(from: 16, to: 128, by: 24) { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 128, y: y)) }
            c.strokePath()
            c.setLineWidth(14); c.stroke(CGRect(x: 7, y: 7, width: 114, height: 114))
            c.setLineWidth(12); c.move(to: CGPoint(x: 10, y: 10)); c.addLine(to: CGPoint(x: 118, y: 118)); c.strokePath()
        }
    }

    static let dot: CGImage = image(32, 32) { c in
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [PColor.white.cgColor, PColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: 16, y: 16), startRadius: 0, endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
    }
}

extension PColor {
    func blended(_ k: CGFloat) -> PColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (usingColorSpaceIfNeeded()).getRed(&r, green: &g, blue: &b, alpha: &a)
        return PColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
    }
    func usingColorSpaceIfNeeded() -> PColor {
        #if os(macOS)
        return usingColorSpace(.deviceRGB) ?? self
        #else
        return self
        #endif
    }
}

// MARK: - Detailed surface textures (diffuse + height maps; SceneKit turns grayscale normal maps into bumps)

extension Tex {
    /// Overlapping rounded scales. `height` returns the bump map instead of the albedo.
    static func scales(height: Bool) -> CGImage {
        image(128, 128) { c in
            c.setFillColor(PColor(white: height ? 0 : 0.55, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            let s: CGFloat = 16
            for row in -1...9 {
                for col in -1...9 {
                    let x = CGFloat(col) * s + (row % 2 == 0 ? 0 : s / 2), y = CGFloat(row) * s * 0.75
                    let r = CGRect(x: x - s * 0.55, y: y - s * 0.55, width: s * 1.1, height: s * 1.1)
                    let top = PColor(white: height ? 1 : 1.0, alpha: 1).cgColor, edge = PColor(white: height ? 0.15 : 0.6, alpha: 1).cgColor
                    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, edge] as CFArray, locations: [0, 1])!
                    c.saveGState(); c.addEllipse(in: r); c.clip()
                    c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y + s * 0.2), startRadius: 0,
                                         endCenter: CGPoint(x: x, y: y), endRadius: s * 0.6, options: [.drawsAfterEndLocation])
                    c.restoreGState()
                }
            }
        }
    }

    static func bricks(height: Bool) -> CGImage {
        image(128, 128) { c in
            c.setFillColor(PColor(white: height ? 0 : 0.78, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            var g = SystemRandomNumberGenerator()
            let bh: CGFloat = 32, bw: CGFloat = 64
            for row in 0..<4 {
                for col in -1..<3 {
                    let x = CGFloat(col) * bw + (row % 2 == 0 ? 0 : bw / 2), y = CGFloat(row) * bh
                    let rect = CGRect(x: x + 3, y: y + 3, width: bw - 6, height: bh - 6)
                    if height {
                        c.setFillColor(PColor(white: 0.85, alpha: 1).cgColor)
                    } else {
                        let v = CGFloat.random(in: -0.06...0.06, using: &g)
                        c.setFillColor(PColor(red: 0.72 + v, green: 0.40 + v, blue: 0.30 + v, alpha: 1).cgColor)
                    }
                    c.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)); c.fillPath()
                    for _ in 0..<14 {   // speckles / pits
                        c.setFillColor(PColor(white: height ? 0.6 : 0.3, alpha: 0.35).cgColor)
                        let p = CGPoint(x: .random(in: rect.minX...rect.maxX, using: &g), y: .random(in: rect.minY...rect.maxY, using: &g))
                        c.fillEllipse(in: CGRect(x: p.x, y: p.y, width: 3, height: 3))
                    }
                }
            }
        }
    }

    /// One floor cell per texture repeat: a slightly domed tile with grout.
    static func tile(height: Bool, dark: Bool) -> CGImage {
        image(64, 64) { c in
            c.setFillColor(PColor(white: height ? 0 : 0.25, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let base: PColor = height ? PColor(white: 0.9, alpha: 1)
                : dark ? PColor(red: 0.30, green: 0.58, blue: 0.22, alpha: 1) : PColor(red: 0.42, green: 0.72, blue: 0.30, alpha: 1)
            c.setFillColor(base.cgColor)
            c.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2, width: 60, height: 60), cornerWidth: 6, cornerHeight: 6, transform: nil)); c.fillPath()
            var g = SystemRandomNumberGenerator()
            for _ in 0..<40 {   // grass blades / texture
                c.setStrokeColor(PColor(white: height ? 1 : (dark ? 0.2 : 0.85), alpha: height ? 0.5 : 0.18).cgColor)
                c.setLineWidth(1.5)
                let x = CGFloat.random(in: 6...58, using: &g), y = CGFloat.random(in: 6...58, using: &g)
                c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + .random(in: -2...2, using: &g), y: y + 4)); c.strokePath()
            }
        }
    }

    /// 2x2 checker of tiles so the floor repeats every two cells.
    static func floor(height: Bool) -> CGImage {
        let a = tile(height: height, dark: false), b = tile(height: height, dark: true)
        return image(128, 128) { c in
            c.draw(a, in: CGRect(x: 0, y: 0, width: 64, height: 64)); c.draw(a, in: CGRect(x: 64, y: 64, width: 64, height: 64))
            c.draw(height ? a : b, in: CGRect(x: 64, y: 0, width: 64, height: 64)); c.draw(height ? a : b, in: CGRect(x: 0, y: 64, width: 64, height: 64))
        }
    }
}

extension Mat {
    static func snake(_ color: PColor) -> SCNMaterial {
        let m = pbr(.white, rough: 0.35)
        m.diffuse.contents = scaleAlbedo
        m.multiply.contents = color
        m.normal.contents = scaleHeight
        m.normal.intensity = 0.8
        m.clearCoat.contents = 0.5
        for p in [m.diffuse, m.normal] { p.wrapS = .repeat; p.wrapT = .repeat; p.contentsTransform = SCNMatrix4MakeScale(2, 2, 1) }
        return m
    }
    static let scaleAlbedo = Tex.scales(height: false)
    static let scaleHeight = Tex.scales(height: true)

    static let brick: SCNMaterial = {
        let m = pbr(.white, rough: 0.8)
        m.diffuse.contents = Tex.bricks(height: false)
        m.normal.contents = Tex.bricks(height: true)
        m.normal.intensity = 1
        return m
    }()
    static let brickTop: SCNMaterial = {
        let m = pbr(PColor(red: 0.62, green: 0.60, blue: 0.56, alpha: 1), rough: 0.85)
        m.diffuse.contents = Tex.noise(PColor(red: 0.60, green: 0.58, blue: 0.54, alpha: 1), PColor(red: 0.72, green: 0.70, blue: 0.66, alpha: 1))
        return m
    }()
}

// MARK: - Scenery around the arena

enum Scenery {
    static func build(arenaSize: Int) -> SCNNode {
        let root = SCNNode()
        var rng = SeededRNG(seed: 7)
        let half = Float(arenaSize) / 2
        let trunk = Mat.pbr(PColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1), rough: 0.9)
        let leaves = [PColor(red: 0.18, green: 0.50, blue: 0.20, alpha: 1), PColor(red: 0.25, green: 0.60, blue: 0.22, alpha: 1),
                      PColor(red: 0.14, green: 0.42, blue: 0.24, alpha: 1)].map { Mat.pbr($0, rough: 0.75) }
        let rock = Mat.stone
        let petals = [PColor.systemRed, .systemYellow, .white, .systemPink, .systemPurple].map { Mat.pbr($0, rough: 0.5) }

        for _ in 0..<150 {
            // Position in a ring outside the walls.
            let side = Int.random(in: 0..<4, using: &rng)
            let along = Float.random(in: -half - 7...half + 7, using: &rng)
            let out = half + 0.6 + pow(Float.random(in: 0...1, using: &rng), 1.6) * 9
            let (x, z): (Float, Float) = [(along, -out), (out, along), (along, out), (-out, along)][side]
            let node = SCNNode()
            node.position = SCNVector3(SCNFloat(x), -0.4, SCNFloat(z))
            node.eulerAngles.y = SCNFloat(Float.random(in: 0...6.28, using: &rng))
            let s = Float.random(in: 0.7...1.4, using: &rng)
            node.scale = SCNVector3(SCNFloat(s), SCNFloat(s), SCNFloat(s))
            let kind = Int.random(in: 0..<10, using: &rng)
            switch kind {
            case 0:   // pine tree: trunk + stacked cones
                let t = SCNNode(geometry: SCNCylinder(radius: 0.15, height: 0.8)); t.geometry?.materials = [trunk]; t.position.y = 0.4
                node.addChildNode(t)
                let leaf = leaves[Int.random(in: 0..<leaves.count, using: &rng)]
                for (i, r) in [1.1, 0.85, 0.6].enumerated() {
                    let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(r), height: 1.2))
                    cone.geometry?.materials = [leaf]; cone.position.y = SCNFloat(1.1 + Double(i) * 0.6); node.addChildNode(cone)
                }
            case 1...2:   // round tree
                let t = SCNNode(geometry: SCNCylinder(radius: 0.13, height: 1.2)); t.geometry?.materials = [trunk]; t.position.y = 0.6
                node.addChildNode(t)
                let leaf = leaves[Int.random(in: 0..<leaves.count, using: &rng)]
                for (dx, dy, r) in [(0.0, 1.6, 0.75), (0.35, 1.35, 0.5), (-0.3, 1.4, 0.55)] {
                    let b = SCNNode(geometry: SCNSphere(radius: CGFloat(r))); b.geometry?.materials = [leaf]
                    b.position = SCNVector3(SCNFloat(dx), SCNFloat(dy), 0); node.addChildNode(b)
                }
            case 3...7:   // bush
                let leaf = leaves[Int.random(in: 0..<leaves.count, using: &rng)]
                for (dx, r) in [(0.0, 0.45), (0.4, 0.35), (-0.35, 0.32)] {
                    let b = SCNNode(geometry: SCNSphere(radius: CGFloat(r))); b.geometry?.materials = [leaf]
                    b.position = SCNVector3(SCNFloat(dx), SCNFloat(r * 0.8), 0); node.addChildNode(b)
                }
            case 8:       // rock
                let r = SCNNode(geometry: SCNSphere(radius: 0.5)); (r.geometry as? SCNSphere)?.segmentCount = 6
                r.geometry?.materials = [rock]; r.scale = SCNVector3(1.2, 0.6, 0.9); r.position.y = 0.2; node.addChildNode(r)
            default:      // flower patch
                for _ in 0..<3 {
                    let px = SCNFloat(Float.random(in: -0.6...0.6, using: &rng)), pz = SCNFloat(Float.random(in: -0.6...0.6, using: &rng))
                    let stem = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 0.4)); stem.geometry?.materials = [leaves[1]]
                    stem.position = SCNVector3(px, 0.2, pz); node.addChildNode(stem)
                    let head = SCNNode(geometry: SCNSphere(radius: 0.09))
                    head.geometry?.materials = [petals[Int.random(in: 0..<petals.count, using: &rng)]]
                    head.position = SCNVector3(px, 0.42, pz); node.addChildNode(head)
                }
            }
            root.addChildNode(node)
        }
        root.enumerateHierarchy { n, _ in n.castsShadow = false }   // outside the play area; skip the shadow pass
        return root
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Jungle style textures

extension Tex {
    /// Dense, even lawn: many short blades on a green base.
    static func grass(height: Bool) -> CGImage {
        image(256, 256) { c in
            c.setFillColor(height ? PColor(white: 0.3, alpha: 1).cgColor : PColor(red: 0.40, green: 0.74, blue: 0.20, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            var g = SeededRNG(seed: 3)
            c.setLineCap(.round)
            for _ in 0..<2600 {
                let x = CGFloat.random(in: 0...256, using: &g), y = CGFloat.random(in: 0...256, using: &g)
                let v = CGFloat.random(in: -0.05...0.07, using: &g)
                c.setStrokeColor(height ? PColor(white: 0.5 + v * 3, alpha: 0.5).cgColor
                                        : PColor(red: 0.36 + v, green: 0.70 + v, blue: 0.16 + v * 0.5, alpha: 0.9).cgColor)
                c.setLineWidth(.random(in: 1.2...2.4, using: &g))
                c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + .random(in: -3...3, using: &g), y: y + .random(in: 4...8, using: &g)))
                c.strokePath()
            }
        }
    }

    /// Overlapping leaves for hedges.
    static func leaves(height: Bool) -> CGImage {
        image(128, 128) { c in
            c.setFillColor(height ? PColor(white: 0.1, alpha: 1).cgColor : PColor(red: 0.08, green: 0.28, blue: 0.08, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            var g = SeededRNG(seed: 11)
            for _ in 0..<160 {
                let x = CGFloat.random(in: -8...136, using: &g), y = CGFloat.random(in: -8...136, using: &g)
                let a = CGFloat.random(in: 0...(.pi * 2), using: &g), v = CGFloat.random(in: -0.08...0.12, using: &g)
                c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: a)
                c.setFillColor(height ? PColor(white: 0.5 + v * 3, alpha: 1).cgColor
                                      : PColor(red: 0.20 + v, green: 0.50 + v * 1.5, blue: 0.14 + v, alpha: 1).cgColor)
                c.fillEllipse(in: CGRect(x: -10, y: -5, width: 20, height: 10))
                c.setStrokeColor(PColor(white: height ? 0.3 : 0, alpha: 0.25).cgColor); c.setLineWidth(1)
                c.move(to: CGPoint(x: -9, y: 0)); c.addLine(to: CGPoint(x: 9, y: 0)); c.strokePath()
                c.restoreGState()
            }
        }
    }

    static func forestFloor() -> CGImage {
        noise(PColor(red: 0.16, green: 0.30, blue: 0.12, alpha: 1), PColor(red: 0.30, green: 0.26, blue: 0.14, alpha: 1))
    }

    /// Equirectangular skin for one body sphere: base colour with large rounded spots and a pale belly.
    static func spotted(base: PColor, spot: PColor) -> CGImage {
        image(256, 128) { c in
            c.setFillColor(base.cgColor); c.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            c.setFillColor(spot.cgColor)
            for (x, w) in [(10.0, 70.0), (128.0, 70.0)] {   // two big spots on opposite sides
                c.fillEllipse(in: CGRect(x: x, y: 44, width: w, height: 58))
            }
            c.fillEllipse(in: CGRect(x: 92, y: 96, width: 30, height: 22))
            c.fillEllipse(in: CGRect(x: 214, y: 96, width: 30, height: 22))
            // subtle scale bump baked into albedo
            c.setFillColor(PColor(white: 0, alpha: 0.06).cgColor)
            for row in 0..<8 { for col in 0..<16 { c.fillEllipse(in: CGRect(x: col * 16 + (row % 2) * 8, y: row * 16, width: 14, height: 14)) } }
        }
    }
}

extension Mat {
    static let hedge: SCNMaterial = {
        let m = pbr(.white, rough: 0.8)
        m.diffuse.contents = Tex.leaves(height: false)
        m.normal.contents = Tex.leaves(height: true)
        m.normal.intensity = 1
        return m
    }()
}

extension Tex {
    /// Soft meadow: gentle tone variation, fine low-contrast blades, clover clusters and a few fallen leaves.
    static func meadow(height: Bool) -> CGImage {
        image(256, 256) { c in
            var g = SeededRNG(seed: 42)
            c.setFillColor(height ? PColor(white: 0.45, alpha: 1).cgColor : PColor(red: 0.44, green: 0.72, blue: 0.24, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            // large soft patches (drawn 3x3 so they tile seamlessly)
            for _ in 0..<14 {
                let x = CGFloat.random(in: 0...256, using: &g), y = CGFloat.random(in: 0...256, using: &g), r = CGFloat.random(in: 30...70, using: &g)
                let v = CGFloat.random(in: -0.05...0.05, using: &g)
                let col = height ? PColor(white: 0.45 + v, alpha: 1) : PColor(red: 0.44 + v, green: 0.72 + v, blue: 0.24 + v * 0.5, alpha: 1)
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [col.cgColor, col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                for dx in [-256.0, 0, 256] { for dy in [-256.0, 0, 256] {
                    let p = CGPoint(x: x + dx, y: y + dy)
                    c.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
                } }
            }
            c.setLineCap(.round)
            for _ in 0..<1800 {   // fine blades
                let x = CGFloat.random(in: 0...256, using: &g), y = CGFloat.random(in: 0...256, using: &g)
                let v = CGFloat.random(in: -0.04...0.06, using: &g)
                c.setStrokeColor(height ? PColor(white: 0.6, alpha: 0.35).cgColor : PColor(red: 0.46 + v, green: 0.76 + v, blue: 0.26, alpha: 0.5).cgColor)
                c.setLineWidth(1.3)
                c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + .random(in: -2...2, using: &g), y: y + 5)); c.strokePath()
            }
            for _ in 0..<16 {   // clover clusters
                let cx = CGFloat.random(in: 12...244, using: &g), cy = CGFloat.random(in: 12...244, using: &g)
                for k in 0..<3 {
                    let a = CGFloat(k) * 2.094 + 0.3
                    c.setFillColor(height ? PColor(white: 0.8, alpha: 1).cgColor : PColor(red: 0.30, green: 0.62, blue: 0.20, alpha: 1).cgColor)
                    c.fillEllipse(in: CGRect(x: cx + cos(a) * 4 - 4, y: cy + sin(a) * 4 - 4, width: 8, height: 8))
                }
            }
            for _ in 0..<6 {      // fallen leaves
                let x = CGFloat.random(in: 10...246, using: &g), y = CGFloat.random(in: 10...246, using: &g)
                c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: .random(in: 0...6.28, using: &g))
                c.setFillColor(height ? PColor(white: 0.75, alpha: 1).cgColor
                                      : (Bool.random(using: &g) ? PColor(red: 0.75, green: 0.55, blue: 0.18, alpha: 1) : PColor(red: 0.62, green: 0.38, blue: 0.14, alpha: 1)).cgColor)
                c.fillEllipse(in: CGRect(x: -7, y: -3.5, width: 14, height: 7)); c.restoreGState()
            }
        }
    }
}
