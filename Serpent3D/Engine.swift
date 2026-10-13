import SceneKit
import SwiftUI

enum CameraMode: Int, CaseIterable { case classic, chaser, firstPerson
    var label: String { ["Classic", "3D Chaser", "First Person"][rawValue] }
}

enum Input {
    case dir(Dir), boostIfHeading(Dir), turnLeft, turnRight, boost(Bool), pause(Bool), togglePause
    case start(GameConfig), prefs(RenderPrefs)
}

struct RenderPrefs: Equatable {
    var camera: CameraMode = .classic
    var color = 0
    var overview = true
}

struct MiniMap: Equatable {
    var walls: [P] = [], player: [P] = [], cpu: [P] = [], food: [P] = [], items: [P] = []
}

@Observable final class HUDState {
    var score = 0
    var level = 1
    var length = 0
    var target = 0
    var timeLeft: Double = 0
    var over = false
    var paused = false
    var gateOpen = false
    var arrows = 0
    var serums = 0
    var slow = false
    var fast = false
    var stunned = false
    var message = ""
    var messageID = 0
    var mini = MiniMap()
    var running = false   // a real (non-demo) game is in progress
}

/// Owns the game simulation and the SceneKit scene. All simulation and node updates run on
/// SceneKit's render thread; UI threads communicate through `post(_:)` and `hud`.
final class Engine: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let hud = HUDState()
    private(set) var game = Game(config: GameConfig(mode: .classic, demo: true))
    private var prefs = RenderPrefs()

    private let lock = NSLock()
    private var inbox: [Input] = []

    private let cameraNode = SCNNode()
    private let world = SCNNode()
    private var wallNodes = SCNNode()
    private var wallKey = ""
    private var foodNodes: [P: SCNNode] = [:]
    private var obstacleNodes: [P: SCNNode] = [:]
    private var specialNodes: [P: SCNNode] = [:]
    private var snakeViews: [SnakeView] = []
    private var lastTime: TimeInterval = 0
    private var acc: Double = 0
    private var heading: Float = 0
    private var camPos = SCNVector3(0, 30, 20)
    private var camLook = SCNVector3(0, 0, 0)
    private var lastTick = -1
    private var ready: Double = 0   // seconds left before the player's snake starts moving

    override init() {
        super.init()
        buildScene()
    }

    func post(_ i: Input) { lock.lock(); inbox.append(i); lock.unlock() }

    // MARK: Scene setup

    private func buildScene() {
        let sky = Tex.sky()
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = 1.2
        scene.rootNode.addChildNode(world)

        let n = CGFloat(Arena.size)
        let floor = SCNBox(width: n, height: 0.4, length: n, chamferRadius: 0.1)
        let fm = Mat.pbr(.white, rough: 0.9)
        fm.diffuse.contents = Tex.meadow(height: false)
        fm.normal.contents = Tex.meadow(height: true)
        fm.normal.intensity = 0.8
        for p in [fm.diffuse, fm.normal] {
            p.contentsTransform = SCNMatrix4MakeScale(SCNFloat(n / 4), SCNFloat(n / 4), 1)
            p.wrapS = .repeat; p.wrapT = .repeat
        }
        let side = Mat.pbr(PColor(red: 0.40, green: 0.28, blue: 0.18, alpha: 1), rough: 1)
        floor.materials = [side, side, side, side, fm, side]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.2, 0)
        world.addChildNode(floorNode)

        let ground = SCNFloor()
        ground.reflectivity = 0
        let gm = Mat.pbr(.white, rough: 1)
        gm.diffuse.contents = Tex.forestFloor()
        gm.diffuse.wrapS = .repeat; gm.diffuse.wrapT = .repeat
        gm.diffuse.contentsTransform = SCNMatrix4MakeScale(12, 12, 1)
        ground.materials = [gm]
        let groundNode = SCNNode(geometry: ground)
        groundNode.position = SCNVector3(0, -0.4, 0)
        world.addChildNode(groundNode)
        world.addChildNode(Scenery.build(arenaSize: Arena.size))
        world.addChildNode(wallNodes)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1300
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowSampleCount = 8
        sun.shadowRadius = 4
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowColor = PColor(white: 0, alpha: 0.45)
        sun.orthographicScale = 16
        sun.automaticallyAdjustsShadowProjection = true
        let sunNode = SCNNode(); sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-1.05, 0.5, 0)
        scene.rootNode.addChildNode(sunNode)

        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 250
        amb.color = PColor(red: 0.75, green: 0.85, blue: 1, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        let cam = SCNCamera()
        cam.fieldOfView = 50
        cam.zNear = 0.1; cam.zFar = 200
        cam.wantsHDR = true
        cam.bloomIntensity = 0.6; cam.bloomThreshold = 0.9
        cam.vignettingIntensity = 0.4; cam.vignettingPower = 0.6
        #if os(macOS)
        cam.screenSpaceAmbientOcclusionIntensity = 0.6
        #endif
        #if targetEnvironment(simulator)
        cam.wantsHDR = false
        sun.castsShadow = false
        #endif
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        scene.fogColor = PColor(red: 0.62, green: 0.80, blue: 0.95, alpha: 1)
        rebuildAll()
    }

    var pointOfView: SCNNode { cameraNode }

    static func world(_ p: P) -> SCNVector3 {
        let h = Float(Arena.size) / 2 - 0.5
        return SCNVector3(Float(p.x) - h, 0, Float(p.y) - h)
    }

    private func rebuildAll() {
        for n in foodNodes.values { n.removeFromParentNode() }
        for n in obstacleNodes.values { n.removeFromParentNode() }
        for n in specialNodes.values { n.removeFromParentNode() }
        foodNodes = [:]; obstacleNodes = [:]; specialNodes = [:]
        for v in snakeViews { v.root.removeFromParentNode() }
        snakeViews = game.snakes.enumerated().map { i, _ in
            let v = SnakeView(colorIndex: game.config.demo ? i : (prefs.color + i) % 3)
            world.addChildNode(v.root); return v
        }
        wallKey = ""
        syncStatic()
        if let h = game.snakes.first { heading = h.dir.angle }
        acc = 0
    }

    private func syncStatic() {
        let key = "\(game.arena.name)-\(game.level)-\(game.walls.count)"
        if key != wallKey {
            wallKey = key
            wallNodes.removeFromParentNode()
            wallNodes = SCNNode()
            var rng = SeededRNG(seed: UInt64(game.level * 31 + game.walls.count))
            let gateGeo = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.12)
            gateGeo.materials = [Mat.pbr(PColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1), rough: 0.4, emission: PColor(red: 0.5, green: 0.08, blue: 0.05, alpha: 1))]
            for p in game.walls {
                var w = Engine.world(p)
                if game.config.mode == .adventure && Arena.gate.contains(p) {
                    let g = SCNNode(geometry: gateGeo); w.y = 0.5; g.position = w; g.castsShadow = true
                    wallNodes.addChildNode(g); continue
                }
                let horiz = game.walls.contains(P(x: p.x - 1, y: p.y)) || game.walls.contains(P(x: p.x + 1, y: p.y))
                let vert = game.walls.contains(P(x: p.x, y: p.y - 1)) || game.walls.contains(P(x: p.x, y: p.y + 1))
                let piece = Boundary.retroBlock(&rng)
                _ = (horiz, vert)
                piece.position = w
                wallNodes.addChildNode(piece)
            }
            world.addChildNode(wallNodes)
        }
        diff(game.foods, &foodNodes) { Models.food($0) }
        diff(game.obstacles.mapValues { $0.kind }, &obstacleNodes) { Models.obstacle($0) }
        diff(game.specials.mapValues { $0.kind }, &specialNodes) { Models.special($0) }
    }

    private func diff<K: Equatable>(_ src: [P: K], _ nodes: inout [P: SCNNode], make: (K) -> SCNNode) {
        for (p, n) in nodes where src[p] == nil {
            n.runAction(.sequence([.scale(to: 0.01, duration: 0.15), .removeFromParentNode()]))
            nodes[p] = nil
        }
        for (p, k) in src where nodes[p] == nil {
            let n = make(k)
            n.position = Engine.world(p)
            n.scale = SCNVector3(0.01, 0.01, 0.01)
            n.runAction(.scale(to: 1, duration: 0.25))
            world.addChildNode(n)
            nodes[p] = n
        }
    }

    // MARK: Render loop

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime == 0 ? 0 : min(time - lastTime, 0.1)
        lastTime = time
        drainInbox()

        if ready > 0 && !game.paused { ready -= dt; if ready <= 0 { say("Go!") } }
        if !game.over && !game.paused && ready <= 0 {
            acc += dt
            var guardSteps = 0
            while acc >= game.interval && guardSteps < 4 {
                acc -= game.interval
                let level = game.level
                game.step()
                guardSteps += 1
                if game.level != level { rebuildAll() }
                handleEvents()
                syncStatic()
                if game.over { break }
            }
            if game.config.demo, game.snakes.allSatisfy({ !$0.alive }) { game.over = false }
        }
        let t = Float(game.over || game.paused ? 1 : min(acc / game.interval, 1))
        for (i, s) in game.snakes.enumerated() where i < snakeViews.count { snakeViews[i].update(s, t: t) }
        updateCamera(renderer, t: t, dt: Float(dt))
        pushHUD()
    }

    private func drainInbox() {
        lock.lock(); let items = inbox; inbox = []; lock.unlock()
        for i in items {
            switch i {
            case .start(let c):
                game = Game(config: c); rebuildAll()
                if !c.demo { ready = 2; say("Ready…"); Audio.shared.play(.ready) }
            case .prefs(let p):
                let recolor = p.color != prefs.color
                prefs = p
                if recolor, !game.config.demo, let v = snakeViews.first { v.setColor(p.color) }
            case .pause(let b): if !game.config.demo && !game.over { game.paused = b }
            case .togglePause: if !game.config.demo && !game.over { game.paused.toggle() }
            case .boost(let b): game.boost = b
            case .boostIfHeading(let d): if game.player?.dir == d { game.boost = true }
            case .dir(let d):
                guard let s = game.player, !game.paused else { continue }
                if ready > 0 { ready = 0; say("Go!") }
                if prefs.camera == .classic { s.enqueue(d) }
                else { switch d { case .left: s.enqueue((s.queue.last ?? s.dir).ccw); case .right: s.enqueue((s.queue.last ?? s.dir).cw); default: break } }
            case .turnLeft, .turnRight:
                guard let s = game.player, !game.paused else { continue }
                if ready > 0 { ready = 0; say("Go!") }
                let cur = s.queue.last ?? s.dir
                if case .turnLeft = i { s.enqueue(cur.ccw) } else { s.enqueue(cur.cw) }
            }
        }
    }

    private func handleEvents() {
        let mineHead = game.player?.head
        for e in game.events {
            switch e {
            case .ate(let p, let f):
                burst(at: p, color: Models.foodColor(f))
                if p == mineHead { if f != .mushroom { Audio.shared.play(.eat) }; Haptics.tap(0.5) }
            case .special(let p, let s):
                burst(at: p, color: Models.specialColor(s), count: 60)
                if p == mineHead {
                    Audio.shared.play(s == .flash ? .speed : s == .snail ? .slow : .special); say(s.name + "!")
                }
            case .crushed(let p): burst(at: p, color: PColor(white: 0.7, alpha: 1), count: 50); Audio.shared.play(.crush)
            case .bonus(_, let b): say("+\(b)")
            case .bite(let p): burst(at: p, color: .green); Audio.shared.play(.bite)
            case .crash(let p):
                burst(at: p, color: .orange, count: 80)
                if game.player != nil && game.player?.alive == false {
                    Audio.shared.play(.crash); Haptics.tap(1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Audio.shared.play(.gameOver) }
                }
            case .gateOpened: Audio.shared.play(.gate); say("Gate open — head north!")
            case .levelComplete: Audio.shared.play(.win); say("Level \(game.level)")
            case .stunned: say("Dizzy…"); Audio.shared.play(.stun)
            }
        }
        game.events.removeAll()
    }

    private func say(_ text: String) {
        DispatchQueue.main.async { self.hud.message = text; self.hud.messageID += 1 }
    }

    private func burst(at p: P, color: PColor, count: Int = 36) {
        let ps = SCNParticleSystem()
        ps.particleImage = Tex.dot
        ps.birthRate = CGFloat(count) * 20
        ps.emissionDuration = 0.05
        ps.loops = false
        ps.particleLifeSpan = 0.6
        ps.particleLifeSpanVariation = 0.3
        ps.particleVelocity = 4
        ps.particleVelocityVariation = 2
        ps.spreadingAngle = 180
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.acceleration = SCNVector3(0, -9, 0)
        ps.particleSize = 0.12
        ps.particleColor = color
        ps.blendMode = .additive
        ps.isAffectedByGravity = false
        let node = SCNNode()
        var w = Engine.world(p); w.y = 0.5
        node.position = w
        node.addParticleSystem(ps)
        world.addChildNode(node)
        node.runAction(.sequence([.wait(duration: 1.2), .removeFromParentNode()]))
    }

    // MARK: Camera

    private func updateCamera(_ r: SCNSceneRenderer, t: Float, dt: Float) {
        let vp = r.currentViewport
        let aspect = vp.height > 0 ? Float(vp.width / vp.height) : 1
        let mode = game.config.demo ? CameraMode.classic : prefs.camera
        guard let s = game.snakes.first, let v = snakeViews.first else { return }
        let target = s.dir.angle
        var d = target - heading
        while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        heading += d * min(1, dt * 10)
        let fwd = SCNVector3(-sin(heading), 0, -cos(heading))
        let hp = v.headPosition
        var pos: SCNVector3, look: SCNVector3, k: Float
        switch mode {
        case .classic:
            let span: Float = 23
            let fov: Float = 50 * .pi / 180
            let fit = aspect < 1 ? span / aspect : span
            let dist = (fit / 2) / tan(fov / 2) * 1.02
            if game.config.demo {
                let a = Float(lastTime * 0.08)
                pos = SCNVector3(sin(a) * dist * 0.75, dist * 0.6, cos(a) * dist * 0.75); look = SCNVector3(0, -2, 0)
            } else {
                pos = SCNVector3(0, dist * 0.88, dist * 0.42); look = SCNVector3(0, 0, 0.9)
            }
            k = 1
        case .chaser:
            pos = hp - fwd * 5.5 + SCNVector3(0, 4.5, 0); look = hp + fwd * 3.5; k = min(1, dt * 6)
        case .firstPerson:
            pos = hp + SCNVector3(0, 0.75, 0) + fwd * 0.3; look = hp + fwd * 6 + SCNVector3(0, 0.25, 0); k = 1
        }
        camPos = camPos + (pos - camPos) * k
        camLook = camLook + (look - camLook) * k
        cameraNode.position = camPos
        cameraNode.look(at: camLook, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.fogStartDistance = mode == .classic ? 200 : 18
        scene.fogEndDistance = mode == .classic ? 300 : 45
    }

    // MARK: HUD

    private func pushHUD() {
        guard game.tickCount != lastTick || game.over != hud.over || game.paused != hud.paused else { return }
        lastTick = game.tickCount
        let g = game
        let pl = g.player
        var mini = MiniMap()
        if prefs.overview && prefs.camera != .classic {
            mini.walls = Array(g.walls); mini.player = pl?.body ?? []
            mini.cpu = g.snakes.dropFirst().filter(\.alive).flatMap(\.body)
            mini.food = Array(g.foods.keys); mini.items = Array(g.specials.keys) + Array(g.obstacles.keys)
        }
        let snap = (g.score, g.level, pl?.body.count ?? 0, g.target, g.timeLeft, g.over, g.paused, g.gateOpen,
                    pl?.arrows ?? 0, pl?.serums ?? 0, g.slowTicks > 0, g.fastTicks > 0, (pl?.stun ?? 0) > 0, !g.config.demo)
        DispatchQueue.main.async {
            let h = self.hud
            h.score = snap.0; h.level = snap.1; h.length = snap.2; h.target = snap.3; h.timeLeft = snap.4
            h.over = snap.5; h.paused = snap.6; h.gateOpen = snap.7; h.arrows = snap.8; h.serums = snap.9
            h.slow = snap.10; h.fast = snap.11; h.stunned = snap.12; h.running = snap.13
            if h.mini != mini { h.mini = mini }
        }
    }
}

