import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var client = PointerClient()
    @State private var motion = MotionPointer()
    @State private var volumeButtons = VolumeButtonObserver()
    @AppStorage("pointerOn") private var pointerOn = false
    @AppStorage("volumeKeysOn") private var volumeKeysOn = false
    @AppStorage("pointerSpeed") private var speed = 1.0
    @AppStorage("pointerDeadZone") private var deadZone = 0.03
    @AppStorage("pointerSmoothing") private var smoothing = 0.5
    @State private var manualHost = ""
    @State private var showSettings = false
    @State private var lastDragY: CGFloat?
    @State private var isScrolling = false
    @State private var wakeWorkItem: DispatchWorkItem?
    @State private var wakeArmed = false
    @State private var resumeWorkItem: DispatchWorkItem?
    @State private var screenOff = false
    @State private var showScreenOffHint = false
    @State private var savedBrightness: CGFloat?
    @State private var wasInBackground = false
    @Environment(\.scenePhase) private var scenePhase

    /// Finger movement (points) beyond which a touch is a scroll, not a tap.
    private let tapSlop: CGFloat = 12
    /// Holding a finger this long on the black screen turns the screen back on.
    private let wakeHoldDuration: TimeInterval = 0.8

    var body: some View {
        ZStack {
            mainContent
            if screenOff {
                screenOffLayer
            }
        }
        .statusBarHidden(screenOff)
        .persistentSystemOverlays(screenOff ? .hidden : .automatic)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            manualHost = client.savedHost ?? ""
            motion.onDelta = { [client] dyaw, dpitch in
                client.sendMotion(dyaw: dyaw, dpitch: dpitch)
            }
            volumeButtons.onDown = { [client] in
                client.sendClick()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            volumeButtons.onUp = { [client] in
                client.sendBack()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            applySettings()
            client.start()
            updateInputs()
        }
        .onChange(of: pointerOn) { _ in updateInputs() }
        .onChange(of: volumeKeysOn) { _ in updateInputs() }
        .onChange(of: scenePhase) { phase in handleScenePhase(phase) }
        .onChange(of: speed) { _ in applySettings() }
        .onChange(of: deadZone) { _ in applySettings() }
        .onChange(of: smoothing) { _ in applySettings() }
    }

    private var mainContent: some View {
        VStack(spacing: 16) {
            connectionSection
            controlsSection
            touchPad
            HStack(spacing: 12) {
                screenOffButton
                clickButton
            }
        }
        .padding()
        .background(VolumeButtonHost(observer: volumeButtons).frame(width: 1, height: 1))
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

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $pointerOn) {
                VStack(alignment: .leading) {
                    Text("體感游標").font(.headline)
                    Text(motion.isAvailable ? "轉動手機移動 Apple TV 上的游標" : "這支手機沒有陀螺儀")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!motion.isAvailable)

            Toggle(isOn: $volumeKeysOn) {
                VStack(alignment: .leading) {
                    Text("音量鍵控制").font(.headline)
                    Text("音量減 = 點擊，音量加 = 上一頁（手機音量會自動調回）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            DisclosureGroup("游標調整", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    settingSlider(title: "速度",
                                  value: $speed, range: 0.3...3.0,
                                  label: String(format: "%.1fx", speed),
                                  hint: "游標移動的快慢")
                    settingSlider(title: "防抖範圍",
                                  value: $deadZone, range: 0.0...0.12,
                                  label: String(format: "%.0f", deadZone * 1000),
                                  hint: "比這更慢的轉動會被忽略，越大越不抖，但細微移動會變難")
                    settingSlider(title: "穩定度",
                                  value: $smoothing, range: 0.0...1.0,
                                  label: String(format: "%.0f%%", smoothing * 100),
                                  hint: "越高越平滑，但游標會稍微慢半拍")
                    Button("恢復預設值") {
                        speed = 1.0
                        deadZone = 0.03
                        smoothing = 0.5
                    }
                    .font(.footnote)
                }
                .padding(.top, 6)
            }
        }
    }

    private func settingSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               label: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(label).font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
            Text(hint).font(.caption2).foregroundColor(.secondary)
        }
    }

    private var touchPad: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                VStack(spacing: 6) {
                    if pointerOn {
                        Image(systemName: "hand.tap")
                            .font(.largeTitle)
                        Text("點一下 = 點擊")
                        Text("上下滑動 = 捲動網頁")
                            .font(.footnote)
                    } else {
                        Text("上下滑動捲動網頁")
                    }
                }
                .foregroundColor(.secondary)
            )
            .contentShape(Rectangle())
            .gesture(touchGesture(onBlackScreen: false))
    }

    private var screenOffButton: some View {
        Button {
            turnScreenOff()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "moon.fill")
                Text("關閉螢幕").font(.caption)
            }
            .frame(minWidth: 70, minHeight: 90)
        }
        .buttonStyle(.bordered)
    }

    private var clickButton: some View {
        Button {
            click()
        } label: {
            Text("點擊")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 90)
        }
        .buttonStyle(.borderedProminent)
    }

    /// Black, minimum-brightness layer that stands in for a locked screen. The whole screen
    /// still works as the touch pad; holding a finger down turns the screen back on.
    private var screenOffLayer: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(
                Text("點一下 = 點擊　上下滑 = 捲動\n長按到震動後放開 = 恢復螢幕")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .opacity(showScreenOffHint ? 0.6 : 0)
                    .animation(.easeOut(duration: 0.6), value: showScreenOffHint)
            )
            .contentShape(Rectangle())
            .gesture(touchGesture(onBlackScreen: true))
    }

    // MARK: - Touch handling

    private func touchGesture(onBlackScreen: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in handleTouchChanged(value, onBlackScreen: onBlackScreen) }
            .onEnded { _ in handleTouchEnded(onBlackScreen: onBlackScreen) }
    }

    private func handleTouchChanged(_ value: DragGesture.Value, onBlackScreen: Bool) {
        if lastDragY == nil {
            // Finger down: freeze the cursor so the tap doesn't move it.
            resumeWorkItem?.cancel()
            motion.isPaused = true
            isScrolling = false
            wakeArmed = false
            if onBlackScreen {
                // After the hold time, vibrate so it's clear the finger can be lifted to wake the screen.
                let wake = DispatchWorkItem {
                    guard !isScrolling else { return }
                    wakeArmed = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                wakeWorkItem = wake
                DispatchQueue.main.asyncAfter(deadline: .now() + wakeHoldDuration, execute: wake)
            }
        }
        let y = value.translation.height
        if !isScrolling && hypot(value.translation.width, y) > tapSlop {
            isScrolling = true
            // Scrolling, not holding: don't wake the screen.
            wakeWorkItem?.cancel()
            wakeArmed = false
        }
        if isScrolling, let last = lastDragY {
            // Finger up = page scrolls down (offset grows), like touch scrolling.
            let delta = Double(last - y) * 2.0
            if delta != 0 {
                client.sendScroll(dx: 0, dy: delta)
            }
        }
        lastDragY = y
    }

    private func handleTouchEnded(onBlackScreen: Bool) {
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        if !isScrolling {
            if onBlackScreen && wakeArmed {
                turnScreenOn()
            } else if onBlackScreen || pointerOn {
                click()
            }
        }
        wakeArmed = false
        lastDragY = nil
        isScrolling = false
        // Keep the cursor frozen a moment longer: lifting the finger also nudges the phone.
        let resume = DispatchWorkItem { motion.isPaused = false }
        resumeWorkItem = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: resume)
    }

    // MARK: - Screen off

    private func turnScreenOff() {
        guard !screenOff else { return }
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        screenOff = true
        showScreenOffHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showScreenOffHint = false
        }
    }

    private func turnScreenOn() {
        guard screenOff else { return }
        screenOff = false
        restoreBrightness()
    }

    private func restoreBrightness() {
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
    }

    // MARK: - Helpers

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if screenOff {
                // Brightness is system-wide, so it was restored when the app left; dim again.
                UIScreen.main.brightness = 0
            }
            if wasInBackground {
                wasInBackground = false
                client.reconnect()
            }
        case .background:
            wasInBackground = true
            restoreBrightness()
        default:
            restoreBrightness()
        }
        updateInputs()
    }

    private func click() {
        client.sendClick()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func applySettings() {
        motion.settings = MotionPointer.Settings(speed: speed, deadZone: deadZone, smoothing: smoothing)
    }

    private func updateInputs() {
        let active = scenePhase == .active
        if pointerOn && active {
            motion.start()
        } else {
            motion.stop()
        }
        if volumeKeysOn && active {
            volumeButtons.start()
        } else {
            volumeButtons.stop()
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
