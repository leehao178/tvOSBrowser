import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Turns the hardware volume buttons into actions.
///
/// iOS has no public API for the volume buttons, so this watches the system output volume:
/// a press changes it by one step, which is reported as `onUp` / `onDown`, and the volume is
/// then put straight back. The phone's media volume therefore stays where the user had it
/// (only nudged one step inward if it was at 0 or at maximum, where a press can't be seen).
/// The hidden MPVolumeView keeps iOS from showing its volume HUD and lets the volume be reset.
final class VolumeButtonObserver: NSObject {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    /// Must be part of the visible view hierarchy (see VolumeButtonHost).
    let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }()

    private var observation: NSKeyValueObservation?
    private var baseline: Float = 0.5
    private var isRunning = false
    private let step: Float = 1.0 / 16.0   // one press of a volume button

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Ambient + mix: don't interrupt music or videos playing in other apps.
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        isRunning = true

        let current = session.outputVolume
        baseline = min(max(current, step), 1.0 - step)
        if abs(baseline - current) > 0.001 {
            setSystemVolume(baseline)
        }

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            DispatchQueue.main.async {
                self?.volumeChanged(to: volume)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func volumeChanged(to volume: Float) {
        guard isRunning else { return }
        let difference = volume - baseline
        // Our own reset back to the baseline also arrives here; ignore it.
        guard abs(difference) > 0.001 else { return }
        if difference > 0 {
            onUp?()
        } else {
            onDown?()
        }
        setSystemVolume(baseline)
    }

    private func setSystemVolume(_ volume: Float) {
        // Setting the slider right away is sometimes ignored, so give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let slider = self?.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.setValue(volume, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

/// Puts the observer's hidden MPVolumeView into the SwiftUI hierarchy.
struct VolumeButtonHost: UIViewRepresentable {
    let observer: VolumeButtonObserver

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.addSubview(observer.volumeView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
