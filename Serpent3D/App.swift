import SwiftUI

#if os(macOS)
import AppKit
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quit when the window's close button is clicked instead of lingering in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

@main
struct Serpent3DApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            RootView()
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 540)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}

// MARK: - Persistence

struct ScoreEntry: Codable, Identifiable {
    var id = UUID()
    var name: String
    var score: Int
    var level: Int
    var date: Date
}

enum HighScores {
    static func list(_ m: GameMode) -> [ScoreEntry] {
        guard let d = UserDefaults.standard.data(forKey: "hs.\(m.rawValue)") else { return [] }
        return (try? JSONDecoder().decode([ScoreEntry].self, from: d)) ?? []
    }
    /// Returns the rank (0-based) if the score made the table.
    @discardableResult static func submit(_ m: GameMode, _ e: ScoreEntry) -> Int? {
        guard e.score > 0 else { return nil }
        var l = list(m); l.append(e); l.sort { $0.score > $1.score }; l = Array(l.prefix(10))
        UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: "hs.\(m.rawValue)")
        return l.firstIndex { $0.id == e.id }
    }
}

enum Screen { case menu, newGame, custom, settings, scores, help, play }

// MARK: - Root

struct RootView: View {
    @State private var engine = Engine()
    @State private var screen: Screen = .menu
    @State private var lastConfig = GameConfig()
    @Environment(\.scenePhase) private var phase

    @AppStorage("camera") private var camera = 0
    @AppStorage("color") private var color = 0
    @AppStorage("overview") private var overview = true
    @AppStorage("music") private var music = true
    @AppStorage("sound") private var sound = true

    var body: some View {
        ZStack {
            SceneHost(engine: engine).ignoresSafeArea()
            Group {
                switch screen {
                case .play:
                    PlayView(engine: engine, config: lastConfig, onRestart: { start(lastConfig) }, onQuit: { goMenu() })
                case .menu: MainMenu(go: { screen = $0 })
                case .newGame: NewGameMenu(go: { screen = $0 }, start: start)
                case .custom: CustomSetup(back: { screen = .newGame }, start: start)
                case .settings: SettingsView(back: { screen = .menu })
                case .scores: ScoresView(back: { screen = .menu })
                case .help: HelpView(back: { screen = .menu })
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: screen)
        .preferredColorScheme(.dark)
        .onAppear { pushPrefs(); Audio.shared.soundOn = sound; Audio.shared.musicOn = music; Audio.shared.startMusic() }
        .onChange(of: camera) { pushPrefs() }
        .onChange(of: color) { pushPrefs() }
        .onChange(of: overview) { pushPrefs() }
        .onChange(of: music) { Audio.shared.musicOn = music }
        .onChange(of: sound) { Audio.shared.soundOn = sound }
        .onChange(of: phase) { if phase != .active { engine.post(.pause(true)) } }
    }

    private func pushPrefs() {
        engine.post(.prefs(RenderPrefs(camera: CameraMode(rawValue: camera) ?? .classic, color: color, overview: overview)))
    }
    private func start(_ c: GameConfig) {
        lastConfig = c
        engine.post(.start(c))
        screen = .play
    }
    private func goMenu() {
        engine.post(.start(GameConfig(mode: .classic, demo: true)))
        screen = .menu
    }
}

// MARK: - Shared styling

struct Panel<Content: View>: View {
    let title: String
    var back: (() -> Void)? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if let back {
                    Button(action: back) { Image(systemName: "chevron.left").font(.title3.bold()) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                Text(title).font(.system(.title, design: .rounded).weight(.heavy))
                Spacer()
            }
            content
        }
        .padding(24)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .padding(16)
    }
}

struct MenuButton: View {
    let title: String
    var icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 26)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).opacity(0.5)
            }
            .font(.system(.headline, design: .rounded))
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(prominent ? AnyShapeStyle(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(prominent ? .black : .white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Title: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("SNAKEROO").font(.system(size: 54, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.yellow, .green], startPoint: .top, endPoint: .bottom))
            Text("3D").font(.system(size: 26, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(.white.opacity(0.85))
        }
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}

// MARK: - Menus

struct MainMenu: View {
    let go: (Screen) -> Void
    var body: some View {
        VStack {
            Spacer()
            Title()
            Panel(title: "") {
                MenuButton(title: "New Game", icon: "play.fill", prominent: true) { go(.newGame) }
                    .keyboardShortcut(.defaultAction)
                MenuButton(title: "Settings", icon: "gearshape.fill") { go(.settings) }
                MenuButton(title: "High Scores", icon: "trophy.fill") { go(.scores) }
                MenuButton(title: "How to Play", icon: "questionmark.circle.fill") { go(.help) }
            }
            Spacer()
        }
    }
}

struct NewGameMenu: View {
    let go: (Screen) -> Void
    let start: (GameConfig) -> Void
    @AppStorage("vsCPU") private var vsCPU = false
    var body: some View {
        Panel(title: "New Game", back: { go(.menu) }) {
            MenuButton(title: "Classic", icon: "square.grid.3x3.fill", prominent: true) {
                start(GameConfig(mode: .classic, speed: 5, vsCPU: vsCPU))
            }
            MenuButton(title: "Adventure", icon: "door.left.hand.open") { start(GameConfig(mode: .adventure)) }
            MenuButton(title: "Custom…", icon: "slider.horizontal.3") { go(.custom) }
            Toggle(isOn: $vsCPU) { Label("Rival snake (CPU) in Classic", systemImage: "person.2.fill") }
                .padding(.horizontal, 4)
            Text("Adventure: grow to the target length to open the north gate, then escape before time runs out.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CustomSetup: View {
    let back: () -> Void
    let start: (GameConfig) -> Void
    @AppStorage("c.arena") private var arena = 0
    @AppStorage("c.food") private var food = 1
    @AppStorage("c.growth") private var growth = 1
    @AppStorage("c.obstacles") private var obstacles = true
    @AppStorage("c.specials") private var specials = true
    @AppStorage("c.speed") private var speed = 5
    @AppStorage("c.cpu") private var cpu = false

    var config: GameConfig {
        GameConfig(mode: .custom, arena: arena, food: FoodAmount(rawValue: food)!, growth: Growth(rawValue: growth)!,
                   obstacles: obstacles, specials: specials, speed: speed, vsCPU: cpu)
    }

    var body: some View {
        Panel(title: "Custom", back: back) {
            VStack(spacing: 12) {
                Picker("Arena", selection: $arena) { ForEach(Arena.all.indices, id: \.self) { Text(Arena.all[$0].name).tag($0) } }
                Picker("Food", selection: $food) { ForEach(FoodAmount.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                Picker("Growth", selection: $growth) { ForEach(Growth.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                Stepper("Speed  \(speed)", value: $speed, in: 1...9)
                Toggle("Obstacles", isOn: $obstacles)
                Toggle("Specials", isOn: $specials)
                Toggle("Rival snake (CPU)", isOn: $cpu)
            }
            .pickerStyle(.menu)
            MenuButton(title: "Start Game", icon: "play.fill", prominent: true) { start(config) }
            MenuButton(title: "Start Random", icon: "dice.fill") {
                arena = Int.random(in: 0..<Arena.all.count); food = Int.random(in: 0...2); growth = Int.random(in: 0...3)
                obstacles = .random(); specials = .random(); speed = .random(in: 3...7)
                start(config)
            }
        }
    }
}

struct SettingsView: View {
    let back: () -> Void
    @AppStorage("camera") private var camera = 0
    @AppStorage("color") private var color = 0
    @AppStorage("overview") private var overview = true
    @AppStorage("music") private var music = true
    @AppStorage("sound") private var sound = true
    @AppStorage("speedUp") private var speedUp = true
    @AppStorage("name") private var name = "Player"

    var body: some View {
        Panel(title: "Settings", back: back) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Camera").font(.subheadline.bold()).foregroundStyle(.secondary)
                Picker("Camera", selection: $camera) { ForEach(CameraMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text("Snake colour").font(.subheadline.bold()).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(0..<3) { i in
                        Circle().fill(Color(SnakeView.colors[i])).frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(.white, lineWidth: color == i ? 3 : 0))
                            .onTapGesture { color = i }
                    }
                }
                Toggle("Overview map (3D cameras)", isOn: $overview)
                Toggle("Speed-up (hold to go faster)", isOn: $speedUp)
                Toggle("Music", isOn: $music)
                Toggle("Sound effects", isOn: $sound)
                HStack { Text("Player name"); TextField("Name", text: $name).textFieldStyle(.roundedBorder) }
            }
        }
    }
}

struct ScoresView: View {
    let back: () -> Void
    @State private var mode: GameMode = .classic
    var body: some View {
        Panel(title: "High Scores", back: back) {
            Picker("Mode", selection: $mode) { ForEach(GameMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            let list = HighScores.list(mode)
            if list.isEmpty {
                Text("No scores yet — go set one!").foregroundStyle(.secondary).padding(.vertical, 30)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.1.id) { i, e in
                        HStack {
                            Text("\(i + 1).").monospacedDigit().frame(width: 30, alignment: .leading).foregroundStyle(.secondary)
                            Text(e.name).lineLimit(1)
                            Spacer()
                            Text(e.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            Text("\(e.score)").monospacedDigit().bold().frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

struct HelpView: View {
    let back: () -> Void
    private let items: [(String, String, String)] = [
        ("Fruit", "applelogo", "Apples, cherries and pears score points and make you grow."),
        ("Mushroom", "sparkles", "Leaves your snake dizzy and frozen for a moment."),
        ("Snail", "tortoise.fill", "Slows the game down for a while."),
        ("Flash", "bolt.fill", "Speeds the game up — worth bonus points."),
        ("Diet", "drop.fill", "Halves your length."),
        ("Twister", "arrow.triangle.2.circlepath", "Swaps your head and tail."),
        ("Arrow", "arrow.up.forward", "Lets you cross over your own body once."),
        ("Serum", "syringe.fill", "Lets you bite through a body — yours or the rival's — and cut it short."),
        ("Obstacles", "shippingbox.fill", "Stones and crates kill on contact, but encircle them with your body to crush them and claim what's inside."),
    ]
    var body: some View {
        Panel(title: "How to Play", back: back) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Steer the serpent to the food and avoid walls and bodies.").font(.callout)
                    Text("**Classic camera:** swipe or use arrow keys / WASD.\n**3D cameras:** tap the left or right half of the screen, swipe, or press ←/→ to turn.\nHold the ⚡︎ button, Shift, or the key for your current direction to speed up. Space or P pauses.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(items, id: \.0) { t, icon, d in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon).frame(width: 28).foregroundStyle(.green)
                            VStack(alignment: .leading) { Text(t).bold(); Text(d).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .frame(maxHeight: 460)
        }
    }
}
