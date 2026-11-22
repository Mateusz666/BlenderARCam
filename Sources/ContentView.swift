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
        buffer.removeAll()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let soi = Data([0xFF, 0xD8]) // Start of JPEG
        let eoi = Data([0xFF, 0xD9]) // End of JPEG

        while let startRange = buffer.range(of: soi),
              let endRange = buffer.range(of: eoi, in: startRange.upperBound..<buffer.endIndex) {
            let jpegData = buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)

            if let image = UIImage(data: jpegData) {
                DispatchQueue.main.async {
                    self.currentFrame = image
                }
            }
        }
        if buffer.count > 1_000_000 {
            buffer.removeAll()
        }
    }
}

// MARK: - Kontroler ARKit + UDP
class ARCamManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var smoothing: Float = 0.25

    let arSession = ARSession()
    private var connection: NWConnection?
    private var smoothPos = SIMD3<Float>(0, 0, 0)
    private var smoothQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var hasInitialFrame = false

    override init() {
        super.init()
        arSession.delegate = self
    }

    func startAR() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        hasInitialFrame = false
    }

    func connect(ip: String, port: UInt16) {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let host = NWEndpoint.Host(ip)
        connection = NWConnection(host: host, port: nwPort, using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))
        isConnected = true
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        isRecording = false
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isConnected, let conn = connection else { return }

        let t = frame.camera.transform
        let rawPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let rawQuat = simd_quatf(t)

        if !hasInitialFrame {
            smoothPos = rawPos
            smoothQuat = rawQuat
            hasInitialFrame = true
        } else {
            let alpha = max(0.05, 1.0 - smoothing)
            smoothPos = simd_mix(smoothPos, rawPos, SIMD3<Float>(repeating: alpha))
            smoothQuat = simd_slerp(smoothQuat, rawQuat, alpha)
        }

        let recFlag = isRecording ? 1 : 0
        let msg = String(
            format: "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%d",
            smoothPos.x, smoothPos.y, smoothPos.z,
            smoothQuat.imag.x, smoothQuat.imag.y, smoothQuat.imag.z, smoothQuat.real,
            recFlag
        )

        if let data = msg.data(using: .utf8) {
            conn.send(content: data, completion: .idempotent)
        }
    }
}

// MARK: - Podgląd ARKit w tle
struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
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
            // Warstwa 1: ARKit (zawsze aktywny dla śledzenia 6DOF)
            ARViewContainer(session: arManager.arSession)
                .ignoresSafeArea()

            // Warstwa 2: Podgląd sceny z Blendera
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
                        Text(arManager.isConnected ? "Oczekiwanie na obraz z Blendera (HTTP:\(httpPort))..." : "Kliknij Połącz, aby uruchomić podgląd")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }

            // Warstwa 3: Interfejs sterowania
            VStack {
                HStack {
                    Button(action: { showBlenderView.toggle() }) {
                        Label(showBlenderView ? "Widok: Blender" : "Widok: Aparat",
                              systemImage: showBlenderView ? "cube.transparent" : "camera")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(10)
                    }
                    Spacer()
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: showSettings ? "chevron.up.circle.fill" : "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(8)
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
                            Slider(value: $arManager.smoothing, in: 0...0.85)
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.65))
                    .cornerRadius(14)
                    .padding(.horizontal)
                }

                Spacer()

                // Dolny pasek: Połącz + REC
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
            arManager.startAR()
        }
    }
}
