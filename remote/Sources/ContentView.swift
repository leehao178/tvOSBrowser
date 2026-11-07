import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var client = PointerClient()
    @State private var motion = MotionPointer()
    @State private var pointerOn = false
    @State private var manualHost = ""
    @State private var lastDragY: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            connectionSection
            pointerSection
            scrollPad
            clickButton
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            motion.onDelta = { [client] dyaw, dpitch in
                client.sendMotion(dyaw: dyaw, dpitch: dpitch)
            }
            client.startBrowsing()
        }
        .onChange(of: pointerOn) { _ in updateMotion() }
        .onChange(of: scenePhase) { _ in updateMotion() }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(client.status)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer()
                Text("\(client.packetsSent)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if client.devices.count > 1 {
                ForEach(client.devices) { device in
                    Button {
                        client.connect(to: device)
                    } label: {
                        HStack {
                            Image(systemName: "appletv")
                            Text(device.name)
                            Spacer()
                            if client.targetName == device.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            HStack {
                TextField("或輸入 Apple TV IP", text: $manualHost)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("連線") {
                    client.connect(host: manualHost)
                    hideKeyboard()
                }
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var pointerSection: some View {
        Toggle(isOn: $pointerOn) {
            VStack(alignment: .leading) {
                Text("體感游標").font(.headline)
                Text(motion.isAvailable ? "轉動手機移動 Apple TV 上的游標" : "這支手機沒有陀螺儀")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(!motion.isAvailable)
    }

    private var scrollPad: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Text("上下滑動捲動網頁")
                    .foregroundColor(.secondary)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let y = value.translation.height
                        if let last = lastDragY {
                            // Finger up = page scrolls down (offset grows), like touch scrolling.
                            let delta = Double(last - y) * 2.0
                            if delta != 0 {
                                client.sendScroll(dx: 0, dy: delta)
                            }
                        }
                        lastDragY = y
                    }
                    .onEnded { _ in lastDragY = nil }
            )
    }

    private var clickButton: some View {
        Button {
            client.sendClick()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Text("點擊")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Helpers

    private func updateMotion() {
        if pointerOn && scenePhase == .active {
            motion.start()
        } else {
            motion.stop()
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
