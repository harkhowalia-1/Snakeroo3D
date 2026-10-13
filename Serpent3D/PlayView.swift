import SwiftUI

struct PlayView: View {
    let engine: Engine
    let config: GameConfig
    let onRestart: () -> Void
    let onQuit: () -> Void

    @AppStorage("camera") private var camera = 0
    @AppStorage("speedUp") private var speedUp = true
    @AppStorage("name") private var name = "Player"
    @FocusState private var focused: Bool
    @State private var toast = ""
    @State private var rank: Int?? = nil
    @State private var dragAnchor: CGPoint?
    @State private var touchBegan = false

    private var hud: HUDState { engine.hud }
    private var classic: Bool { camera == CameraMode.classic.rawValue }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Touch surface
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in touch(v, width: geo.size.width) }
                        .onEnded { _ in dragAnchor = nil; touchBegan = false })

                VStack(spacing: 10) {
                    topBar
                    if config.mode == .adventure { adventureBar }
                    if !toast.isEmpty {
                        Text(toast).font(.system(.title2, design: .rounded).weight(.heavy))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        if !hud.mini.walls.isEmpty || !hud.mini.player.isEmpty { MiniMapView(map: hud.mini).frame(width: 130, height: 130) }
                        Spacer()
                        if speedUp { boostButton }
                    }
                }
                .padding()
                .allowsHitTesting(!hud.over && !hud.paused ? true : false)

                if hud.paused && !hud.over { pauseCard }
                if hud.over { overCard }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; rank = nil }
        .onKeyPress(phases: [.down, .up]) { key($0) }
        .onChange(of: hud.messageID) {
            withAnimation(.spring(duration: 0.3)) { toast = hud.message }
            let id = hud.messageID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if hud.messageID == id { withAnimation { toast = "" } } }
        }
        .onChange(of: hud.over) {
            if hud.over && hud.running && rank == nil {
                rank = .some(HighScores.submit(config.mode, ScoreEntry(name: name.isEmpty ? "Player" : name, score: hud.score, level: hud.level, date: .now)))
            }
        }
    }

    // MARK: HUD pieces

    private var topBar: some View {
        HStack(spacing: 12) {
            stat("SCORE", String(format: "%06d", hud.score))
            stat("LENGTH", config.mode == .adventure ? "\(hud.length)/\(hud.target)" : "\(hud.length)")
            if config.mode == .adventure { stat("LEVEL", "\(hud.level)") }
            HStack(spacing: 8) {
                if hud.arrows > 0 { badge("arrow.up.forward", hud.arrows, .cyan) }
                if hud.serums > 0 { badge("syringe.fill", hud.serums, .green) }
                if hud.slow { badge("tortoise.fill", 0, .purple) }
                if hud.fast { badge("bolt.fill", 0, .yellow) }
                if hud.stunned { badge("sparkles", 0, .orange) }
            }
            Spacer()
            Button { engine.post(.togglePause) } label: {
                Image(systemName: "pause.fill").font(.title3.bold()).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(v).font(.system(.title3, design: .rounded).weight(.heavy)).monospacedDigit().contentTransition(.numericText())
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func badge(_ icon: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 2) { Image(systemName: icon); if n > 1 { Text("\(n)").bold() } }
            .font(.callout).foregroundStyle(c).padding(8).background(.ultraThinMaterial, in: Capsule())
    }

    private var adventureBar: some View {
        let total = 60 + Double(hud.level) * 8
        return VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(hud.timeLeft < 10 ? Color.red : .green)
                        .frame(width: max(0, g.size.width * hud.timeLeft / total))
                }
            }.frame(height: 8)
            Text(hud.gateOpen ? "Gate open — exit north!" : "Reach length \(hud.target) to open the gate  ·  \(Int(hud.timeLeft))s")
                .font(.caption.bold()).foregroundStyle(hud.gateOpen ? .green : .white.opacity(0.8))
        }
        .frame(maxWidth: 420)
    }

    private var boostButton: some View {
        Image(systemName: "bolt.fill").font(.title.bold()).foregroundStyle(.yellow)
            .frame(width: 72, height: 72).background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.yellow.opacity(0.4)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in engine.post(.boost(true)) }
                .onEnded { _ in engine.post(.boost(false)) })
    }

    private var pauseCard: some View {
        Panel(title: "Paused") {
            MenuButton(title: "Resume", icon: "play.fill", prominent: true) { engine.post(.pause(false)); focused = true }
                .keyboardShortcut(.defaultAction)
            MenuButton(title: "Restart", icon: "arrow.clockwise") { onRestart() }
            MenuButton(title: "Quit to Menu", icon: "house.fill") { onQuit() }
        }
    }

    private var overCard: some View {
        Panel(title: "Game Over") {
            VStack(spacing: 6) {
                Text("\(hud.score)").font(.system(size: 64, weight: .black, design: .rounded)).monospacedDigit()
                if case .some(.some(let r)) = rank {
                    Label(r == 0 ? "New high score!" : "Rank #\(r + 1)", systemImage: "trophy.fill").foregroundStyle(.yellow).bold()
                }
                if config.mode == .adventure { Text("Reached level \(hud.level)").foregroundStyle(.secondary) }
            }
            MenuButton(title: "Play Again", icon: "arrow.clockwise", prominent: true) { rank = nil; onRestart() }
                .keyboardShortcut(.defaultAction)
            MenuButton(title: "Menu", icon: "house.fill") { onQuit() }
        }
    }

    // MARK: Input

    private func touch(_ v: DragGesture.Value, width: CGFloat) {
        guard !hud.over, !hud.paused else { return }
        if !classic {
            if !touchBegan { touchBegan = true; engine.post(v.startLocation.x < width / 2 ? .turnLeft : .turnRight) }
            return
        }
        let anchor = dragAnchor ?? v.startLocation
        if dragAnchor == nil { dragAnchor = anchor }
        let dx = v.location.x - anchor.x, dy = v.location.y - anchor.y
        guard max(abs(dx), abs(dy)) > 22 else { return }
        engine.post(.dir(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)))
        dragAnchor = v.location
    }

    private func key(_ k: KeyPress) -> KeyPress.Result {
        let down = k.phase == .down
        var d: Dir?
        switch k.key {
        case .upArrow: d = .up
        case .downArrow: d = .down
        case .leftArrow: d = .left
        case .rightArrow: d = .right
        case .space, .escape: if down { engine.post(.togglePause) }; return .handled
        default:
            switch k.characters.lowercased() {
            case "w": d = .up
            case "s": d = .down
            case "a": d = .left
            case "d": d = .right
            case "p": if down { engine.post(.togglePause) }; return .handled
            default: break
            }
        }
        if k.modifiers.contains(.shift) && speedUp { engine.post(.boost(down)) }
        guard let d else { return .ignored }
        if !down { engine.post(.boost(false)); return .handled }
        if classic {
            engine.post(.dir(d))
            // Holding the key of the current direction speeds up (repeat presses arrive as .down too).
            if speedUp { engine.post(.boostIfHeading(d)) }
        } else {
            switch d {
            case .left: engine.post(.turnLeft)
            case .right: engine.post(.turnRight)
            case .up: if speedUp { engine.post(.boost(true)) }
            case .down: break
            }
        }
        return .handled
    }
}

struct MiniMapView: View {
    let map: MiniMap
    var body: some View {
        Canvas { ctx, size in
            let c = size.width / CGFloat(Arena.size)
            func fill(_ ps: [P], _ color: Color, inset: CGFloat = 0) {
                var path = Path()
                for p in ps { path.addRect(CGRect(x: CGFloat(p.x) * c + inset, y: CGFloat(p.y) * c + inset, width: c - inset * 2, height: c - inset * 2)) }
                ctx.fill(path, with: .color(color))
            }
            fill(map.walls, .gray)
            fill(map.food, .red, inset: 1)
            fill(map.items, .yellow, inset: 1)
            fill(map.cpu, .orange)
            fill(map.player, .green)
            if let h = map.player.first { fill([h], .white) }
        }
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
