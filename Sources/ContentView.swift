import SwiftUI
import UIKit
import ARKit
import SceneKit
import Network
import simd

class OneEuroFilter3D {
    private var minCutoff: Float
    private var beta: Float
    private var dCutoff: Float = 1.0
    private var prevPos: SIMD3<Float>?
    private var prevDeriv: SIMD3<Float> = .zero
    private var prevTime: TimeInterval?

    init(minCutoff: Float = 1.5, beta: Float = 0.05) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    func updateParams(smoothAmount: Float) {
        let clamped = max(0.0, min(1.0, smoothAmount))
        self.minCutoff = 12.0 * pow(0.04, clamped)
        self.beta = 0.5 * (1.0 - clamped) + 0.02
    }

    func reset() {
        prevPos = nil
        prevDeriv = .zero
        prevTime = nil
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(_ pos: SIMD3<Float>, timestamp: TimeInterval) -> SIMD3<Float> {
        guard let lastPos = prevPos, let lastTime = prevTime else {
            prevPos = pos
            prevTime = timestamp
            return pos
        }
        let dt = Float(max(timestamp - lastTime, 1.0 / 120.0))
        let deriv = (pos - lastPos) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let smoothedDeriv = prevDeriv + aD * (deriv - prevDeriv)

        let speed = simd_length(smoothedDeriv)
        let cutoff = minCutoff + beta * speed
        let a = alpha(cutoff: cutoff, dt: dt)
        let filtered = lastPos + a * (pos - lastPos)

        prevPos = filtered
        prevDeriv = smoothedDeriv
        prevTime = timestamp
        return filtered
    }
}

class ARCameraStreamer: NSObject, ObservableObject, ARSessionDelegate {
    @Published var ipAddress: String = "192.168.1.100"
    @Published var portString: String = "9999"
    @Published var isStreaming: Bool = false
    @Published var isRecording: Bool = false
    @Published var smoothLevel: Float = 0.65
    @Published var movementScale: Float = 1.0
    @Published var isPortraitMode: Bool = false
    @Published var trackingStatus: String = "Gotowy"

    private var connection: NWConnection?
    private let posFilter = OneEuroFilter3D()
    private var smoothedRot: simd_quatf?
    private var lastTimestamp: TimeInterval?

    private var originPos: SIMD3<Float>?
    private var originYawInv: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var shouldRecenter: Bool = true

    private let arToBlenderQuat = simd_quatf(angle: .pi / 2.0, axis: SIMD3<Float>(1, 0, 0))
    private let portraitOffsetQuat = simd_quatf(angle: .pi / 2.0, axis: SIMD3<Float>(0, 0, 1))

    func toggleStreaming() {
        if isStreaming { stopStreaming() } else { startStreaming() }
    }

    func startStreaming() {
        guard let portNum = UInt16(portString), let port = NWEndpoint.Port(rawValue: portNum) else {
            trackingStatus = "Błędny port"
            return
        }
        let host = NWEndpoint.Host(ipAddress)
        connection = NWConnection(host: host, port: port, using: .udp)
        connection?.start(queue: .global(qos: .userInteractive))

        UIApplication.shared.isIdleTimerDisabled = true
        recenter()
        isStreaming = true
        trackingStatus = "UDP -> \(ipAddress):\(portString)"
    }

    func stopStreaming() {
        isRecording = false
        if let data = "{\"rec\":false}".data(using: .utf8) {
            connection?.send(content: data, completion: .idempotent)
        }
        connection?.cancel()
        connection = nil
        UIApplication.shared.isIdleTimerDisabled = false
        isStreaming = false
        trackingStatus = "Zatrzymano"
    }

    func recenter() {
        shouldRecenter = true
        posFilter.reset()
        smoothedRot = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isStreaming else { return }

        let transform = frame.camera.transform
        let rawPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rawRot = simd_quatf(transform)

        if shouldRecenter || originPos == nil {
            originPos = rawPos
            let forwardX = -transform.columns.2.x
            let forwardZ = -transform.columns.2.z
            let yaw = atan2(-forwardX, -forwardZ)
            originYawInv = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
            shouldRecenter = false
        }

        let deltaPos = originYawInv.act(rawPos - (originPos ?? .zero)) * movementScale
        var relRot = originYawInv * rawRot
        if isPortraitMode {
            relRot = relRot * portraitOffsetQuat
        }

        let finalPos: SIMD3<Float>
        if smoothLevel < 0.02 {
            finalPos = deltaPos
        } else {
            posFilter.updateParams(smoothAmount: smoothLevel)
            finalPos = posFilter.filter(deltaPos, timestamp: frame.timestamp)
        }

        let finalRot: simd_quatf
        if smoothLevel < 0.02 || smoothedRot == nil {
            finalRot = relRot
        } else {
            let prev = smoothedRot!
            let dt = Float(max(frame.timestamp - (lastTimestamp ?? frame.timestamp), 1.0 / 120.0))
            let dot = min(1.0, abs(simd_dot(prev, relRot)))
            let angleDiff = 2.0 * acos(dot)
            let angularSpeed = angleDiff / dt

            let baseAlpha = 1.0 - (smoothLevel * 0.92)
            let speedBoost = min(0.7, angularSpeed * 0.12)
            let t = min(1.0, max(0.04, baseAlpha + speedBoost))
            finalRot = simd_slerp(prev, relRot, t)
        }
        smoothedRot = finalRot
        lastTimestamp = frame.timestamp

        let bx = finalPos.x
        let by = -finalPos.z
        let bz = finalPos.y
        let bq = arToBlenderQuat * finalRot

        let recStr = isRecording ? "true" : "false"
        let json = String(
            format: "{\"px\":%.5f,\"py\":%.5f,\"pz\":%.5f,\"qw\":%.5f,\"qx\":%.5f,\"qy\":%.5f,\"qz\":%.5f,\"rec\":%@}",
            bx, by, bz, bq.real, bq.imag.x, bq.imag.y, bq.imag.z, recStr
        )

        if let data = json.data(using: .utf8) {
            connection?.send(content: data, completion: .idempotent)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var streamer: ARCameraStreamer

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session.delegate = streamer
        view.automaticallyUpdatesLighting = false

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        view.session.run(config)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var streamer = ARCameraStreamer()

    var body: some View {
        ZStack {
            ARViewContainer(streamer: streamer)
                .edgesIgnoringSafeArea(.all)

            VStack {
                VStack(spacing: 8) {
                    HStack {
                        TextField("IP Komputera", text: $streamer.ipAddress)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .disabled(streamer.isStreaming)

                        TextField("Port", text: $streamer.portString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 75)
                            .keyboardType(.numberPad)
                            .disabled(streamer.isStreaming)
                    }
                    HStack {
                        Circle()
                            .fill(streamer.isStreaming ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(streamer.trackingStatus)
                            .font(.caption)
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("Pionowo", isOn: $streamer.isPortraitMode)
                            .labelsHidden()
                        Text(streamer.isPortraitMode ? "Pion" : "Poziom")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.65))
                .cornerRadius(14)
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        Text("Smooth: \(Int(streamer.smoothLevel * 100))%")
                            .font(.caption).bold().foregroundColor(.white)
                            .frame(width: 95, alignment: .leading)
                        Slider(value: $streamer.smoothLevel, in: 0...1)
                            .accentColor(.cyan)
                    }

                    HStack {
                        Text(String(format: "Skala: %.1fx", streamer.movementScale))
                            .font(.caption).bold().foregroundColor(.white)
                            .frame(width: 95, alignment: .leading)
                        Slider(value: $streamer.movementScale, in: 0.2...3.0, step: 0.1)
                            .accentColor(.orange)
                    }

                    HStack(spacing: 14) {
                        Button(action: { streamer.toggleStreaming() }) {
                            Text(streamer.isStreaming ? "Rozłącz" : "Połącz")
                                .bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(streamer.isStreaming ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        Button(action: { streamer.recenter() }) {
                            Text("Wyzeruj")
                                .bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(!streamer.isStreaming)

                        Button(action: { streamer.isRecording.toggle() }) {
                            HStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                                Text(streamer.isRecording ? "STOP" : "REC")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(streamer.isRecording ? Color.red : Color.red.opacity(0.5))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(!streamer.isStreaming)
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.72))
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
        }
    }
}
