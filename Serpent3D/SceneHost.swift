import SwiftUI
import SceneKit

#if os(macOS)
struct SceneHost: NSViewRepresentable {
    let engine: Engine
    func makeNSView(context: Context) -> SCNView { make() }
    func updateNSView(_ v: SCNView, context: Context) {}
}
#else
struct SceneHost: UIViewRepresentable {
    let engine: Engine
    func makeUIView(context: Context) -> SCNView { make() }
    func updateUIView(_ v: SCNView, context: Context) {}
}
#endif

extension SceneHost {
    func make() -> SCNView {
        let v = SCNView(frame: .zero, options: nil)
        v.scene = engine.scene
        v.pointOfView = engine.pointOfView
        v.delegate = engine
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 120
        v.rendersContinuously = true
        v.isPlaying = true
        v.backgroundColor = .black
        #if targetEnvironment(simulator)
        v.antialiasingMode = .none          // the simulator's GPU is far slower than real devices
        v.preferredFramesPerSecond = 30
        #endif
        return v
    }
}
