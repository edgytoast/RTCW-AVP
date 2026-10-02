import SwiftUI
import UniformTypeIdentifiers
import QuartzCore
import GameController
import CompositorServices

@main
struct RTCWApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        .defaultSize(width: 1280, height: 720)

        // Immersive VR (M3): the engine renders each eye into Compositor Services textures.
        ImmersiveSpace(id: "vr") {
            CompositorLayer(configuration: VRLayerConfiguration()) { renderer in
                EngineThread.shared.start(immersive: renderer)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Launch mode: `-vr` / `-flat` launch arguments skip the start screen (used by scripts).
enum AppMode {
    static var forced: String? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-vr") { return "vr" }
        if args.contains("-flat") { return "flat" }
        return nil
    }
}

struct RootView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var mode: String? = AppMode.forced

    var body: some View {
        switch mode {
        case "flat":
            GameView()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        case "vr":
            Text("Entering VR…")
                .font(.title)
                .padding()
                .task {
                    if case .opened = await openImmersiveSpace(id: "vr") {
                        dismissWindow(id: "main")
                    }
                }
        default:
            StartScreen(mode: $mode)
        }
    }
}

/// Game data (user-supplied, never bundled): Documents/main/*.pk3, lowercase names.
enum GameData {
    static let required = ["pak0", "sp_pak1", "sp_pak2", "sp_pak3"]
    static let optional = ["sp_pak4"]          // GOTY / patched releases
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("main", isDirectory: true)
    }
    static func present(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).pk3").path)
    }
    static var missing: [String] { required.filter { !present($0) } }

    /// Copy picked files (or every pk3 inside picked folders) we recognise into Documents/main.
    static func importItems(_ urls: [URL]) -> (imported: [String], error: String?) {
        let fm = FileManager.default
        var imported: [String] = []
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var files = [url]
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                }
                for file in files {
                    let base = file.deletingPathExtension().lastPathComponent.lowercased()
                    guard file.pathExtension.lowercased() == "pk3", (required + optional).contains(base) else { continue }
                    let dst = folder.appendingPathComponent("\(base).pk3")
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: file, to: dst)
                    imported.append(base)
                }
            }
        } catch {
            return (imported, error.localizedDescription)
        }
        return (imported, nil)
    }
}

struct StartScreen: View {
    @Binding var mode: String?
    @State private var importing = false
    @State private var message = ""
    @State private var missing = GameData.missing

    var body: some View {
        VStack(spacing: 24) {
            Text("Return to Castle Wolfenstein").font(.largeTitle)
            if missing.isEmpty {
                HStack(spacing: 24) {
                    Button("Play in VR") { mode = "vr" }
                    Button("Play flat") { mode = "flat" }
                }
                .font(.title2)
                Text("DualSense recommended").foregroundStyle(.secondary)
            } else {
                Text("Game files needed: \(missing.map { "\($0).pk3" }.joined(separator: ", "))")
                    .multilineTextAlignment(.center)
                Text("Use the files from your own copy (GOG or Steam, folder 'Main').")
                    .foregroundStyle(.secondary)
            }
            Button(missing.isEmpty ? "Re-import game files…" : "Import game files…") { importing = true }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(48)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let r = GameData.importItems(urls)
                message = r.error.map { "Import failed: \($0)" }
                    ?? (r.imported.isEmpty ? "No RTCW pk3 files found in the selection."
                                           : "Imported: \(r.imported.sorted().joined(separator: ", "))")
            case .failure(let error):
                message = "Import failed: \(error.localizedDescription)"
            }
            missing = GameData.missing
        }
    }
}

struct VRLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated            // one texture per eye (ADR-002)
        configuration.isFoveationEnabled = false
        // RTCW writes gamma-space colors; prefer a non-sRGB target so the GPU does not re-encode.
        if capabilities.supportedColorFormats.contains(.bgra8Unorm) {
            configuration.colorFormat = .bgra8Unorm
        }
        configuration.depthFormat = .depth32Float
    }
}

/// Flat-mode host (ADR-002, M2): a CAMetalLayer the engine renders into via ANGLE.
struct GameView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalHostView { MetalHostView() }
    func updateUIView(_ view: MetalHostView, context: Context) {}
}

final class MetalHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // visionOS otherwise turns controller presses into pinch events on the gazed-at
        // view; deliver them exclusively through GameController (read in vos_input.m).
        let interaction = GCEventInteraction()
        interaction.handledEventTypes = .gamepad
        addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        layer.contentsScale = scale
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        // Follow window resizes: vos_flat.m letterboxes the fixed render target into this.
        (layer as? CAMetalLayer)?.drawableSize = CGSize(width: w, height: h)
        // Engine starts once, with the first real size (render target size).
        EngineThread.shared.start(layer: layer, pixelWidth: w, pixelHeight: h)
    }
}

/// Owns the single engine thread (ADR-003): VOS_EngineInit once, then VOS_EngineFrame forever.
final class EngineThread: @unchecked Sendable {
    static let shared = EngineThread()
    private var thread: Thread?

    /// Game data lives in Documents/main/*.pk3 (user-supplied, never bundled).
    static var basePath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    static var homePath: String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RTCW", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Engine command line = launch arguments (e.g. `+map escape1`), minus app flags.
    static var commandLine: String {
        ProcessInfo.processInfo.arguments.dropFirst().filter { $0 != "-vr" && $0 != "-flat" }.joined(separator: " ")
    }

    func start(immersive renderer: LayerRenderer) {
        VOS_XR_SetLayerRenderer(Unmanaged.passRetained(renderer).toOpaque())
        run()
    }

    func start(layer: CALayer, pixelWidth: Int, pixelHeight: Int) {
        guard thread == nil else { return }
        VOS_SetNativeLayer(Unmanaged.passUnretained(layer).toOpaque(), Int32(pixelWidth), Int32(pixelHeight))
        run()
    }

    private func run() {
        guard thread == nil else { return }
        let base = Self.basePath, home = Self.homePath, cmd = Self.commandLine
        let t = Thread {
            VOS_EngineInit(base, home, cmd)
            while true {
                VOS_EngineFrame()
            }
        }
        t.name = "RTCW.engine"
        t.stackSize = 16 << 20
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }
}
