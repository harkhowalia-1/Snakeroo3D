import Foundation

// MARK: - Basic types

struct P: Hashable, Codable {
    var x: Int, y: Int
    static func + (a: P, b: P) -> P { P(x: a.x + b.x, y: a.y + b.y) }
}

enum Dir: Int, CaseIterable {
    case up, right, down, left
    var delta: P { [P(x: 0, y: -1), P(x: 1, y: 0), P(x: 0, y: 1), P(x: -1, y: 0)][rawValue] }
    var cw: Dir { Dir(rawValue: (rawValue + 1) % 4)! }
    var ccw: Dir { Dir(rawValue: (rawValue + 3) % 4)! }
    var opposite: Dir { Dir(rawValue: (rawValue + 2) % 4)! }
    /// Heading angle around the vertical axis (radians), 0 = facing -z (up).
    var angle: Float { -Float(rawValue) * .pi / 2 }
}

enum GameMode: String, Codable, CaseIterable { case classic, adventure, custom }

enum FoodKind: Int, CaseIterable {
    case apple, cherry, pear, mushroom
    var points: Int { [5, 10, 15, 0][rawValue] }
}

enum Special: Int, CaseIterable {
    case snail, flash, serum, twister, arrow, diet
    var name: String { ["Snail", "Flash", "Serum", "Twister", "Arrow", "Diet"][rawValue] }
    var points: Int { 25 }
}

enum ObstacleKind { case stone, crate }

enum Loot { case none, bonus(Int), special(Special) }

struct Obstacle { var kind: ObstacleKind; var loot: Loot }

enum Growth: Int, CaseIterable { case slow, normal, fast, random
    var label: String { ["Slow", "Normal", "Fast", "Random"][rawValue] }
}
enum FoodAmount: Int, CaseIterable { case few, normal, plenty
    var label: String { ["Few", "Normal", "Plenty"][rawValue] }
    var count: Int { [1, 3, 6][rawValue] }
}

struct GameConfig {
    var mode: GameMode = .classic
    var arena = 0
    var food: FoodAmount = .few
    var growth: Growth = .normal
    var obstacles = false
    var specials = false
    var speed = 5            // 1...9
    var vsCPU = false
    var demo = false         // attract mode: CPU only
}

// MARK: - Arenas

struct Arena {
    let name: String
    let walls: Set<P>
    let wraps: Bool
    static let size = 20

    static let all: [Arena] = {
        let n = size
        func border() -> Set<P> {
            var s = Set<P>()
            for i in 0..<n { s.insert(P(x: i, y: 0)); s.insert(P(x: i, y: n - 1)); s.insert(P(x: 0, y: i)); s.insert(P(x: n - 1, y: i)) }
            return s
        }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Set<P> {
            var s = Set<P>(); for i in x..<x + w { for j in y..<y + h { s.insert(P(x: i, y: j)) } }; return s
        }
        var courtyard = border()
        for (x, y) in [(3, 3), (13, 3), (3, 13), (13, 13)] {
            courtyard.formUnion(rect(x, y, 4, 1)); courtyard.formUnion(rect(x + (x < 10 ? 0 : 3), y + (y < 10 ? 0 : -3), 1, 4))
        }
        var cross = border()
        cross.formUnion(rect(9, 4, 2, 4)); cross.formUnion(rect(9, 12, 2, 4))
        cross.formUnion(rect(4, 9, 4, 2)); cross.formUnion(rect(12, 9, 4, 2))
        var pillars = border()
        for x in [4, 9, 14] { for y in [4, 9, 14] where !(x == 9 && y == 9) { pillars.formUnion(rect(x, y, 2, 2)) } }
        var canyon = border()
        canyon.formUnion(rect(1, 6, 7, 1)); canyon.formUnion(rect(12, 6, 7, 1))
        canyon.formUnion(rect(4, 13, 12, 1))
        var spiral = border()
        spiral.formUnion(rect(4, 4, 12, 1)); spiral.formUnion(rect(15, 4, 1, 10))
        spiral.formUnion(rect(7, 15, 9, 1)); spiral.formUnion(rect(4, 7, 1, 9))
        spiral.formUnion(rect(7, 8, 1, 5)); spiral.formUnion(rect(7, 8, 5, 1))
        return [
            Arena(name: "Meadow", walls: border(), wraps: false),
            Arena(name: "Eden", walls: [], wraps: true),
            Arena(name: "Courtyard", walls: courtyard, wraps: false),
            Arena(name: "Crossroads", walls: cross, wraps: false),
            Arena(name: "Pillars", walls: pillars, wraps: false),
            Arena(name: "Canyon", walls: canyon, wraps: false),
            Arena(name: "Spiral", walls: spiral, wraps: false),
        ]
    }()

    /// The 3 cells in the top wall that open in adventure mode.
    static let gate: Set<P> = [P(x: 9, y: 0), P(x: 10, y: 0), P(x: 11, y: 0)]
}

// MARK: - Snake

final class Snake {
    var body: [P]
    var prevBody: [P]
    var dir: Dir
    var queue: [Dir] = []
    var grow = 0
    var alive = true
    var isAI: Bool
    var stun = 0
    var arrows = 0
    var serums = 0
    var bridged = false      // head currently passing over own body via Arrow
    var snap = false         // renderer should not interpolate this tick
    var respawn = 0

    init(head: P, dir: Dir, length: Int, ai: Bool) {
        self.dir = dir; isAI = ai
        body = (0..<length).map { P(x: head.x - dir.delta.x * $0, y: head.y - dir.delta.y * $0) }
        prevBody = body
    }
    var head: P { body[0] }

    func enqueue(_ d: Dir) {
        let last = queue.last ?? dir
        guard d != last, d != last.opposite, queue.count < 3 else { return }
        queue.append(d)
    }
}

// MARK: - Events (consumed by renderer / audio)

enum GameEvent {
    case ate(P, FoodKind), special(P, Special), crushed(P), bonus(P, Int)
    case crash(P), gateOpened, levelComplete, bite(P), stunned
}

// MARK: - Game

final class Game {
    let N = Arena.size
    var config: GameConfig
    var arena: Arena
    var walls: Set<P>
    var snakes: [Snake] = []
    var foods: [P: FoodKind] = [:]
    var obstacles: [P: Obstacle] = [:]
    var specials: [P: (kind: Special, ttl: Int)] = [:]
    var score = 0
    var level = 1
    var over = false
    var won = false
    var paused = false
    var gateOpen = false
    var timeLeft: Double = 0
    var slowTicks = 0, fastTicks = 0
    var tickCount = 0
    var events: [GameEvent] = []
    var boost = false
    var rng = SystemRandomNumberGenerator()

    var player: Snake? { config.demo ? nil : snakes.first }
    var target: Int { 8 + level * 4 }

    init(config: GameConfig) {
        self.config = config
        arena = Arena.all[0]; walls = []
        setupLevel()
    }

    private func adventureArena(_ level: Int) -> Int { [0, 2, 3, 4, 5, 6][(level - 1) % 6] }

    func setupLevel() {
        let idx: Int
        switch config.mode {
        case .classic: idx = config.demo ? 2 : 0
        case .adventure: idx = adventureArena(level)
        case .custom: idx = config.arena
        }
        arena = Arena.all[idx]
        walls = arena.walls
        gateOpen = false
        foods = [:]; obstacles = [:]; specials = [:]
        slowTicks = 0; fastTicks = 0
        snakes = [Snake(head: P(x: 5, y: 17), dir: .right, length: 4, ai: config.demo)]
        if config.vsCPU || config.demo { snakes.append(Snake(head: P(x: 14, y: 2), dir: .left, length: 4, ai: true)) }
        // Clear any wall under the spawn columns for custom arenas.
        for s in snakes { for c in s.body { walls.remove(c) } }
        if config.mode == .adventure { timeLeft = 60 + Double(level) * 8 }
        let wantObstacles = config.mode == .adventure ? level > 1 : (config.mode == .custom && config.obstacles)
        if wantObstacles { for _ in 0..<(config.mode == .adventure ? min(2 + level, 8) : 5) { placeObstacle() } }
        refillFood()
    }

    var foodTarget: Int { config.mode == .custom ? config.food.count : (config.demo ? 3 : 1) }
    var specialsOn: Bool { config.mode == .adventure || (config.mode == .custom && config.specials) || config.demo }

    // Tick interval in seconds.
    var interval: Double {
        let lvl = config.mode == .adventure ? min(3 + level, 9) : config.speed
        var t = 0.26 - Double(lvl) * 0.02
        if slowTicks > 0 { t *= 1.7 }
        if fastTicks > 0 { t *= 0.6 }
        if boost, player?.isAI == false { t *= 0.5 }
        return t
    }

    // MARK: occupancy

    func occupied(_ p: P) -> Bool {
        walls.contains(p) || foods[p] != nil || obstacles[p] != nil || specials[p] != nil || snakes.contains { $0.body.contains(p) }
    }

    func randomFree() -> P? {
        for _ in 0..<400 {
            let p = P(x: Int.random(in: 0..<N, using: &rng), y: Int.random(in: 0..<N, using: &rng))
            if !occupied(p), !nearHead(p) { return p }
        }
        return nil
    }
    private func nearHead(_ p: P) -> Bool { snakes.contains { abs($0.head.x - p.x) + abs($0.head.y - p.y) < 3 } }

    func refillFood() {
        while foods.count < foodTarget, let p = randomFree() {
            let r = Int.random(in: 0..<100, using: &rng)
            foods[p] = r < 50 ? .apple : r < 78 ? .cherry : r < 92 ? .pear : .mushroom
        }
    }

    func placeObstacle() {
        guard let p = randomFree(), p.x > 1, p.y > 1, p.x < N - 2, p.y < N - 2 else { return }
        let loot: Loot = specialsOn && Bool.random() ? .special(Special.allCases.randomElement()!) : .bonus(50)
        obstacles[p] = Obstacle(kind: Bool.random() ? .stone : .crate, loot: loot)
    }

    func wrap(_ p: P) -> P { P(x: (p.x + N) % N, y: (p.y + N) % N) }
    func inBounds(_ p: P) -> Bool { p.x >= 0 && p.y >= 0 && p.x < N && p.y < N }

    // MARK: step

    func step() {
        guard !over, !paused else { return }
        tickCount += 1
        if slowTicks > 0 { slowTicks -= 1 }
        if fastTicks > 0 { fastTicks -= 1 }
        if config.mode == .adventure && !config.demo {
            timeLeft -= interval
            if timeLeft <= 0 { timeLeft = 0; endGame(); return }
        }

        for s in snakes { s.prevBody = s.body; s.snap = false }

        // Respawn dead CPU opponents.
        for s in snakes where !s.alive && s.isAI {
            s.respawn -= 1
            if s.respawn <= 0, let p = randomFree(), inBounds(p + P(x: 0, y: 3)) {
                let fresh = Snake(head: p, dir: .up, length: 4, ai: true)
                if fresh.body.allSatisfy({ !occupied($0) || $0 == p }) {
                    s.body = fresh.body; s.prevBody = fresh.body; s.dir = .up; s.alive = true; s.snap = true; s.queue = []
                }
            }
        }

        for s in snakes where s.alive {
            if s.isAI { if let d = aiChoose(s) { s.queue = [d] } }
            if let d = s.queue.first { s.queue.removeFirst(); if d != s.dir.opposite { s.dir = d } }
        }

        // Compute heads
        var moves: [(Snake, P)] = []
        for s in snakes where s.alive {
            if s.stun > 0 { s.stun -= 1; continue }
            var next = s.head + s.dir.delta
            if !inBounds(next) {
                if gateOpen && s === player && next.y < 0 { levelComplete(); return }
                if arena.wraps { next = wrap(next); s.snap = true } else { kill(s, at: s.head); continue }
            }
            moves.append((s, next))
        }

        // Resolve collisions
        for (s, next) in moves {
            if walls.contains(next) || obstacles[next] != nil { kill(s, at: next); continue }
            if moves.contains(where: { $0.0 !== s && $0.1 == next }) { kill(s, at: next); continue }
            var hit = false
            for o in snakes where o.alive {
                // The tail cell vacates this tick unless growing.
                let cells = (o.grow == 0) ? o.body.dropLast() : o.body[...]
                guard let idx = cells.firstIndex(of: next) else { continue }
                if o === s && s.arrows > 0 && idx > 0 {
                    s.arrows -= 1; s.bridged = true
                } else if s.serums > 0 && idx > 0 {
                    s.serums -= 1
                    o.body.removeSubrange(idx...)
                    if o.body.count < 2 { o.alive = false; o.respawn = 30 }
                    events.append(.bite(next)); if s === player { score += 20 }
                } else { hit = true }
                break
            }
            if hit { kill(s, at: next); continue }
            s.body.insert(next, at: 0)
            if s.grow > 0 { s.grow -= 1 } else { s.body.removeLast() }
            consume(s, at: next)
        }

        crushEnclosedObstacles()

        // Specials expire / spawn
        for (p, v) in specials { if v.ttl <= 1 { specials[p] = nil } else { specials[p]!.ttl = v.ttl - 1 } }
        if specialsOn && specials.count < 1 && Int.random(in: 0..<90, using: &rng) == 0, let p = randomFree() {
            specials[p] = (Special.allCases.randomElement()!, 70)
        }
        refillFood()

        if config.mode == .adventure, !gateOpen, let pl = player, pl.body.count >= target {
            gateOpen = true
            for g in Arena.gate { walls.remove(g) }
            events.append(.gateOpened)
        }
    }

    private func consume(_ s: Snake, at p: P) {
        let mine = s === player
        if let f = foods.removeValue(forKey: p) {
            if f == .mushroom { s.stun = 6; if mine { events.append(.stunned) } }
            let g: Int
            switch config.growth { case .slow: g = 1; case .normal: g = 2; case .fast: g = 4; case .random: g = Int.random(in: 1...4) }
            s.grow += (f == .mushroom ? 0 : g)
            if mine { score += f.points * (config.mode == .adventure ? level : 1) }
            events.append(.ate(p, f))
        }
        if let sp = specials.removeValue(forKey: p) { apply(sp.kind, to: s, at: p) }
    }

    private func apply(_ sp: Special, to s: Snake, at p: P) {
        if s === player { score += sp.points }
        events.append(.special(p, sp))
        switch sp {
        case .snail: slowTicks = 50; fastTicks = 0
        case .flash: fastTicks = 60; slowTicks = 0
        case .diet: if s.body.count > 4 { s.body.removeLast(s.body.count / 2 - 1) }; s.grow = 0
        case .arrow: s.arrows += 1
        case .serum: s.serums += 1
        case .twister:
            s.body.reverse(); s.snap = true
            if s.body.count > 1 {
                let a = s.body[0], b = s.body[1]
                var dx = a.x - b.x, dy = a.y - b.y
                if abs(dx) > 1 { dx = -dx.signum() }; if abs(dy) > 1 { dy = -dy.signum() }
                s.dir = Dir.allCases.first { $0.delta == P(x: dx, y: dy) } ?? s.dir.opposite
            }
            s.queue = []
        }
    }

    /// Obstacles cut off from the arena edge by snake bodies are crushed.
    private func crushEnclosedObstacles() {
        guard !obstacles.isEmpty else { return }
        var blocked = Set<P>()
        for s in snakes where s.alive { blocked.formUnion(s.body) }
        var seen = Set<P>(), stack: [P] = []
        for i in 0..<N { for p in [P(x: i, y: 0), P(x: i, y: N - 1), P(x: 0, y: i), P(x: N - 1, y: i)] where !blocked.contains(p) && !seen.contains(p) { seen.insert(p); stack.append(p) } }
        while let c = stack.popLast() {
            for d in Dir.allCases {
                let n = c + d.delta
                if inBounds(n), !blocked.contains(n), !seen.contains(n) { seen.insert(n); stack.append(n) }
            }
        }
        for (p, o) in obstacles where !seen.contains(p) {
            obstacles[p] = nil
            events.append(.crushed(p))
            switch o.loot {
            case .none: break
            case .bonus(let b): score += b; events.append(.bonus(p, b))
            case .special(let sp): specials[p] = (sp, 90)
            }
        }
    }

    private func kill(_ s: Snake, at p: P) {
        s.alive = false
        events.append(.crash(p))
        if s.isAI { s.respawn = config.demo ? 10 : 25; return }
        endGame()
    }

    private func endGame() { over = true }

    private func levelComplete() {
        score += Int(timeLeft) * 2 + 100
        level += 1
        events.append(.levelComplete)
        setupLevel()
        for s in snakes { s.snap = true }
    }

    // MARK: AI

    func aiChoose(_ s: Snake) -> Dir? {
        var blocked = walls.union(obstacles.keys)
        for o in snakes where o.alive { blocked.formUnion(o.body.dropLast()) }
        func nextCell(_ p: P, _ d: Dir) -> P? {
            var n = p + d.delta
            if !inBounds(n) { guard arena.wraps else { return nil }; n = wrap(n) }
            return blocked.contains(n) ? nil : n
        }
        let options = [s.dir, s.dir.ccw, s.dir.cw].filter { nextCell(s.head, $0) != nil }
        guard !options.isEmpty else { return nil }
        // BFS to nearest non-mushroom food or special
        let goals = Set(foods.filter { $0.value != .mushroom }.keys).union(specials.keys)
        var first: [P: Dir] = [:], queue: [P] = []
        for d in options { let n = nextCell(s.head, d)!; first[n] = d; queue.append(n) }
        var i = 0
        while i < queue.count {
            let c = queue[i]; i += 1
            if goals.contains(c), let d = first[c], area(from: nextCell(s.head, d)!, blocked: blocked) > s.body.count { return d }
            for d in Dir.allCases { if let n = nextCell(c, d), first[n] == nil { first[n] = first[c]; queue.append(n) } }
        }
        return options.max { area(from: nextCell(s.head, $0)!, blocked: blocked) < area(from: nextCell(s.head, $1)!, blocked: blocked) }
    }

    private func area(from p: P, blocked: Set<P>) -> Int {
        var seen: Set<P> = [p], stack = [p]
        while let c = stack.popLast(), seen.count < 120 {
            for d in Dir.allCases {
                var n = c + d.delta
                if !inBounds(n) { if arena.wraps { n = wrap(n) } else { continue } }
                if !blocked.contains(n), seen.insert(n).inserted { stack.append(n) }
            }
        }
        return seen.count
    }
}
