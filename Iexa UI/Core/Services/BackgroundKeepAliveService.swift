import AVFoundation
import Combine
import CoreLocation
import Foundation
import OSLog
import UIKit

@MainActor
final class BackgroundKeepAliveService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAliveService()

    @Published private(set) var isActive = false

    var enhancedBackgroundEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enhancedBackgroundExecution") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "enhancedBackgroundExecution")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enhancedBackgroundExecution")
            reevaluate()
        }
    }

    var backgroundLocationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "backgroundLocationTrackingEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "backgroundLocationTrackingEnabled")
            reevaluate()
        }
    }

    private let logger = Logger(subsystem: "com.openui", category: "BackgroundKeepAlive")
    private let locationManager = CLLocationManager()
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var activeReasons: [String: Int] = [:]
    private var appIsInBackground = false
    private var audioEngine: AVAudioEngine?
    private var silentPlayerNode: AVAudioPlayerNode?
    private var silentAudioActive = false
    private var locationUpdating = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.pausesLocationUpdatesAutomatically = false
        installLifecycleObservers()
    }

    func begin(reason: String) {
        let key = normalizedReason(reason)
        activeReasons[key, default: 0] += 1
        isActive = !activeReasons.isEmpty
        beginBackgroundTaskIfNeeded(name: "Iexa \(key)")
        reevaluate()
    }

    func finish(reason: String) {
        let key = normalizedReason(reason)
        if let count = activeReasons[key], count > 1 {
            activeReasons[key] = count - 1
        } else {
            activeReasons.removeValue(forKey: key)
        }
        isActive = !activeReasons.isEmpty
        reevaluate()
        if activeReasons.isEmpty {
            endBackgroundTask()
        }
    }

    func finishAll() {
        activeReasons.removeAll()
        isActive = false
        reevaluate()
        endBackgroundTask()
    }

    private func installLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appIsInBackground = true
                self?.reevaluate()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appIsInBackground = false
                self?.reevaluate()
            }
        }
    }

    private func beginBackgroundTaskIfNeeded(name: String) {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.logger.warning("Background task expired; releasing keep-alive")
                self?.finishAll()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    private func reevaluate() {
        let shouldKeepAlive = enhancedBackgroundEnabled && isActive && appIsInBackground
        if shouldKeepAlive {
            startSilentAudioIfNeeded()
            startLocationIfAllowed()
        } else {
            stopSilentAudio()
            stopLocation()
        }
    }

    private func startSilentAudioIfNeeded() {
        guard !silentAudioActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0001
            try engine.start()
            scheduleSilentBuffer(on: player, format: format)
            player.play()

            audioEngine = engine
            silentPlayerNode = player
            silentAudioActive = true
            logger.info("Silent background audio started")
        } catch {
            logger.warning("Silent background audio failed: \(error.localizedDescription, privacy: .public)")
            stopSilentAudio()
        }
    }

    private func scheduleSilentBuffer(on player: AVAudioPlayerNode, format: AVAudioFormat) {
        let frameCount: AVAudioFrameCount = 44_100
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
    }

    private func stopSilentAudio() {
        guard silentAudioActive || audioEngine != nil || silentPlayerNode != nil else { return }
        silentPlayerNode?.stop()
        audioEngine?.stop()
        silentPlayerNode = nil
        audioEngine = nil
        silentAudioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        logger.info("Silent background audio stopped")
    }

    private func startLocationIfAllowed() {
        guard backgroundLocationEnabled, !locationUpdating else { return }
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
        locationUpdating = true
        logger.info("Background location heartbeat started")
    }

    private func stopLocation() {
        guard locationUpdating else { return }
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        locationUpdating = false
        logger.info("Background location heartbeat stopped")
    }

    private func normalizedReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "task" : trimmed
    }
}
