import SceneKit
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

typealias V3 = SIMD3<Float>

func v3(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 { SCNVector3(SCNFloat(x), SCNFloat(y), SCNFloat(z)) }
extension SCNVector3 { var simd: V3 { V3(Float(x), Float(y), Float(z)) } }

// MARK: - Mesh builders

enum Geo {
    static func mesh(_ pos: [V3], _ nrm: [V3], _ uv: [SIMD2<Float>], _ idx: [UInt32]) -> SCNGeometry {
        let p = pos.flatMap { [$0.x, $0.y, $0.z] }, n = nrm.flatMap { [$0.x, $0.y, $0.z] }, t = uv.flatMap { [$0.x, $0.y] }
        func src(_ a: [Float], _ sem: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: a.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: sem, vectorCount: a.count / comps,
                              usesFloatComponents: true, componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
        }
        let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                    primitiveCount: idx.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: [src(p, .vertex, 3), src(n, .normal, 3), src(t, .texcoord, 2)], elements: [el])
    }

    private static func grid(rows: Int, cols: Int) -> [UInt32] {
        var idx: [UInt32] = []
        idx.reserveCapacity(rows * cols * 6)
        for i in 0..<rows { for j in 0..<cols {
            let a = UInt32(i * (cols + 1) + j), b = a + UInt32(cols + 1)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        } }
        return idx
    }

    /// Surface of revolution around Y. Profile = (radius, height) from bottom to top.
    static func lathe(_ prof: [(Float, Float)], segments: Int = 40) -> SCNGeometry {
        var pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Float>] = []
        for (i, (r, y)) in prof.enumerated() {
            let a = prof[max(0, i - 1)], b = prof[min(prof.count - 1, i + 1)]
            let dr = b.0 - a.0, dy = b.1 - a.1
            let l = max(1e-5, sqrt(dr * dr + dy * dy))
            let nr = dy / l, ny = -dr / l
            for j in 0...segments {
                let f = Float(j) / Float(segments) * 2 * .pi
                pos.append(V3(r * cos(f), y, r * sin(f)))
                nrm.append(V3(nr * cos(f), ny, nr * sin(f)))
                uv.append(SIMD2(Float(j) / Float(segments), 1 - Float(i) / Float(prof.count - 1)))
            }
        }
        return mesh(pos, nrm, uv, grid(rows: prof.count - 1, cols: segments))
    }

    /// Tube along a 3D curve using parallel-transport frames. `radii` per point; u = arc length * uScale.
    static func tube(_ pts: [V3], radii: [Float], sides: Int = 16, uScale: Float = 1, startNormal: V3 = V3(0, 1, 0)) -> SCNGeometry? {
        guard pts.count >= 2 else { return nil }
        var pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Float>] = []
        pos.reserveCapacity(pts.count * (sides + 1))
        var arc: Float = 0
        var N = startNormal
        for i in 0..<pts.count {
            let T = simd_normalize(pts[min(i + 1, pts.count - 1)] - pts[max(i - 1, 0)])
            N = N - T * simd_dot(N, T)
            if simd_length(N) < 1e-4 { N = abs(T.y) < 0.9 ? V3(0, 1, 0) : V3(1, 0, 0); N = N - T * simd_dot(N, T) }
            N = simd_normalize(N)
            let B = simd_cross(T, N)
            if i > 0 { arc += simd_distance(pts[i], pts[i - 1]) }
            for j in 0...sides {
                let a = Float(j) / Float(sides) * 2 * .pi
                let o = -N * cos(a) + B * sin(a)
                pos.append(pts[i] + o * radii[i]); nrm.append(o)
                uv.append(SIMD2(arc * uScale, Float(j) / Float(sides)))
            }
        }
        return mesh(pos, nrm, uv, grid(rows: pts.count - 1, cols: sides))
    }

    /// Lumpy sphere (rocks): radius displaced by smooth pseudo-noise, normals from faces.
    static func rock(seed: Float, rings: Int = 18, segments: Int = 24) -> SCNGeometry {
        var pos: [V3] = [], uv: [SIMD2<Float>] = []
        for i in 0...rings {
            let th = Float(i) / Float(rings) * .pi
            for j in 0...segments {
                let ph = Float(j % segments) / Float(segments) * 2 * .pi
                let d = V3(sin(th) * cos(ph), -cos(th), sin(th) * sin(ph))
                let n = sin(d.x * 3.1 + seed) * 0.08 + sin(d.y * 4.3 + seed * 2) * 0.07 + sin(d.z * 5.7 - seed) * 0.06
                    + sin((d.x + d.z) * 9 + seed * 3) * 0.025
                pos.append(d * (0.5 + n)); uv.append(SIMD2(Float(j) / Float(segments), Float(i) / Float(rings)))
            }
        }
        let idx = grid(rows: rings, cols: segments)
        var nrm = [V3](repeating: .zero, count: pos.count)
        for k in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[k]), b = Int(idx[k + 1]), c = Int(idx[k + 2])
            let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            nrm[a] += fn; nrm[b] += fn; nrm[c] += fn
        }
        // Weld the seam so it shades smoothly.
        for i in 0...rings { let a = i * (segments + 1), b = a + segments; let s = nrm[a] + nrm[b]; nrm[a] = s; nrm[b] = s }
        return mesh(pos, nrm.map { simd_length($0) > 0 ? simd_normalize($0) : V3(0, 1, 0) }, uv, idx)
    }

    /// Extruded, chamfered solid from a closed polygon in the XY plane.
    static func extrude(_ pts: [CGPoint], depth: CGFloat, chamfer: CGFloat) -> SCNShape {
        #if os(macOS)
        let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }; p.close()
        #else
        let p = UIBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.close()
        #endif
        p.flatness = 0.01
        let s = SCNShape(path: p, extrusionDepth: depth)
        s.chamferRadius = chamfer
        return s
    }
}

// MARK: - Materials for elements

enum EMat {
    static func glossy(_ c: PColor, rough: CGFloat = 0.25, coat: CGFloat = 0.8) -> SCNMaterial {
        let m = Mat.pbr(c, rough: rough); m.clearCoat.contents = coat; m.clearCoatRoughness.contents = 0.1; m.isDoubleSided = true; return m
    }
    static func matte(_ c: PColor, rough: CGFloat = 0.7) -> SCNMaterial { let m = Mat.pbr(c, rough: rough); m.isDoubleSided = true; return m }
    static func glow(_ c: PColor, _ k: CGFloat = 0.6) -> SCNMaterial { let m = glossy(c); m.emission.contents = c.blended(k); return m }
    static func glass() -> SCNMaterial {
        let m = Mat.pbr(PColor(white: 1, alpha: 1), rough: 0.05)
        m.transparency = 0.35; m.transparencyMode = .dualLayer; m.isDoubleSided = true; m.blendMode = .alpha
        return m
    }
    static let metal: SCNMaterial = { let m = Mat.pbr(PColor(white: 0.8, alpha: 1), rough: 0.25, metal: 1); m.isDoubleSided = true; return m }()
    static let stem = matte(PColor(red: 0.38, green: 0.24, blue: 0.10, alpha: 1))
    static let leaf = glossy(PColor(red: 0.22, green: 0.62, blue: 0.16, alpha: 1), rough: 0.4, coat: 0.3)
    static let white = glossy(PColor(red: 1, green: 0.98, blue: 0.94, alpha: 1), rough: 0.15)
    static let black = glossy(PColor(white: 0.03, alpha: 1), rough: 0.05)
}

private func node(_ g: SCNGeometry?, _ m: SCNMaterial, _ p: SCNVector3 = SCNVector3Zero) -> SCNNode {
    let n = SCNNode(geometry: g); n.geometry?.materials = [m]; n.position = p; return n
}

private func leafNode(size: CGFloat) -> SCNNode {
    let pts = (0..<20).map { i -> CGPoint in
        let t = Double(i) / 20 * 2 * .pi
        return CGPoint(x: sin(t) * 0.5 * size * (1 - 0.3 * cos(t)), y: (cos(t) * 0.5 + 0.5) * size * 1.6)
    }
    let n = node(Geo.extrude(pts, depth: size * 0.06, chamfer: size * 0.025), EMat.leaf)
    return n
}

// MARK: - Element models

enum Models {
    static func foodColor(_ f: FoodKind) -> PColor {
        [PColor(red: 0.86, green: 0.10, blue: 0.10, alpha: 1), PColor(red: 0.70, green: 0.02, blue: 0.16, alpha: 1),
         PColor(red: 0.80, green: 0.82, blue: 0.20, alpha: 1), PColor(red: 0.90, green: 0.16, blue: 0.10, alpha: 1)][f.rawValue]
    }
    static func specialColor(_ s: Special) -> PColor {
        [PColor(red: 0.62, green: 0.42, blue: 0.95, alpha: 1), PColor(red: 1, green: 0.84, blue: 0.10, alpha: 1),
         PColor(red: 0.20, green: 0.95, blue: 0.45, alpha: 1), PColor(red: 1, green: 0.48, blue: 0.08, alpha: 1),
         PColor(red: 0.20, green: 0.65, blue: 1, alpha: 1), PColor(red: 0.95, green: 0.95, blue: 1, alpha: 1)][s.rawValue]
    }

    private static func present(_ inner: SCNNode, spin: Double = 4, bob: Bool = true) -> SCNNode {
        let root = SCNNode()
        root.addChildNode(inner)
        inner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spin)))
        if bob {
            let up = SCNAction.moveBy(x: 0, y: 0.12, z: 0, duration: 0.8); up.timingMode = .easeInEaseOut
            let dn = SCNAction.moveBy(x: 0, y: -0.12, z: 0, duration: 0.8); dn.timingMode = .easeInEaseOut
            inner.runAction(.repeatForever(.sequence([up, dn])))
        }
        root.enumerateHierarchy { n, _ in n.castsShadow = true }
        return root
    }

    // Cached geometry so spawning is cheap.
    private static let appleGeo: SCNGeometry = Geo.lathe((0...40).map { i in
        let th = Float(i) / 40 * .pi
        var r = 0.33 * sin(th) * (1 + 0.12 * sin(th * 2))
        var y = 0.30 * (1 - cos(th))
        y -= 0.07 * exp(-pow((.pi - th) / 0.32, 2))
        y += 0.03 * exp(-pow(th / 0.3, 2))
        if i == 0 || i == 40 { r = 0 }
        return (r, y)
    })
    private static let pearGeo: SCNGeometry = Geo.lathe((0...40).map { i in
        let s = Float(i) / 40
        let r = pow(sin(.pi * s), 0.7) * (0.30 - 0.15 * s) + 0.05 * sin(.pi * s) * exp(-pow((s - 0.75) / 0.15, 2))
        return (i == 0 || i == 40 ? 0 : r, 0.78 * s)
    })
    private static let capGeo: SCNGeometry = Geo.lathe(
        [(0.07, 0.30), (0.25, 0.31), (0.40, 0.34), (0.43, 0.38)] + (0...16).map { i in
            let a = Float(i) / 16 * .pi / 2
            return (0.43 * cos(a), 0.38 + 0.30 * sin(a) * (1 - 0.08 * cos(a)))
        })
    private static let mushStemGeo: SCNGeometry = Geo.lathe([(0, 0), (0.14, 0), (0.15, 0.04), (0.12, 0.15), (0.10, 0.28), (0.09, 0.33), (0, 0.33)])

    static func food(_ f: FoodKind) -> SCNNode {
        let n = SCNNode()
        let skin = EMat.glossy(foodColor(f))
        switch f {
        case .apple:
            let body = node(appleGeo, skin, v3(0, 0.08, 0)); n.addChildNode(body)
            let st = node(Geo.tube([V3(0, 0.6, 0), V3(0.02, 0.7, 0), V3(0.06, 0.78, 0)], radii: [0.025, 0.022, 0.018], sides: 8), EMat.stem)
            n.addChildNode(st)
            let lf = leafNode(size: 0.16); lf.position = v3(0.05, 0.72, 0); lf.eulerAngles = v3(0.3, 0, -1.0); n.addChildNode(lf)
        case .cherry:
            let top = V3(0, 0.85, 0)
            for sx: Float in [-1, 1] {
                let base = V3(0.16 * sx, 0.24, 0)
                n.addChildNode(node(SCNSphere(radius: 0.17), skin, v3(base.x, base.y, base.z)))
                let mid = V3(0.12 * sx, 0.6, 0.02)
                let pts = (0...10).map { i -> V3 in   // quadratic curve stem
                    let t = Float(i) / 10; return (1 - t) * (1 - t) * (base + V3(0, 0.15, 0)) + 2 * (1 - t) * t * mid + t * t * top
                }
                n.addChildNode(node(Geo.tube(pts, radii: Array(repeating: 0.018, count: pts.count), sides: 8), EMat.leaf))
            }
            let lf = leafNode(size: 0.18); lf.position = v3(0, 0.84, 0); lf.eulerAngles = v3(0.4, 0.3, -1.2); n.addChildNode(lf)
        case .pear:
            n.addChildNode(node(pearGeo, skin, v3(0, 0.05, 0)))
            n.addChildNode(node(Geo.tube([V3(0, 0.8, 0), V3(0.03, 0.9, 0), V3(0.08, 0.96, 0)], radii: [0.025, 0.02, 0.016], sides: 8), EMat.stem))
        case .mushroom:
            n.addChildNode(node(mushStemGeo, EMat.matte(PColor(red: 0.98, green: 0.95, blue: 0.86, alpha: 1), rough: 0.6)))
            n.addChildNode(node(capGeo, skin))
            var rng = SeededRNG(seed: 5)
            for i in 0..<7 {   // raised white warts on the cap
                let a = Float(i) / 7 * 2 * .pi + Float.random(in: 0...0.4, using: &rng)
                let el = Float(i % 2 == 0 ? 0.5 : 1.0)
                let d = V3(cos(a) * cos(el), sin(el), sin(a) * cos(el))
                let p = V3(d.x * 0.40, 0.38 + d.y * 0.28, d.z * 0.40)
                let w = node(SCNSphere(radius: 0.055), EMat.white, v3(p.x, p.y, p.z)); w.scale = v3(1, 0.45, 1)
                w.look(at: v3(p.x + d.x, p.y + d.y, p.z + d.z), up: v3(0, 1, 0), localFront: v3(0, 1, 0))
                n.addChildNode(w)
            }
            n.addChildNode(node(SCNSphere(radius: 0.06), EMat.white, v3(0, 0.67, 0)))
        }
        return present(n, spin: f == .mushroom ? 6 : 4)
    }

    static func special(_ s: Special) -> SCNNode {
        let c = specialColor(s)
        let n = SCNNode()
        switch s {
        case .snail:
            // Spiral shell as a tapering tube, plus a soft body with eye stalks.
            let pts = (0...80).map { i -> V3 in
                let t = Float(i) / 80, a = t * 2.6 * 2 * .pi, r = 0.26 * (1 - t * 0.9)
                return V3(r * cos(a), 0.45 + r * sin(a), (t - 0.5) * 0.12)
            }
            let radii = (0...80).map { Float(0.12) * (1 - Float($0) / 80 * 0.85) }
            n.addChildNode(node(Geo.tube(pts, radii: radii, sides: 14, startNormal: V3(0, 0, 1)), EMat.glow(c, 0.3)))
            let body = (0...12).map { i -> V3 in let t = Float(i) / 12; return V3(-0.42 + t * 0.85, 0.1 + 0.08 * sin(t * .pi) + (t > 0.85 ? (t - 0.85) * 1.2 : 0), 0) }
            let br = (0...12).map { i -> Float in let t = Float(i) / 12; return 0.11 * sin(.pi * min(1, t * 1.15 + 0.05)) + 0.02 }
            let skin = EMat.glossy(PColor(red: 0.85, green: 0.78, blue: 0.55, alpha: 1), rough: 0.35)
            n.addChildNode(node(Geo.tube(body, radii: br, sides: 12), skin))
            for z: Float in [-0.06, 0.06] {
                n.addChildNode(node(Geo.tube([V3(0.36, 0.2, z), V3(0.42, 0.33, z * 1.6)], radii: [0.025, 0.02], sides: 8), skin))
                n.addChildNode(node(SCNSphere(radius: 0.035), EMat.black, v3(0.42, 0.35, z * 1.6)))
            }
        case .flash:
            let bolt: [CGPoint] = [(0.05, 0.9), (-0.22, 0.38), (-0.02, 0.38), (-0.12, 0), (0.24, 0.52), (0.04, 0.52), (0.18, 0.9)].map { CGPoint(x: $0.0, y: $0.1) }
            let b = node(Geo.extrude(bolt, depth: 0.14, chamfer: 0.035), EMat.glow(c, 0.8)); b.position = v3(0, 0.05, 0)
            n.addChildNode(b)
        case .serum:
            let bottle = Geo.lathe([(0, 0.05), (0.15, 0.05), (0.17, 0.08), (0.17, 0.48), (0.10, 0.58), (0.07, 0.64), (0.07, 0.72), (0, 0.72)])
            let liquid = Geo.lathe([(0, 0.07), (0.145, 0.07), (0.15, 0.09), (0.15, 0.38), (0, 0.38)])
            n.addChildNode(node(liquid, EMat.glow(c, 0.9)))
            n.addChildNode(node(bottle, EMat.glass()))
            n.addChildNode(node(Geo.lathe([(0, 0.70), (0.09, 0.70), (0.095, 0.73), (0.09, 0.82), (0, 0.84)]), EMat.matte(PColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1), rough: 0.4)))
        case .twister:
            for k in 0..<2 {
                let pts = (0...90).map { i -> V3 in
                    let t = Float(i) / 90, a = t * 3 * 2 * .pi + Float(k) * .pi, r = 0.08 + 0.26 * t
                    return V3(r * cos(a), 0.08 + t * 0.75, r * sin(a))
                }
                let radii = (0...90).map { i in Float(0.025 + 0.035 * Double(i) / 90) }
                n.addChildNode(node(Geo.tube(pts, radii: radii, sides: 10), EMat.glow(k == 0 ? c : c.blended(0.8), 0.5)))
            }
        case .arrow:
            let arrow: [CGPoint] = [(-0.38, 0.06), (0.08, 0.06), (0.08, 0.2), (0.4, 0), (0.08, -0.2), (0.08, -0.06), (-0.38, -0.06)].map { CGPoint(x: $0.0, y: $0.1) }
            let a = node(Geo.extrude(arrow, depth: 0.12, chamfer: 0.03), EMat.glow(c, 0.6)); a.position = v3(0, 0.45, 0)
            let fins: [CGPoint] = [(-0.42, 0.14), (-0.30, 0.06), (-0.30, -0.06), (-0.42, -0.14), (-0.48, 0)].map { CGPoint(x: $0.0, y: $0.1) }
            a.addChildNode(node(Geo.extrude(fins, depth: 0.16, chamfer: 0.02), EMat.glossy(.white)))
            n.addChildNode(a)
        case .diet:
            let can = Geo.lathe([(0, 0.05), (0.15, 0.05), (0.17, 0.09), (0.17, 0.62), (0.14, 0.68), (0.13, 0.69), (0, 0.69)])
            let label = Mat.pbr(.white, rough: 0.3, metal: 0.6)
            label.diffuse.contents = Tex.image(128, 64) { g in
                g.setFillColor(PColor(white: 0.92, alpha: 1).cgColor); g.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
                g.setFillColor(PColor(red: 0.15, green: 0.55, blue: 1, alpha: 1).cgColor); g.fill(CGRect(x: 0, y: 22, width: 128, height: 22))
                g.setFillColor(PColor.white.cgColor)
                for x in stride(from: 6, to: 128, by: 24) { g.fillEllipse(in: CGRect(x: x, y: 28, width: 10, height: 10)) }
            }
            label.isDoubleSided = true
            n.addChildNode(node(can, label))
            n.addChildNode(node(Geo.lathe([(0, 0.69), (0.13, 0.69), (0.135, 0.71), (0, 0.71)]), EMat.metal))
            n.addChildNode(node(Geo.tube([V3(-0.02, 0.69, 0), V3(0.05, 0.85, 0.02)], radii: [0.02, 0.02], sides: 8), EMat.glossy(.systemPink)))
        }
        // halo ring + light so specials read as power-ups
        let ring = node(SCNTorus(ringRadius: 0.42, pipeRadius: 0.025), EMat.glow(c, 1.0), v3(0, 0.03, 0))
        ring.runAction(.repeatForever(.sequence([.scale(to: 1.12, duration: 0.6), .scale(to: 0.95, duration: 0.6)])))
        let light = SCNLight(); light.type = .omni; light.color = c; light.intensity = 150; light.attenuationEndDistance = 3
        let ln = SCNNode(); ln.light = light; ln.position = v3(0, 0.8, 0)
        let root = present(n, spin: 3)
        root.addChildNode(ring); root.addChildNode(ln)
        return root
    }

    private static let rockGeos: [SCNGeometry] = (0..<4).map { Geo.rock(seed: Float($0) * 1.7 + 0.5) }
    private static let rockMat: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 0.9)
        m.diffuse.contents = Tex.noise(PColor(red: 0.52, green: 0.50, blue: 0.47, alpha: 1), PColor(red: 0.68, green: 0.66, blue: 0.62, alpha: 1))
        m.normal.contents = Tex.noise(PColor(white: 0.4, alpha: 1), PColor(white: 0.9, alpha: 1)); m.normal.intensity = 0.6
        return m
    }()
    private static let crateMat: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 0.75)
        m.diffuse.contents = Tex.crate()
        let h = Tex.image(128, 128) { c in   // planks raised, frame proud, gaps sunk
            c.setFillColor(PColor(white: 0.55, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            c.setStrokeColor(PColor(white: 0.1, alpha: 1).cgColor); c.setLineWidth(3)
            for y in stride(from: 16, to: 128, by: 24) { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 128, y: y)) }
            c.strokePath()
            c.setStrokeColor(PColor(white: 1, alpha: 1).cgColor); c.setLineWidth(14); c.stroke(CGRect(x: 7, y: 7, width: 114, height: 114))
            c.setLineWidth(12); c.move(to: CGPoint(x: 10, y: 10)); c.addLine(to: CGPoint(x: 118, y: 118)); c.strokePath()
        }
        m.normal.contents = h; m.normal.intensity = 1
        return m
    }()

    static func obstacle(_ k: ObstacleKind) -> SCNNode {
        let n = SCNNode()
        switch k {
        case .stone:
            let i = Int.random(in: 0..<rockGeos.count)
            let r = node(rockGeos[i], rockMat, v3(0, 0.3, 0)); r.scale = v3(1.6, 1.15, 1.45)
            r.eulerAngles.y = SCNFloat(Float.random(in: 0...6.28)); n.addChildNode(r)
            let moss = node(rockGeos[(i + 1) % rockGeos.count], EMat.matte(PColor(red: 0.25, green: 0.5, blue: 0.15, alpha: 1), rough: 1), v3(0.1, 0.62, 0))
            moss.scale = v3(0.7, 0.18, 0.6); n.addChildNode(moss)
        case .crate:
            let b = node(SCNBox(width: 0.84, height: 0.84, length: 0.84, chamferRadius: 0.06), crateMat, v3(0, 0.42, 0))
            b.eulerAngles.y = SCNFloat(Float.random(in: -0.15...0.15)); n.addChildNode(b)
            for x: Float in [-0.42, 0.42] { for z: Float in [-0.42, 0.42] {   // iron corner brackets
                n.addChildNode(node(SCNBox(width: 0.1, height: 0.86, length: 0.1, chamferRadius: 0.02), EMat.metal, v3(x * 0.98, 0.42, z * 0.98)))
            } }
        }
        n.enumerateHierarchy { c, _ in c.castsShadow = true }
        return n
    }
}

// MARK: - Snake: one continuous smooth tube + an original cartoon head

final class SnakeView {
    let root = SCNNode()
    private let head: SCNNode
    private let body = SCNNode()
    private var skin: SCNMaterial
    private var headMat: SCNMaterial
    private(set) var headPosition = SCNVector3Zero

    /// Base colours (swatches + head) and spot colours.
    static let colors: [PColor] = [
        PColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1),
        PColor(red: 0.88, green: 0.16, blue: 0.14, alpha: 1),
        PColor(red: 0.16, green: 0.40, blue: 0.90, alpha: 1),
    ]
    static let spots: [PColor] = [
        PColor(red: 0.98, green: 0.86, blue: 0.20, alpha: 1),
        PColor(red: 1.00, green: 0.82, blue: 0.10, alpha: 1),
        PColor(red: 0.40, green: 0.90, blue: 0.95, alpha: 1),
    ]

    init(colorIndex: Int) {
        skin = EMat.glossy(.white, rough: 0.3, coat: 0.7)
        skin.normal.contents = Mat.scaleHeight; skin.normal.intensity = 0.5
        skin.diffuse.wrapS = .repeat; skin.diffuse.wrapT = .repeat
        skin.normal.wrapS = .repeat; skin.normal.wrapT = .repeat
        skin.normal.contentsTransform = SCNMatrix4MakeScale(1, 3, 1)
        headMat = EMat.glossy(.white, rough: 0.3, coat: 0.7)
        head = SnakeView.makeHead(headMat)
        root.addChildNode(body)
        root.addChildNode(head)
        body.castsShadow = true
        setColor(colorIndex)
    }

    func setColor(_ i: Int) {
        let k = i % SnakeView.colors.count
        skin.diffuse.contents = SnakeView.skinTexture(base: SnakeView.colors[k], spot: SnakeView.spots[k])
        headMat.diffuse.contents = SnakeView.colors[k]
    }

    /// Texture covers 2 cells of length (u) × full circumference (v): pale belly at the edges, spots on the back.
    static func skinTexture(base: PColor, spot: PColor) -> CGImage {
        Tex.image(256, 128) { c in
            c.setFillColor(base.cgColor); c.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            let belly = PColor(red: 0.98, green: 0.92, blue: 0.72, alpha: 1)
            c.setFillColor(belly.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 256, height: 22)); c.fill(CGRect(x: 0, y: 106, width: 256, height: 22))
            c.setFillColor(spot.cgColor)
            c.fillEllipse(in: CGRect(x: 20, y: 36, width: 90, height: 56))
            c.fillEllipse(in: CGRect(x: 150, y: 44, width: 70, height: 40))
            c.setFillColor(base.blended(0.75).cgColor)   // dark outline dots for a cartoon edge
            for x in [16.0, 112.0, 146.0, 222.0] { c.fillEllipse(in: CGRect(x: x, y: 60, width: 8, height: 8)) }
        }
    }

    private static func makeHead(_ m: SCNMaterial) -> SCNNode {
        let h = SCNNode()
        // Rounded, slightly flattened head built by lathe and laid along -z.
        let shape = Geo.lathe((0...24).map { i in
            let t = Float(i) / 24, th = t * .pi
            return (0.42 * sin(th) * (1 - 0.18 * t), -0.5 + t * 1.15)
        })
        let skull = node(shape, m); skull.eulerAngles.x = -.pi / 2; skull.scale = v3(1.1, 1, 0.82); skull.position = v3(0, 0.0, 0.05)
        h.addChildNode(skull)
        for sx: Float in [-1, 1] {
            let eye = node(SCNSphere(radius: 0.2), EMat.white, v3(0.2 * sx, 0.28, -0.22)); eye.scale = v3(1, 1.15, 1)
            h.addChildNode(eye)
            let pupil = node(SCNSphere(radius: 0.09), EMat.black, v3(0.22 * sx, 0.31, -0.38)); pupil.name = "pupil"
            h.addChildNode(pupil)
            h.addChildNode(node(SCNSphere(radius: 0.03), EMat.white, v3(0.19 * sx, 0.37, -0.45)))
            let lid = node(SCNSphere(radius: 0.21), m, v3(0.2 * sx, 0.33, -0.22)); lid.scale = v3(1.02, 0.45, 1.02); lid.name = "lid"
            h.addChildNode(lid)
            h.addChildNode(node(SCNSphere(radius: 0.03), EMat.black, v3(0.1 * sx, 0.02, -0.66)))
        }
        // Smile: a thin dark tube arc around the snout.
        let smile = (0...12).map { i -> V3 in let a = (Float(i) / 12 - 0.5) * 2.2; return V3(sin(a) * 0.3, -0.12 + (1 - cos(a)) * 0.05, -0.5 - cos(a) * 0.12) }
        h.addChildNode(node(Geo.tube(smile, radii: Array(repeating: 0.018, count: smile.count), sides: 6), EMat.black))
        let tongue = node(Geo.tube([V3(0, -0.14, -0.6), V3(0, -0.15, -0.8), V3(-0.04, -0.16, -0.9)], radii: [0.03, 0.025, 0.012], sides: 8),
                          EMat.glossy(PColor(red: 0.95, green: 0.15, blue: 0.35, alpha: 1)))
        tongue.runAction(.repeatForever(.sequence([.wait(duration: 1.8, withRange: 1), .move(by: v3(0, 0, -0.12), duration: 0.07), .move(by: v3(0, 0, 0.12), duration: 0.07)])))
        h.addChildNode(tongue)
        // Blink by dropping the lids.
        h.runAction(.repeatForever(.sequence([.wait(duration: 3.5, withRange: 2), .run { n in
            for c in n.childNodes where c.name == "lid" {
                c.runAction(.sequence([.move(by: v3(0, -0.12, 0), duration: 0.06), .move(by: v3(0, 0.12, 0), duration: 0.08)]))
            }
        }])))
        h.scale = v3(1.05, 1.05, 1.05)
        h.enumerateHierarchy { n, _ in n.castsShadow = true }
        return h
    }

    func update(_ s: Snake, t: Float) {
        root.opacity = s.alive ? 1 : 0.35
        guard let first = s.body.first else { body.geometry = nil; return }
        func w(_ p: P) -> V3 { Engine.world(p).simd }

        // Polyline from head cell back to tail (plus the vacated tail cell while moving).
        let growing = s.body.count > s.prevBody.count || s.body.last == s.prevBody.last
        let interpolate = s.alive && !s.snap && s.prevBody.count <= s.body.count && s.prevBody.first != first
        var q = s.body.map(w)
        if interpolate && !growing, let pl = s.prevBody.last { q.append(w(pl)) }
        let front = interpolate ? 1 - t : 0      // trim this much from the head end
        let back = interpolate && !growing ? t : 0

        // Split at wrap-around gaps.
        var pieces: [[V3]] = [[q[0]]]
        for i in 1..<max(q.count, 1) where q.count > 1 {
            if simd_distance(q[i], q[i - 1]) > 1.5 { pieces.append([q[i]]) } else { pieces[pieces.count - 1].append(q[i]) }
        }
        if pieces[0].count > 1 { pieces[0][0] = mix(pieces[0][0], pieces[0][1], t: front) }
        let lp = pieces.count - 1
        if pieces[lp].count > 1 { let c = pieces[lp].count; pieces[lp][c - 1] = mix(pieces[lp][c - 1], pieces[lp][c - 2], t: back) }

        let hp = pieces[0][0]
        headPosition = v3(hp.x, 0, hp.z)
        let dirV: V3 = pieces[0].count > 1 ? simd_normalize(hp - pieces[0][1]) : V3(Float(s.dir.delta.x), 0, Float(s.dir.delta.y))
        head.position = v3(hp.x, 0.44, hp.z)
        head.eulerAngles.y = SCNFloat(atan2(-dirV.x, -dirV.z))

        // Total length (for taper), then sample each piece with rounded corners.
        var total: Float = 0
        for p in pieces { for i in 1..<max(p.count, 1) where p.count > 1 { total += simd_distance(p[i], p[i - 1]) } }
        let geos = pieces.compactMap { piece -> SCNGeometry? in
            let pts = SnakeView.rounded(piece)
            var radii: [Float] = [], arc: Float = 0, startArc = SnakeView.arcOffset
            for i in 0..<pts.count {
                if i > 0 { arc += simd_distance(pts[i], pts[i - 1]) }
                let d = startArc + arc, fromTail = max(0, total - d)
                let r = 0.38 * min(1, 0.92 + d * 0.05) * min(1, fromTail / 2.6 + 0.12)
                radii.append(max(0.04, r))
            }
            SnakeView.arcOffset += arc
            let lifted = zip(pts, radii).map { V3($0.x, $1, $0.z) }   // rest on the floor
            return Geo.tube(lifted, radii: radii, sides: 18, uScale: 0.5)
        }
        SnakeView.arcOffset = 0
        if geos.count == 1 { body.geometry = geos[0]; body.geometry?.materials = [skin]; body.childNodes.forEach { $0.removeFromParentNode() } }
        else {
            body.geometry = nil
            body.childNodes.forEach { $0.removeFromParentNode() }
            for g in geos { g.materials = [skin]; let n = SCNNode(geometry: g); n.castsShadow = true; body.addChildNode(n) }
        }
    }

    private static var arcOffset: Float = 0

    /// Replace each interior corner with a quadratic curve between segment midpoints.
    private static func rounded(_ p: [V3]) -> [V3] {
        guard p.count > 2 else { return p.count == 2 ? subdivide(p[0], p[1], 4) : p }
        var out: [V3] = []
        let mids = (0..<p.count - 1).map { (p[$0] + p[$0 + 1]) * 0.5 }
        out += subdivide(p[0], mids[0], 3).dropLast()
        for i in 1..<p.count - 1 {
            let a = mids[i - 1], c = p[i], b = mids[i]
            for k in 0..<6 { let t = Float(k) / 6; out.append((1 - t) * (1 - t) * a + 2 * (1 - t) * t * c + t * t * b) }
        }
        out += subdivide(mids[mids.count - 1], p[p.count - 1], 3)
        // drop near-duplicate points (zero-length segments break frames)
        var clean: [V3] = [out[0]]
        for v in out.dropFirst() where simd_distance(v, clean.last!) > 0.01 { clean.append(v) }
        return clean.count >= 2 ? clean : [p[0], p[p.count - 1]]
    }

    private static func subdivide(_ a: V3, _ b: V3, _ n: Int) -> [V3] { (0...n).map { mix(a, b, t: Float($0) / Float(n)) } }
}

// MARK: - Boundary: mossy jungle logs, stumps, ferns

enum Boundary {
    static let bark: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 0.9)
        m.diffuse.contents = barkTex(height: false); m.normal.contents = barkTex(height: true); m.normal.intensity = 1.2
        for p in [m.diffuse, m.normal] { p.wrapS = .repeat; p.wrapT = .repeat }
        return m
    }()
    static let rings: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 0.8)
        m.diffuse.contents = Tex.image(128, 128) { c in
            c.setFillColor(PColor(red: 0.30, green: 0.19, blue: 0.10, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            for (i, r) in stride(from: 60.0, to: 4, by: -7).enumerated() {
                let v = i % 2 == 0 ? 0.0 : 0.06
                c.setFillColor(PColor(red: 0.78 - v, green: 0.60 - v, blue: 0.38 - v, alpha: 1).cgColor)
                c.fillEllipse(in: CGRect(x: 64 - r, y: 64 - r, width: r * 2, height: r * 2))
                c.setStrokeColor(PColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 1).cgColor); c.setLineWidth(1.2)
                c.strokeEllipse(in: CGRect(x: 64 - r, y: 64 - r, width: r * 2, height: r * 2))
            }
        }
        return m
    }()
    static let moss: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 1)
        m.diffuse.contents = Tex.noise(PColor(red: 0.22, green: 0.48, blue: 0.12, alpha: 1), PColor(red: 0.42, green: 0.66, blue: 0.20, alpha: 1))
        m.normal.contents = Tex.noise(PColor(white: 0.3, alpha: 1), PColor(white: 0.9, alpha: 1)); m.normal.intensity = 0.8
        return m
    }()
    static let fern = EMat.glossy(PColor(red: 0.18, green: 0.55, blue: 0.14, alpha: 1), rough: 0.5, coat: 0.2)

    private static let frond: SCNGeometry = {
        let pts = (0...8).map { k -> V3 in let t = Float(k) / 8; return V3(t * 0.6, sin(t * .pi * 0.8) * 0.35 - t * t * 0.2, 0) }
        let g = Geo.tube(pts, radii: (0...8).map { 0.05 * (1 - Float($0) / 9) }, sides: 6)!
        g.materials = [fern]; return g
    }()

    static func barkTex(height: Bool) -> CGImage {
        Tex.image(128, 256) { c in
            c.setFillColor(PColor(white: height ? 0.4 : 0, alpha: 1).cgColor)
            if !height { c.setFillColor(PColor(red: 0.36, green: 0.24, blue: 0.13, alpha: 1).cgColor) }
            c.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
            var g = SeededRNG(seed: 21)
            for _ in 0..<70 {   // long grooves running along the log
                let x = CGFloat.random(in: 0...128, using: &g), w = CGFloat.random(in: 3...9, using: &g)
                let v = CGFloat.random(in: -0.06...0.08, using: &g)
                c.setFillColor(height ? PColor(white: CGFloat.random(in: 0...1, using: &g) > 0.5 ? 0.9 : 0.1, alpha: 0.6).cgColor
                                      : PColor(red: 0.42 + v, green: 0.29 + v, blue: 0.16 + v * 0.5, alpha: 0.8).cgColor)
                c.fill(CGRect(x: x, y: 0, width: w, height: 256))
            }
            for _ in 0..<40 {   // cross cracks
                c.setFillColor(PColor(white: height ? 0 : 0.12, alpha: 0.5).cgColor)
                c.fill(CGRect(x: .random(in: 0...128, using: &g), y: .random(in: 0...256, using: &g), width: .random(in: 6...18, using: &g), height: 2))
            }
        }
    }

    private static let logGeo: SCNCylinder = { let c = SCNCylinder(radius: 0.4, height: 1.04); c.radialSegmentCount = 20; c.materials = [bark, rings, rings]; return c }()
    private static let stumpGeo: SCNCylinder = { let c = SCNCylinder(radius: 0.46, height: 1.0); c.radialSegmentCount = 22; c.materials = [bark, rings, rings]; return c }()
    private static let mossGeo: SCNSphere = { let s = SCNSphere(radius: 0.3); s.segmentCount = 12; s.materials = [moss]; return s }()

    static func log(alongX: Bool, _ rng: inout SeededRNG) -> SCNNode {
        let n = SCNNode()
        let l = SCNNode(geometry: logGeo); l.position = v3(0, 0.4, 0)
        if alongX { l.eulerAngles.z = .pi / 2 } else { l.eulerAngles.x = .pi / 2 }
        l.eulerAngles.y = SCNFloat(Float.random(in: 0...6.28, using: &rng)) * 0   // keep grain aligned
        n.addChildNode(l)
        // Moss blanket along the top.
        let mp = SCNNode(geometry: mossGeo); mp.position = v3(0, 0.74, 0)
        mp.scale = alongX ? v3(1.7, 0.28, 1.0) : v3(1.0, 0.28, 1.7); n.addChildNode(mp)
        decorate(n, &rng, top: 0.8)
        n.enumerateHierarchy { c, _ in c.castsShadow = true }
        return n
    }

    static func stump(_ rng: inout SeededRNG) -> SCNNode {
        let n = SCNNode()
        let s = SCNNode(geometry: stumpGeo); s.position = v3(0, 0.5, 0); n.addChildNode(s)
        for i in 0..<4 {   // roots flaring out
            let a = Float(i) / 4 * 2 * .pi + Float.random(in: 0...0.5, using: &rng)
            let pts = [V3(cos(a) * 0.3, 0.3, sin(a) * 0.3), V3(cos(a) * 0.5, 0.1, sin(a) * 0.5), V3(cos(a) * 0.62, 0.02, sin(a) * 0.62)]
            n.addChildNode(node(Geo.tube(pts, radii: [0.14, 0.09, 0.04], sides: 10), bark))
        }
        decorate(n, &rng, top: 1.02)
        n.enumerateHierarchy { c, _ in c.castsShadow = true }
        return n
    }

    /// Random ferns, mushrooms-free leaf sprigs and moss tufts so the border never repeats.
    private static func decorate(_ n: SCNNode, _ rng: inout SeededRNG, top: Float) {
        let r = Int.random(in: 0..<10, using: &rng)
        if r < 2 {   // fern: arching fronds sharing one tapered-tube mesh
            for i in 0..<3 {
                let f = SCNNode(geometry: frond)
                f.position = v3(0, top, 0)
                f.eulerAngles.y = SCNFloat(Float(i) / 3 * 2 * .pi + Float.random(in: 0...0.5, using: &rng))
                n.addChildNode(f)
            }
        } else if r < 4 {
            let t = SCNNode(geometry: mossGeo)
            t.position = v3(Float.random(in: -0.2...0.2, using: &rng), top, Float.random(in: -0.2...0.2, using: &rng))
            t.scale = v3(0.7, 0.5, 0.7); n.addChildNode(t)
        }
    }
}

// MARK: - Retro pixel-block boundary (inspired by early monochrome phone snake games)

extension Boundary {
    /// Classic monochrome handheld palette: near-black olive "ink" on a pale grey-green backlight.
    static let lcdInk = PColor(red: 0.11, green: 0.14, blue: 0.07, alpha: 1)
    static let lcdGlass = PColor(red: 0.60, green: 0.68, blue: 0.47, alpha: 1)
    private static func lcdTexture(height: Bool) -> CGImage {
        Tex.image(64, 64) { c in   // 4x4 square pixels per face; the gaps show the backlight
            c.setFillColor((height ? PColor(white: 0.15, alpha: 1) : lcdGlass).cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            c.setFillColor((height ? PColor(white: 0.85, alpha: 1) : lcdInk).cgColor)
            for i in 0..<4 { for j in 0..<4 { c.fill(CGRect(x: i * 16 + 1, y: j * 16 + 1, width: 14, height: 14)) } }
        }
    }
    static let pixelMat: SCNMaterial = {
        let m = Mat.pbr(.white, rough: 0.92)          // flat, matte, no gloss — like an LCD segment
        m.diffuse.contents = lcdTexture(height: false)
        m.diffuse.magnificationFilter = .nearest
        m.normal.contents = lcdTexture(height: true); m.normal.intensity = 0.5
        return m
    }()
    private static let blockGeo: SCNBox = {
        let b = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.12)   // the original first-build stone block
        b.materials = [Mat.stone]
        return b
    }()

    /// One chunky block per wall cell, with a small raised "pixel" stud on top.
    static func retroBlock(_ rng: inout SeededRNG) -> SCNNode {
        let n = SCNNode()
        let b = SCNNode(geometry: blockGeo); b.position = v3(0, 0.5, 0); n.addChildNode(b)
        n.enumerateHierarchy { c, _ in c.castsShadow = true }
        return n
    }
}
