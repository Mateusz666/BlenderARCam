import SwiftUI
import ARKit
import RealityKit
import Network

// MARK: - Odbiornik strumienia MJPEG z Blendera
class MJPEGStreamClient: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var currentFrame: UIImage?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let decodeQueue = DispatchQueue(label: "mjpeg.decode", qos: .userInitiated)

    func start(ip: String, port: String = "8080") {
        stop()
        guard let url = URL(string: "http://\(ip):\(port)/") else { return }
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: url)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        decodeQueue.async { self.buffer.removeAll() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        decodeQueue.async {
            self.buffer.append(data)
            let soi = Data([0xFF, 0xD8])
            let eoi = Data([0xFF, 0xD9])
            var latestImage: UIImage?

            while let startRange = self.buffer.range(of: soi),
                  let endRange = self.buffer.range(of: eoi, in: startRange.upperBound..<self.buffer.endIndex) {
                let jpegData = self.buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
                self.buffer.removeSubrange(self.buffer.startIndex..<endRange.upperBound)
                if let image = UIImage(data: jpegData) {
                    latestImage = image
                }
            }
            if self.buffer.count > 500_000 {
                self.buffer.removeAll()
            }
            if let img = latestImage {
                DispatchQueue.main.async {
                    self.currentFrame = img
                }
            }
        }
    }
}

// MARK: - Kontroler ARKit + UDP (stabilny, na osobnym wątku)
class ARCamManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var smoothing: Float = 0.15
    @Published var focalLength: Float = 35.0
    @Published var trackingOK = false
    @Published var trackingText = "Kalibracja..."

    let arSession = ARSession()
    private let arQueue = DispatchQueue(label: "arkit.delegate", qos: .userInteractive)
    private var connection: NWConnection?
    private var smoothPos = SIMD3<Float>(0, 0, 0)
    private var smoothQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var hasInitialFrame = false

    // Lokalne kopie zmiennych dla wątku ARKit
    private var localConnected = false
    private var localRecording = false
    private var localSmoothing: Float = 0.15
    private var localFocalLength: Float = 35.0

    override init() {
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = arQueue
    }

    func startAR() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = []
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        arQueue.async {
            self.hasInitialFrame = false
        }
    }

    func recenter() {
        startAR()
    }

    func syncSettings() {
        let s = smoothing
        let f = focalLength
        let r = isRecording
        arQueue.async {
            self.localSmoothing = s
            self.localFocalLength = f
            self.localRecording = r
        }
    }

    func connect(ip: String, port: UInt16) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let host = NWEndpoint.Host(ip)
        let conn = NWConnection(host: host, port: nwPort, using: .udp)
        conn.start(queue: arQueue)
        arQueue.async {
            self.connection = conn
            self.localConnected = true
        }
        isConnected = true
        syncSettings()
    }

    func disconnect() {
        arQueue.async {
            self.connection?.cancel()
            self.connection = nil
            self.localConnected = false
            self.localRecording = false
        }
        isConnected = false
        isRecording = false
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        switch frame.camera.trackingState {
        case .normal:
            if !trackingOK {
                DispatchQueue.main.async {
                    self.trackingOK = true
                    self.trackingText = "Tracking OK"
                }
            }
        case .limited(let reason):
            let msg: String
            switch reason {
            case .excessiveMotion: msg = "Za szybki ruch"
            case .insufficientFeatures: msg = "Za mało detali/światła"
            case .initializing: msg = "Kalibracja..."
            case .relocalizing: msg = "Odzyskiwanie pozycji..."
            @unknown default: msg = "Ograniczony tracking"
            }
            DispatchQueue.main.async {
                self.trackingOK = false
                self.trackingText = msg
            }
            return
        case .notAvailable:
            DispatchQueue.main.async {
                self.trackingOK = false
                self.trackingText = "Brak trackingu"
            }
            return
        }

        guard localConnected, let conn = connection else { return }

        let t = frame.camera.transform
        let rawPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let rawQuat = simd_quatf(t)

        if !hasInitialFrame {
            smoothPos = rawPos
            smoothQuat = rawQuat
            hasInitialFrame = true
        } else {
            let alpha = max(0.05, 1.0 - localSmoothing)
            smoothPos = simd_mix(smoothPos, rawPos, SIMD3<Float>(repeating: alpha))
            smoothQuat = simd_slerp(smoothQuat, rawQuat, alpha)
        }

        let recFlag = localRecording ? 1 : 0
        let msg = String(
            format: "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%d,%.1f",
            smoothPos.x, smoothPos.y, smoothPos.z,
            smoothQuat.imag.x, smoothQuat.imag.y, smoothQuat.imag.z, smoothQuat.real,
            recFlag,
            localFocalLength
        )

        if let data = msg.data(using: .utf8) {
            conn.send(content: data, completion: .idempotent)
        }
    }
}

// MARK: - Podgląd aparatu (tylko gdy wybrany tryb Aparat, bez nadpisywania sesji)
struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Główny ekran aplikacji
struct ContentView: View {
    @StateObject private var arManager = ARCamManager()
    @StateObject private var streamClient = MJPEGStreamClient()

    @State private var ipAddress = "192.168.1.14"
    @State private var udpPort = "9998"
    @State private var httpPort = "8080"
    @State private var showBlenderView = true
    @State private var showSettings = true

    var body: some View {
        ZStack {
            if showBlenderView {
                Color.black.ignoresSafeArea()
                if let frame = streamClient.currentFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(arManager.isConnected ? "Oczekiwanie na obraz z Blendera..." : "Kliknij Połącz")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            } else {
                ARViewContainer(session: arManager.arSession)
                    .ignoresSafeArea()
            }

            // Interfejs sterowania
            VStack {
                HStack(spacing: 8) {
                    Button(action: { showBlenderView.toggle() }) {
                        Label(showBlenderView ? "Blender" : "Aparat",
                              systemImage: showBlenderView ? "cube.transparent" : "camera")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }

                    Button(action: { arManager.recenter() }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }

                    // Wskaźnik jakości trackingu ARKit
                    HStack(spacing: 5) {
                        Circle()
                            .fill(arManager.trackingOK ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(arManager.trackingText)
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6))
                    .cornerRadius(8)

                    Spacer()

                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: showSettings ? "chevron.up.circle.fill" : "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if showSettings {
                    VStack(spacing: 10) {
                        HStack {
                            TextField("IP komputera", text: $ipAddress)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.decimalPad)
                            TextField("UDP", text: $udpPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 68)
                                .keyboardType(.numberPad)
                            TextField("HTTP", text: $httpPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 68)
                                .keyboardType(.numberPad)
                        }

                        HStack {
                            Text("Wygładzanie: \(Int(arManager.smoothing * 100))%")
                                .font(.caption)
                                .foregroundColor(.white)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: $arManager.smoothing, in: 0...0.85)
                                .onChange(of: arManager.smoothing) { _ in arManager.syncSettings() }
                        }

                        HStack {
                            Text("Ogniskowa: \(Int(arManager.focalLength)) mm")
                                .font(.caption)
                                .foregroundColor(.white)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: $arManager.focalLength, in: 16...100, step: 1)
                                .onChange(of: arManager.focalLength) { _ in arManager.syncSettings() }
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.65))
                    .cornerRadius(14)
                    .padding(.horizontal)
                }

                Spacer()

                HStack(spacing: 16) {
                    Button(action: {
                        if arManager.isConnected {
                            arManager.disconnect()
                            streamClient.stop()
                        } else {
                            let portNum = UInt16(udpPort) ?? 9998
                            arManager.connect(ip: ipAddress, port: portNum)
                            streamClient.start(ip: ipAddress, port: httpPort)
                            showSettings = false
                        }
                    }) {
                        Text(arManager.isConnected ? "Rozłącz" : "Połącz")
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(arManager.isConnected ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    if arManager.isConnected {
                        Button(action: {
                            arManager.isRecording.toggle()
                            arManager.syncSettings()
                        }) {
                            Text(arManager.isRecording ? "STOP REC" : "REC")
                                .bold()
                                .frame(width: 110)
                                .padding()
                                .background(arManager.isRecording ? Color.red : Color.gray.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            arManager.startAR()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
