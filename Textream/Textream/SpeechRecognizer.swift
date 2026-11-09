//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio

private let waveformUpdatesPerSecond = 20.0
private let speechCaptureBuffersPerSecond = 40.0

func speechCaptureFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
    guard hardwareFormat.channelCount > 1 else { return hardwareFormat }

    // An input-node tap must use the hardware sample rate. AVAudioEngine can
    // downmix channels here, but requesting a different rate raises an
    // uncaught AVFAudio format-mismatch exception on high-rate USB devices.
    return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: hardwareFormat.sampleRate,
        channels: 1,
        interleaved: false
    )
}

func speechCaptureBufferSize(for format: AVAudioFormat) -> AVAudioFrameCount {
    AVAudioFrameCount(max(1024, format.sampleRate / speechCaptureBuffersPerSecond))
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, namePointer)
            }
            guard nameStatus == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var isStarting: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        voiceActivityDetector.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var annotationRanges: [Range<Int>] = []
    private var voiceActivityDetector = VoiceActivityDetector()
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var recognitionGeneration: Int = 0
    private var shouldListen: Bool = false
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()
    private var preemptiveRestartTimer: Timer?
    /// Sliding window of recent match positions for confidence gating.
    /// We require 2-of-3 recent results to agree before committing a forward jump.
    private var recentMatchPositions: [Int] = []
    /// Transcript prefix to ignore when matching — set on jumps so the task
    /// can keep running instead of being restarted (a restart loses the words
    /// the user re-speaks right after the jump). Stored as the prefix string,
    /// not a char count: partial results revise earlier text, and trimming by
    /// the surviving common prefix avoids swallowing post-jump speech when
    /// the pre-jump portion changes length. Cleared whenever a new
    /// recognition task starts a fresh transcript.
    private var spokenAnchorPrefix: String = ""
    /// Results computed before a jump can be delivered after it; matching
    /// ignores results for a short window so pre-jump speech isn't matched
    /// against the text at the new offset.
    private var lastJumpAt: Date = .distantPast

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        regressionPending = nil
        regressionUndo = nil
        regressionFloor = 0
        isOffScript = false
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word).
    /// Nearby jumps keep the recognition task alive and anchor matching past
    /// the already-spoken transcript, so tracking resumes on the first
    /// re-spoken word. Far jumps restart the task instead: contextualStrings
    /// are built for the section being read, and after a page-scale jump
    /// stale hints hurt recognition more than the task warm-up costs.
    /// retryCount is deliberately not touched here — resetting it on every
    /// tap would let a user keep a failing availability-retry loop alive
    /// forever.
    func jumpTo(charOffset: Int) {
        let clampedOffset = max(0, min(charOffset, sourceText.count))
        let targetOffset = advancePastAnnotations(from: clampedOffset)
        let distance = abs(targetOffset - recognizedCharCount)
        recognizedCharCount = targetOffset
        matchStartOffset = targetOffset
        recentMatchPositions = []
        // The reader often finishes the old sentence after a tap. Those words
        // must not count as a re-read that takes the highlight back.
        regressionPending = nil
        regressionUndo = nil
        regressionFloor = targetOffset
        isOffScript = false
        if isListening && (distance > 500 || !audioEngine.isRunning) {
            // Far jump, or the engine died without a config-change callback —
            // fall back to a full restart (also refreshes contextualStrings).
            restartRecognition(resetRetryCount: false)
            return
        }
        spokenAnchorPrefix = lastSpokenText
        lastJumpAt = Date()
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        recognizedCharCount = advancePastAnnotations(from: 0)
        matchStartOffset = recognizedCharCount
        retryCount = 0
        recentMatchPositions = []
        regressionPending = nil
        regressionUndo = nil
        regressionFloor = 0
        isOffScript = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream.")
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldListen,
                          self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginAfterMicrophoneAccess(for: generation)
                    } else {
                        self.failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream.")
                    }
                }
            }
        case .authorized:
            beginAfterMicrophoneAccess(for: generation)
        @unknown default:
            failListening("Microphone authorization is unavailable.")
        }
    }

    private func beginAfterMicrophoneAccess(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }
        if NotchSettings.shared.listeningMode == .wordTracking {
            requestSpeechAuthAndBegin(for: generation)
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin(for generation: Int) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == generation else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                default:
                    self.failListening("Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow Textream.")
                    self.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    private func failListening(_ message: String) {
        voiceActivityDetector.reset()
        shouldListen = false
        isListening = false
        isStarting = false
        error = message
        cleanupRecognition()
    }

    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        cleanupRecognition()
    }

    func forceStop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        sourceText = ""
        annotationRanges = []
        retryCount = maxRetries
        recentMatchPositions = []
        regressionPending = nil
        regressionUndo = nil
        cleanupRecognition()
    }

    func resume() {
        guard !sourceText.isEmpty else { return }
        cleanupRecognition()
        retryCount = 0
        recognizedCharCount = advancePastAnnotations(from: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        regressionPending = nil
        regressionUndo = nil
        isOffScript = false
        shouldDismiss = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func cleanupRecognitionTask() {
        recognitionGeneration &+= 1
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        stopPreemptiveTimer()

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func cleanupRecognition() {
        cleanupRecognitionTask()
        cleanupAudioEngine()
        voiceActivityDetector.reset()
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen, !sourceText.isEmpty else { return }
        isListening = false
        isStarting = true
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldListen,
                  self.sessionGeneration == expectedSessionGeneration,
                  !self.sourceText.isEmpty else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        let expectedSessionGeneration = sessionGeneration
        let requiresSpeechRecognition = NotchSettings.shared.listeningMode == .wordTracking
        // Ensure clean state
        cleanupRecognition()
        guard shouldListen, sessionGeneration == expectedSessionGeneration else {
            isListening = false
            isStarting = false
            return
        }
        isListening = false
        isStarting = true
        regressionUndo = regressionUndoForNewTask()
        // New session = fresh transcript (see restartTask for why
        // lastSpokenText must be cleared alongside the anchor)
        spokenAnchorPrefix = ""
        lastSpokenText = ""
        regressionPending = nil

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            let expectedSessionGeneration = sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.suppressConfigChange = false
            }
        }

        if requiresSpeechRecognition {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
            guard let speechRecognizer else {
                // nil means the locale isn't supported for speech recognition —
                // that's permanent, so fail immediately instead of retrying.
                failListening("Speech recognition isn't supported for the selected language.")
                return
            }
            guard speechRecognizer.isAvailable else {
                // Unavailability is often transient (the recognition service
                // churns briefly after a task cancellation or device change).
                // Giving up here leaves the engine stopped and the app deaf —
                // retry like the invalid-format guard below does.
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleBeginRecognition(after: 0.5)
                } else {
                    failListening("Speech recognizer is not available.")
                }
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                failListening("Unable to create a speech recognition request.")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation

            // Add contextual strings from the source text to improve STT accuracy
            let upcoming = String(sourceText.dropFirst(matchStartOffset))
            let contextWords = upcoming.split(separator: " ")
                .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { $0.count >= 5 }
            let uniqueContextWords = Array(Set(contextWords).prefix(50))
            if !uniqueContextWords.isEmpty {
                recognitionRequest.contextualStrings = uniqueContextWords
            }
        } else {
            speechRecognizer = nil
            recognitionRequest = nil
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio input is unavailable.")
            }
            return
        }

        // SFSpeechRecognizer expects mono voice audio. Downmix multi-channel
        // devices without changing the input node's hardware sample rate.
        guard let tapFormat = speechCaptureFormat(for: hardwareFormat) else {
            failListening("Audio input format is unsupported.")
            return
        }

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.shouldListen,
                  !self.suppressConfigChange,
                  !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        let waveformFrameInterval = AVAudioFrameCount(
            max(1, tapFormat.sampleRate / waveformUpdatesPerSecond)
        )
        var framesSinceWaveformUpdate = waveformFrameInterval

        inputNode.installTap(
            onBus: 0,
            bufferSize: speechCaptureBufferSize(for: tapFormat),
            format: tapFormat
        ) { [weak self] buffer, _ in
            self?.appendBufferToRequest(buffer)

            framesSinceWaveformUpdate &+= buffer.frameLength
            guard framesSinceWaveformUpdate >= waveformFrameInterval else { return }
            framesSinceWaveformUpdate %= waveformFrameInterval

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.recordAudioLevel(level)
            }
        }

        if let speechRecognizer, let recognitionRequest {
            recognitionGeneration &+= 1
            let currentRecognitionGeneration = recognitionGeneration
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        // Ignore stale results from a previous session
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        self.retryCount = 0 // Reset on success
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                        guard self.recognitionRequest != nil else { return }
                        guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                            self.isListening = false
                            self.isStarting = false
                            return
                        }

                        self.matchStartOffset = self.recognizedCharCount

                        // Distinguish timeout errors (expected every ~60s) from real errors.
                        // SFSpeechRecognizer timeout is error code 1110 in kAFAssistantErrorDomain,
                        // or 216 (kAudioConverterErr_FormatNotSupported). Retry immediately for
                        // timeouts with no retry limit; use backoff for real errors.
                        let nsError = error as NSError
                        let isTimeout = nsError.code == 1110 || nsError.code == 216

                        if isTimeout {
                            // Expected timeout — restart immediately, no retry limit
                            self.retryCount = 0
                            if self.audioEngine.isRunning {
                                self.restartTask()
                            } else {
                                self.scheduleBeginRecognition(after: 0.1)
                            }
                        } else if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = min(Double(self.retryCount) * 0.5, 1.5)
                            self.scheduleBeginRecognition(after: delay)
                        } else {
                            self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            guard shouldListen, sessionGeneration == expectedSessionGeneration else {
                cleanupRecognition()
                return
            }
            error = nil
            isStarting = false
            isListening = true
            if requiresSpeechRecognition {
                startPreemptiveTimer()
            }
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartRecognition(resetRetryCount: Bool = true) {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        if resetRetryCount {
            retryCount = 0
        }
        isListening = false
        isStarting = true
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    // MARK: - Thread-safe buffer appending

    private func recordAudioLevel(_ level: CGFloat) {
        audioLevels.append(level)
        if audioLevels.count > 30 {
            audioLevels.removeFirst()
        }
        voiceActivityDetector.process(level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    private func appendBufferToRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    // MARK: - Soft restart (task only, keeps audio engine running)

    private func restartTask() {
        guard shouldListen, isListening, audioEngine.isRunning, !sourceText.isEmpty else {
            isListening = false
            if shouldListen, !sourceText.isEmpty {
                cleanupRecognition()
                scheduleBeginRecognition(after: 0.5)
            }
            return
        }
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        // Update match offset before restarting
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        regressionPending = nil
        regressionUndo = regressionUndoForNewTask()
        // New task = fresh transcript. lastSpokenText must be cleared too:
        // a jump taken before the first new result would otherwise anchor on
        // the old task's transcript and trim away everything the new task
        // ever produces.
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Cancel any pending restart to avoid stale beginRecognition clobbering this session
        pendingRestart?.cancel()
        pendingRestart = nil

        // Cancel the old task and atomically swap to a new request under lock.
        // The lock prevents the audio tap from appending to the old request
        // between endAudio() and the new assignment.
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation

        // Add contextual strings for the remaining text
        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        let uniqueWords = Array(Set(contextWords).prefix(50))
        if !uniqueWords.isEmpty {
            newRequest.contextualStrings = uniqueWords
        }

        // Nil out recognitionRequest before cancelling the old task so the
        // old task's error callback sees nil and skips retry logic. Then set
        // the new request after cancellation.
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        // Start new recognition task
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // Transient unavailability — fall back to a full session restart
            // with retries rather than going permanently deaf.
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                // Don't leave the mic hot with no session consuming it
                failListening("Speech recognizer is not available.")
            }
            return
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    self.retryCount = 0
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    guard self.recognitionRequest != nil else { return }
                    guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
                        self.isStarting = false
                        return
                    }

                    self.matchStartOffset = self.recognizedCharCount

                    let nsError = error as NSError
                    let isTimeout = nsError.code == 1110 || nsError.code == 216

                    if isTimeout {
                        self.retryCount = 0
                        if self.audioEngine.isRunning {
                            self.restartTask()
                        } else {
                            self.scheduleBeginRecognition(after: 0.1)
                        }
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                    }
                }
            }
        }

        startPreemptiveTimer()
    }

    // MARK: - Pre-emptive restart timer

    private func startPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: true) { [weak self] _ in
            guard let self, self.isListening, !self.sourceText.isEmpty else { return }
            self.restartTask()
        }
    }

    private func stopPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken fullSpoken: String) {
        // Results computed before a jump can be delivered just after it —
        // don't match pre-jump speech against the text at the new offset.
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }

        let spoken = spokenSinceJump(fullSpoken)
        guard !spoken.isEmpty else { return }

        // After a re-read jump that the new words show to be wrong, match
        // again from the state before the jump.
        if undoWrongRegression(spoken: spoken) {
            matchCharacters(spoken: fullSpoken)
            return
        }

        // Off script: hold the highlight until the newest words are script
        // words again near the held place (or a longer, unique run further
        // on), or the reader re-reads an earlier line.
        if isOffScript {
            if checkForRegression(spoken: spoken, fullSpoken: fullSpoken, current: recognizedCharCount) {
                isOffScript = false
                return
            }
            guard let run = Self.offScriptResume(source: sourceText, held: recognizedCharCount,
                                                 spoken: Self.regressionWords(in: spoken),
                                                 matches: regressionMatch) else { return }
            // Match on from the start of the run, with the run words as the
            // first words since the anchor, so that a later revision of those
            // words is matched at the same place.
            isOffScript = false
            recognizedCharCount = advancePastAnnotations(from: min(run.end, sourceText.count))
            matchStartOffset = run.start
            recentMatchPositions = []
            regressionPending = nil
            spokenAnchorPrefix = Self.dropLastWords(fullSpoken, run.words)
            return
        }

        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        // Combine the two strategies. When they agree, average; when they
        // disagree, prefer the further (word-level) match so fast reading can
        // catch up instead of being dragged back by the brittle character scan.
        let best = SpeechTextAlignment.bestOffset(characterResult: charResult, wordResult: wordResult)

        let rawCandidate = min(matchStartOffset + best, sourceText.count)
        var candidate = advancePastAnnotations(from: rawCandidate)
        // The reader may have gone back to re-read an earlier line. The
        // re-read words can also look like small forward progress, so check
        // before any forward move.
        if checkForRegression(spoken: spoken, fullSpoken: fullSpoken,
                              current: max(candidate, recognizedCharCount)) {
            return
        }
        // The newest words do not fit the script around the highlight: the
        // reader has gone off script. Hold here. Not while the highlight is
        // still on a tapped word: the reader may be finishing the old sentence.
        let spokenWords = Self.regressionWords(in: spoken)
        let window = Self.offScriptWindow(source: sourceText, from: recognizedCharCount,
                                          to: max(candidate, recognizedCharCount))
        let near = Self.nearScriptWords(source: sourceText, from: recognizedCharCount,
                                        to: max(candidate, recognizedCharCount))
        if !(regressionFloor > 0 && recognizedCharCount == regressionFloor),
           Self.offScriptMisses(spoken: spokenWords, window: window, known: near,
                                matches: regressionMatch) > Self.offScriptMaxMisses {
            isOffScript = true
            return
        }
        // Do not move forward while a re-read waits for confirmation, so the
        // highlight does not run ahead before it jumps back.
        guard regressionPending == nil else { return }
        // A forward move needs the newest words to be script words, and it
        // goes no further than they do. When all of them match just ahead
        // and the matchers lag, follow them.
        guard let support = Self.supportEnd(source: sourceText, spoken: spokenWords, current: recognizedCharCount,
                                            candidate: candidate, known: near, matches: supportMatch) else { return }
        var forward = candidate
        if support.matches >= Self.supportTailWords, support.end + 1 > candidate,
           support.end <= recognizedCharCount + Self.supportFarChars {
            forward = advancePastAnnotations(from: min(support.end + 1, sourceText.count))
        }
        candidate = advancePastAnnotations(from: min(forward, support.end + 1, sourceText.count))
        guard candidate > recognizedCharCount else { return }
        // A move to the end of the page ends the page. Hold it while the
        // newest words look like the start of a re-read, so that the re-read
        // can still take the highlight back.
        if candidate >= sourceText.count,
           Self.regressionHoldsPageEnd(source: sourceText, floor: regressionFloor,
                                       spoken: Self.regressionWords(in: spoken), matches: regressionMatch) {
            return
        }

        // Confidence gating: require 2-of-3 recent results to agree on
        // forward movement to avoid single-result false-positive jumps.
        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 {
            recentMatchPositions.removeFirst()
        }

        // Check if at least 2 of the recent positions agree (within tolerance)
        let agreementThreshold = 10 // characters
        var confirmed = false
        if recentMatchPositions.count >= 2 {
            var agreeCount = 0
            for pos in recentMatchPositions {
                if abs(pos - candidate) <= agreementThreshold {
                    agreeCount += 1
                }
            }
            confirmed = agreeCount >= 2
        }

        // Small forward movements (< 1 word length) are always allowed
        // to keep the highlight responsive for normal reading
        if SpeechTextAlignment.shouldCommit(
            characterResult: charResult,
            wordResult: wordResult,
            current: recognizedCharCount,
            rawCandidate: rawCandidate,
            candidate: candidate,
            confirmed: confirmed
        ) {
            recognizedCharCount = candidate
        }
    }

    /// The transcript from after the most recent jump. Trim by the common
    /// prefix that survived the recognizer's revisions, but never less than
    /// the anchor length minus a small slack — a revision very early in the
    /// transcript would otherwise leak the whole pre-jump transcript back
    /// into matching.
    private func spokenSinceJump(_ fullSpoken: String) -> String {
        guard !spokenAnchorPrefix.isEmpty else { return fullSpoken }
        let common = zip(spokenAnchorPrefix, fullSpoken).prefix(while: { $0 == $1 }).count
        let trimLen = min(fullSpoken.count, max(common, spokenAnchorPrefix.count - 24))
        return String(fullSpoken.dropFirst(trimLen))
    }

    // MARK: - Off script (ad-lib) hold

    /// True while the reader says words that are not in the script near the
    /// highlight (an ad-lib). The highlight holds until offScriptResume finds
    /// the reader, or the reader re-reads an earlier line.
    private(set) var isOffScript = false

    /// The newest spoken words checked against the script around the highlight.
    static let offScriptCheckWords = 4
    /// More misses than this among them (in order) means off script.
    static let offScriptMaxMisses = 1
    /// The check window: script words before the highlight and after the candidate.
    static let offScriptBackWords = 4
    static let offScriptAheadWords = 3
    /// Pick-up near the held place: the newest 3 spoken words are 3 script
    /// words in a row that start from 4 words before to 12 words after it.
    static let resumeRunWords = 3
    static let resumeBackWords = 4
    static let resumeNearWords = 12
    /// Or 3 of the newest 4 words match in order inside 5 script words that
    /// start on one of the first 2 of them (one misheard word).
    static let resumeSlipHits = 3
    /// Further on, up to 400 chars after the held place (the next
    /// paragraph): 4 words in a row, found nowhere else in the searched text.
    static let resumeFarRunWords = 4
    static let resumeFarChars = 400
    /// In pick-up runs, words shorter than 5 letters must match exactly.
    static let resumeExactBelowLetters = 5
    /// A forward move needs 2 of the newest 3 words to match script words in
    /// order (at most 1 script word skipped between them) from 30 chars
    /// before the highlight to 40 chars after the candidate. Support that
    /// starts more than 40 chars after the highlight needs 3 matches.
    static let supportTailWords = 3
    static let supportMinMatches = 2
    static let supportBackChars = 30
    static let supportAheadChars = 40
    static let supportGap = 1
    static let supportFarChars = 40

    /// Words of 3 letters or fewer must match exactly in the support check.
    private func supportMatch(_ a: String, _ b: String) -> Bool {
        a == b || (min(a.count, b.count) >= 4 && isFuzzyMatch(a, b))
    }

    /// How many of the newest `offScriptCheckWords` spoken words are not part
    /// of the best in-order match with the script words in `window`. A
    /// script word said as several words counts as one word, a number in
    /// digits matches it in words (see `numberMatch`), and a name heard as
    /// 2 or 3 other words counts as one miss (see `alignSpoken`).
    static func offScriptMisses(spoken: [String], window: [String], known: Set<String> = [],
                                matches: (String, String) -> Bool) -> Int {
        func same(_ a: String, _ b: String) -> Bool { matches(a, b) || numberMatch(a, b) }
        let recent = Array(spoken.suffix(offScriptCheckWords * spokenFormMaxWords))
        let joined = joinSpokenForms(recent, script: window, partialEnd: true)
        return alignSpoken(joined, window, known: known, countFrom: max(0, joined.count - offScriptCheckWords),
                           matches: same).misses
    }

    // MARK: Words the recogniser writes in another form

    /// Units said with a number ("forty percent", "ninety nine dollars", "nine am").
    static let numberUnits: Set<String> = ["percent", "dollars", "dollar", "pounds", "pound", "euros", "euro", "cents", "k", "grand", "am", "pm"]
    /// The values of number words: zero to nineteen, the tens, hundred to
    /// billion, and the ordinals first to twelfth, twentieth and thirtieth.
    static let numberValues: [String: Int] = {
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                     "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                        "eleventh", "twelfth"]
        var v: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
                                "twentieth": 20, "thirtieth": 30]
        for (k, w) in units.enumerated() { v[w] = k }
        for (k, w) in numberTens.enumerated() { v[w] = 20 + 10 * k }
        for (k, w) in ordinals.enumerated() { v[w] = k + 1 }
        return v
    }()
    static let numberTens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func hasDigit(_ w: String) -> Bool { w.contains { $0.isNumber } }

    /// The value of a number word: "forty" 40, "twentyfour" 24, "third" 3.
    static func numberValue(_ w: String) -> Int? {
        if let v = numberValues[w] { return v }
        for tens in numberTens where w.hasPrefix(tens) {
            if let u = numberValues[String(w.dropFirst(tens.count))], (1...9).contains(u) { return numberValues[tens]! + u }
        }
        return nil
    }

    /// The digits that a number said in words starts with: "21" for "twenty
    /// one", "4" for "four hundred", "20" for "twenty twenty four".
    static func numberStart(_ words: ArraySlice<String>) -> String? {
        guard let first = words.first, let v = numberValue(first) else { return nil }
        if numberTens.contains(first), words.count >= 2, let u = numberValue(words[words.startIndex + 1]),
           (1...9).contains(u) { return String(v + u) }
        return String(v)
    }

    /// The script forms of a number said in words, the closest first: its
    /// value in digits and, when it ends with a scale word, the number before
    /// that word with and without the scale letter. "two thousand five
    /// hundred" is "2500"; "twenty k" is "20000", "20k" or "20"; "two and a
    /// half million" is "2500000", "25m" ("$2.5M") or "25" ("2.5 million").
    /// Unit words ("dollars") do not count.
    static func spokenNumberForms(_ words: ArraySlice<String>) -> [String] {
        func digits(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x).filter(\.isNumber) }
        var total = 0.0, part = 0.0, short: (said: String, letter: String)?
        for (n, w) in words.enumerated() {
            if let letter = scaleLetters[w] ?? (w == "k" ? "k" : nil), letter != "x" {
                short = total == 0 ? (digits(max(part, 1)), letter) : nil
                total += max(part, 1) * Double(numberValues[w] ?? 1000)
                part = 0
            } else if w == "and" || (w == "a" && n > 0) || numberUnits.contains(w) {
                continue
            } else {
                short = nil
                if w == "a" { part = 1 } else if w == "half" { part += 0.5 } else if w == "hundred" {
                    part = max(part, 1) * 100
                } else if let v = numberValue(w) { part += Double(v) } else { return [] }
            }
        }
        return [digits(total + part)] + (short.map { [$0.said + $0.letter, $0.said] } ?? [])
    }

    /// A number word or a unit said with a number.
    static func isNumberWord(_ w: String) -> Bool { numberUnits.contains(w) || numberValue(w) != nil }

    /// A number word and a number in digits, either way round, when the
    /// digits start with the word's value ("40" for "forty", "2024" for
    /// "twenty", "3rd" for "third"), so "12" is not "ten". A tens word fits
    /// 2 or more digits that start with its tens digit ("25" for "twenty" in
    /// "twenty five").
    static func numberMatch(_ script: String, _ spoken: String) -> Bool {
        func fits(_ digits: String, _ word: String) -> Bool {
            guard hasDigit(digits), let v = numberValue(word) else { return false }
            let d = digits.filter { $0.isNumber }
            if numberTens.contains(word) { return d.count >= 2 && d.first == String(v).first }
            return d.hasPrefix(String(v))
        }
        return fits(spoken, script) || fits(script, spoken)
    }

    /// A script word of this many letters or more (a name or a brand) can be
    /// heard as 2 or 3 other words ("Shopify" as "shop if I", "Kajabi" as
    /// "car jabby"), when their letters are within `soundAlikeLetterSlack`
    /// of its letters and none of them with `soundAlikeOwnLetters` letters
    /// or more is itself a script word near the highlight: an ad-lib is made
    /// of common words, and a reader who skips on says script words.
    static let soundAlikeMinLetters = 5
    static let soundAlikeLetterSlack = 3
    static let soundAlikeOwnLetters = 3

    /// The script words up to `resumeFarChars` chars before `from` and after `to`.
    static func nearScriptWords(source: String, from: Int, to: Int) -> Set<String> {
        Set(regressionSourceWords(source, from: max(0, from - resumeFarChars),
                                  to: min(source.count, to + resumeFarChars)).map(\.word))
    }

    /// The best in-order alignment of `spoken` with `script`. A spoken word
    /// is a hit, a miss, or one of 2 or 3 words that stand for one script
    /// word (see `soundAlikeMinLetters`). Such a group comes after a hit and
    /// before a hit; a group of 2 can also be the newest words (the hit after
    /// it is not in yet). A group counts as one miss, at its first word.
    /// Returns the misses at spoken words from `countFrom` on, and `spoken`
    /// with each group that has a hit after it replaced by its script word.
    static func alignSpoken(_ spoken: [String], _ script: [String], known: Set<String> = [], countFrom: Int,
                            matches: (String, String) -> Bool) -> (misses: Int, words: [String]) {
        let n = spoken.count, m = script.count
        let none = Int.max / 2
        let scriptSet = known.union(script)
        let canGroup = spoken.map { $0.count < soundAlikeOwnLetters || !scriptSet.contains($0) }
        // State f: 0 after a miss (or at the start), 1 after a hit, k = 2 or 3
        // after a group of k words (a hit must follow; a group of 2 may end).
        typealias Step = (i: Int, j: Int, f: Int)
        var cost = [[[Int]]](repeating: [[Int]](repeating: [Int](repeating: none, count: 4), count: m + 1), count: n + 1)
        var from = [[[Step?]]](repeating: [[Step?]](repeating: [Step?](repeating: nil, count: 4), count: m + 1), count: n + 1)
        cost[0][0][0] = 0
        func relax(_ i: Int, _ j: Int, _ f: Int, _ c: Int, _ p: Step) {
            if c < cost[i][j][f] { cost[i][j][f] = c; from[i][j][f] = p }
        }
        for i in 0...n { for j in 0...m { for f in 0..<4 {
            let c = cost[i][j][f]
            guard c < none else { continue }
            let p = (i: i, j: j, f: f)
            if j < m { relax(i, j + 1, f, c, p) } // script word not said
            guard i < n else { continue }
            if j < m, matches(script[j], spoken[i]) { relax(i + 1, j + 1, 1, c, p) }
            let miss = i >= countFrom ? 1 : 0
            if f < 2 { relax(i + 1, j, 0, c + miss, p) }
            if f == 1, j < m, script[j].count >= soundAlikeMinLetters {
                for k in 2...3 where i + k <= n && canGroup[i..<(i + k)].allSatisfy({ $0 }) {
                    let letters = spoken[i..<(i + k)].reduce(0) { $0 + $1.count }
                    if abs(letters - script[j].count) <= soundAlikeLetterSlack { relax(i + k, j + 1, k, c + miss, p) }
                }
            }
        } } }
        var best: (j: Int, f: Int)?
        for j in 0...m { for f in 0..<3 where cost[n][j][f] < none {
            if best == nil || cost[n][j][f] < cost[n][best!.j][best!.f] { best = (j, f) }
        } }
        guard let best else { return (0, spoken) }
        var out: [String] = []
        var at = (i: n, j: best.j, f: best.f)
        while let p = from[at.i][at.j][at.f] {
            let k = at.i - p.i
            if k >= 2 {
                if at.i < n { out.append(script[p.j]) } else { out.append(contentsOf: spoken[p.i..<at.i].reversed()) }
            } else if k == 1 {
                out.append(spoken[p.i])
            }
            at = p
        }
        return (cost[n][best.j][best.f], out.reversed())
    }

    /// The most spoken words that can stand for one script word.
    static let spokenFormMaxWords = 3
    /// Short forms that are read in full ("i.e." as "that is", "DFY" as
    /// "done for you"). A plural short form ("KPIs") is its words with "s".
    static let spokenExpansions: [String: Set<String>] = ["ie": ["that is"], "eg": ["for example", "for instance"], "etc": ["et cetera", "and so on"], "vs": ["versus"], "dr": ["doctor"], "mr": ["mister"], "mrs": ["missus", "misses"], "aka": ["also known as"], "diy": ["do it yourself"], "fyi": ["for your information"], "dfy": ["done for you"], "dwy": ["done with you"], "cta": ["call to action"], "ctas": ["calls to action"], "va": ["virtual assistant"], "roi": ["return on investment"], "sop": ["standard operating procedure"], "kpi": ["key performance indicator"]]
    /// Words said after digits for a short letter ("$2M" heard as "$2
    /// million", "$10k" as "10 grand", "10x" as "10 times").
    static let scaleLetters: [String: String] = ["thousand": "k", "million": "m", "billion": "b", "grand": "k", "times": "x"]
    /// The ends of contractions (letters only) and the words they stand for.
    static let contractionEnds: [String: Set<String>] = ["m": ["am"], "s": ["is", "has", "us"], "ve": ["have"], "re": ["are"], "ll": ["will"], "d": ["would", "had"], "t": ["not"], "nt": ["not"]]

    /// True when spoken `words` say the script word `script` as more words:
    /// joined they are the script word ("c r m" for "CRM", "step by step" for
    /// "step-by-step"), or they are a contraction said in full ("i am" for
    /// "I'm", "do not" for "don't"), or a range ("3 to 5" for "3-5"), or a
    /// short form read in full, or digits and a scale word ("2 million" for
    /// "2M", "3 times" for "3x").
    static func isSpokenForm(_ script: String, _ words: ArraySlice<String>) -> Bool {
        let said = words.joined(separator: " ")
        if spokenExpansions[script]?.contains(said) == true { return true }
        if script.count > 2, script.hasSuffix("s"),
           spokenExpansions[String(script.dropLast())]?.contains(where: { $0 + "s" == said }) == true { return true }
        if words.count == 2, let first = words.first, first.allSatisfy(\.isNumber),
           let letter = scaleLetters[words.last!], first + letter == script { return true } // "2 million" for "2M"
        if words.count == 3, rangeDigits(words) == script { return true }
        if words.count == 3, words[words.startIndex + 1] == "and",
           words.first! + words.last! == script { return true } // "q and a" for "Q&A"
        guard words.count >= 2 else { return false }
        if words.joined() == script { return true }
        guard words.count == 2, let first = words.first, let last = words.last,
              first.count < script.count, script.hasPrefix(first) else { return false }
        return contractionEnds[String(script.dropFirst(first.count))]?.contains(last) == true
    }

    /// A range said with "to" ("3 to 5", "three to five") as the script word
    /// of a range in digits ("3-5" is "35" as letters and digits), or its
    /// start ("3 to" is "3"). The end can carry a unit: "3 to 5k", "4 to 6
    /// pm", "2 to 3 times" are "35k", "46pm", "23x" (see `scaleLetters`).
    static func rangeDigits(_ words: ArraySlice<String>) -> String? {
        func digits(_ w: String) -> String? { w.allSatisfy(\.isNumber) ? w : numberValue(w).map { String($0) } }
        let s = words.startIndex
        guard (2...4).contains(words.count), words[s + 1] == "to", let a = digits(words[s]) else { return nil }
        guard words.count > 2 else { return a }
        let end = words[s + 2]
        if words.count == 4 {
            guard let b = digits(end), words[s + 3].allSatisfy(\.isLetter) else { return nil }
            return a + b + (scaleLetters[words[s + 3]] ?? words[s + 3])
        }
        if let b = digits(end) { return a + b }
        let b = end.prefix { $0.isNumber } // "5k"
        return !b.isEmpty && end.dropFirst(b.count).allSatisfy(\.isLetter) ? a + end : nil
    }

    /// `spoken` with each 2 or 3 words in a row that say one word of `script`
    /// (see `isSpokenForm`) replaced by that word. With `partialEnd`, the
    /// last 2 or 3 words can also be the start of one ("c r" while the reader
    /// says "CRM").
    static func joinSpokenForms(_ spoken: [String], script: [String], partialEnd: Bool = false) -> [String] {
        var out: [String] = []
        var i = 0
        while i < spoken.count {
            var joined: (word: String, count: Int)?
            // A number said in words ("two thousand five hundred dollars") for a
            // script number in digits ("$2,500"): the whole run of number words.
            // "a" before a scale word is one ("a million", "a hundred bucks").
            let one = spoken[i] == "a" && i + 1 < spoken.count && ["hundred", "thousand", "million"].contains(spoken[i + 1])
            if one || (isNumberWord(spoken[i]) && !numberUnits.contains(spoken[i])),
               let start = one ? "1" : numberStart(spoken[i...]),
               case let fits = script.filter({ hasDigit($0) && $0.filter(\.isNumber).hasPrefix(start) }), !fits.isEmpty {
                var run = 1
                while i + run < spoken.count {
                    // "and" inside a number ("four hundred and ninety seven",
                    // "two and a half million").
                    let half = spoken[i + run] == "and" && i + run + 2 < spoken.count
                        && spoken[i + run + 1] == "a" && spoken[i + run + 2] == "half"
                    let and = spoken[i + run] == "and" && ["hundred", "thousand", "million"].contains(spoken[i + run - 1])
                        && i + run + 1 < spoken.count && numberValue(spoken[i + run + 1]) != nil
                    guard isNumberWord(spoken[i + run]) || and || half else { break }
                    run += half ? 3 : and ? 2 : 1
                }
                // Of several script numbers that start with these digits, the one
                // with the value said wins ("one million" is "1m", not "10k"; "two
                // thousand five hundred" is "2500", not "20k"; "two and a half" the
                // start of "25m"), else a plain number, else the first. A run with
                // "a" or "half" joins only its value ("a hundred" is "100", not "12").
                // Words read as written ("a hundred" in the script) stay as they are.
                let words = spoken[i..<(i + run)], forms = spokenNumberForms(words)
                let w = forms.lazy.compactMap { f in fits.first { $0 == f || $0.filter(\.isNumber) == f } }.first
                    ?? (one || words.contains("half") ? nil : fits.first { $0.allSatisfy(\.isNumber) } ?? fits[0])
                if run >= 2, let w, !hasRun(script, words) { joined = (w, run) }
            }
            // A range with a unit word ("4 to 6 pm" for "4-6pm", "3 to 5 grand" for "$3-5k").
            if joined == nil, i + 4 <= spoken.count, let r = rangeDigits(spoken[i..<(i + 4)]), script.contains(r) {
                joined = (r, 4)
            }
            for k in stride(from: spokenFormMaxWords, through: 1, by: -1) where joined == nil && i + k <= spoken.count {
                let group = spoken[i..<(i + k)]
                // Words read as written ("every day" in a script that also has
                // "everyday") stay as they are.
                if k >= 2, hasRun(script, group) { continue }
                let atEnd = partialEnd && k >= 2 && i + k == spoken.count
                // The start of a range ("3 to", "4 to 6" while the reader says "4 to 6 pm").
                let rangeStart = atEnd ? rangeDigits(group) : nil
                if let w = script.first(where: { s in isSpokenForm(s, group)
                    || (atEnd && s.count > group.joined().count && s.hasPrefix(group.joined()))
                    || (rangeStart.map { s.count > $0.count && s.hasPrefix($0) && s.drop(while: \.isNumber).allSatisfy(\.isLetter) } ?? false) }) {
                    joined = (w, k)
                    break
                }
            }
            out.append(joined?.word ?? spoken[i])
            i += joined?.count ?? 1
        }
        return out
    }

    /// True when `words` are in `script` as words in a row.
    static func hasRun(_ script: [String], _ words: ArraySlice<String>) -> Bool {
        guard !words.isEmpty, words.count <= script.count else { return false }
        return (0...(script.count - words.count)).contains { script[$0..<($0 + words.count)].elementsEqual(words) }
    }

    /// Script words for the off-script check: `offScriptBackWords` words
    /// before `from`, the words from `from` to `to`, and
    /// `offScriptAheadWords` words after `to`. Stage directions are left out.
    static func offScriptWindow(source: String, from: Int, to: Int) -> [String] {
        let words = regressionSourceWords(source, from: max(0, from - 400), to: min(source.count, to + 400))
        let i0 = words.firstIndex { $0.start >= from } ?? words.count
        let i1 = words.firstIndex { $0.start >= to } ?? words.count
        return words[max(0, i0 - offScriptBackWords)..<min(words.count, i1 + offScriptAheadWords)].map(\.word)
    }

    /// The length of the longest in-order match between spoken and script words.
    static func inOrderHits(_ spoken: [String], _ script: [String],
                            matches: (String, String) -> Bool) -> Int {
        guard !spoken.isEmpty, !script.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: script.count + 1)
        for w in spoken {
            var cur = [Int](repeating: 0, count: script.count + 1)
            for j in script.indices {
                cur[j + 1] = matches(script[j], w) ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[script.count]
    }

    /// The longest in-order match and the script index of the first script
    /// word that completes it.
    static func inOrderLast(_ spoken: [String], _ script: [String],
                            matches: (String, String) -> Bool) -> (hits: Int, last: Int)? {
        guard !spoken.isEmpty, !script.isEmpty else { return nil }
        let n = spoken.count, m = script.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { for j in 1...m {
            dp[i][j] = matches(script[j - 1], spoken[i - 1]) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
        } }
        guard dp[n][m] > 0 else { return nil }
        var j = 1
        while dp[n][j] < dp[n][m] { j += 1 }
        return (dp[n][m], j - 1)
    }

    /// `text` without its last `n` space-separated words.
    static func dropLastWords(_ text: String, _ n: Int) -> String {
        var idx = text.endIndex
        var left = n
        while left > 0, idx > text.startIndex {
            idx = text.index(before: idx)
            while idx > text.startIndex, text[idx] == " " { idx = text.index(before: idx) }
            while idx > text.startIndex, text[text.index(before: idx)] != " " { idx = text.index(before: idx) }
            left -= 1
        }
        return String(text[..<idx])
    }

    /// Where to pick up after an ad-lib: the start of the script run that the
    /// newest spoken words match, the char offset just after its last word,
    /// and how many newest spoken words it used. Nil while the newest words
    /// are not back on the script. The search goes from `resumeBackWords`
    /// words before `held` forward; the first match wins.
    static func offScriptResume(source: String, held: Int, spoken: [String],
                                matches: (String, String) -> Bool) -> (start: Int, end: Int, words: Int)? {
        let words = regressionSourceWords(source, from: max(0, held - 200),
                                          to: min(source.count, held + resumeFarChars))
        let iHeld = words.firstIndex { $0.start >= held } ?? words.count
        let atEnd = held + resumeFarChars >= source.count
        func same(_ a: String, _ b: String) -> Bool {
            min(a.count, b.count) < resumeExactBelowLetters ? a == b : matches(a, b)
        }
        func runAt(_ k: Int, _ need: Int) -> Bool {
            k >= 0 && k + need <= words.count
                && zip(words[k..<(k + need)], spoken.suffix(need)).allSatisfy { same($0.0.word, $0.1) }
        }
        func end(_ k: Int) -> Int { words[k].start + words[k].length + 1 }
        let newest = Array(spoken.suffix(offScriptCheckWords))
        var i = max(0, iHeld - resumeBackWords)
        while i < words.count {
            let near = i - iHeld <= resumeNearWords
            let need = near ? resumeRunWords : resumeFarRunWords
            if spoken.count >= need, runAt(i, need) {
                // A far run must be the only place with these words.
                if !near, words.indices.contains(where: { $0 != i && runAt($0, need) }) { return nil }
                return (words[i].start, end(i + need - 1), need)
            }
            if near, newest.count >= resumeSlipHits,
               newest.prefix(2).contains(where: { same(words[i].word, $0) }) {
                let span = words[i..<min(words.count, i + offScriptCheckWords + 1)].map(\.word)
                if let m = inOrderLast(newest, span, matches: same), m.hits >= resumeSlipHits {
                    return (words[i].start, end(i + m.last), newest.count)
                }
            }
            // At most resumeRunWords words from here to the page end, and none
            // after the held place left out: all of them in a row pick up, or
            // all but one in order (a single word must have 5 letters or more).
            let left = words.count - i
            if atEnd, i <= iHeld, left <= resumeRunWords {
                if left < resumeRunWords, spoken.count >= left, runAt(i, left) {
                    return (words[i].start, end(words.count - 1), left)
                }
                if left >= 2, let m = inOrderLast(newest, words[i...].map(\.word), matches: same),
                   i + m.last >= iHeld, m.hits >= left - 1,
                   m.hits >= 2 || words[i + m.last].word.count >= resumeExactBelowLetters {
                    return (words[i].start, end(i + m.last), newest.count)
                }
            }
            i += 1
        }
        return nil
    }

    /// The char offset where the newest spoken words end in the script when
    /// they continue it near the highlight, and how many of them matched.
    /// Nil when they do not: no forward move. Support that ends after
    /// `current` is preferred; support behind it still means on script.
    static func supportEnd(source: String, spoken: [String], current: Int, candidate: Int, known: Set<String> = [],
                           matches: (String, String) -> Bool) -> (end: Int, matches: Int)? {
        let words = regressionSourceWords(source, from: max(0, current - supportBackChars),
                                          to: max(candidate, current) + supportAheadChars)
        func same(_ a: String, _ b: String) -> Bool { matches(a, b) || numberMatch(a, b) }
        let recent = Array(spoken.suffix(supportTailWords * spokenFormMaxWords))
        let joined = joinSpokenForms(recent, script: words.map(\.word))
        let tail = Array(alignSpoken(joined, words.map(\.word), known: known, countFrom: 0,
                                     matches: same).words.suffix(supportTailWords))
        guard !tail.isEmpty else { return nil }
        let minMatches = min(supportMinMatches, tail.count)
        var behind: (end: Int, matches: Int)?
        var ahead: (end: Int, matches: Int)?
        for e in words.indices {
            // The newest word may be a misheard script word: try the one before it too.
            for newest in stride(from: tail.count - 1, through: max(0, tail.count - 2), by: -1) {
                // One spoken word for 2 script words ("everyone" for "every one",
                // "cannot" for "can not") matches the first and ends on the second.
                let pair = e + 1 < words.count && tail[newest] == words[e].word + words[e + 1].word
                guard pair || same(words[e].word, tail[newest]) else { continue }
                var hits = 1
                var si = e
                var ti = newest - 1
                while ti >= 0 && si > 0 {
                    var hit: Int?
                    for back in 1...(1 + supportGap) where si - back >= 0 {
                        if same(words[si - back].word, tail[ti]) { hit = si - back; break }
                    }
                    if let hit { si = hit; hits += 1 }
                    ti -= 1
                }
                guard hits >= minMatches else { continue }
                if words[e].start > current + supportFarChars, hits < supportTailWords { continue }
                // When the newest word did not match, allow the next script word too.
                let f = (e + 1 < words.count && (newest < tail.count - 1 || pair)) ? e + 1 : e
                let end = words[f].start + words[f].length
                if end > current {
                    if ahead == nil || hits > ahead!.matches { ahead = (end, hits) }
                } else if behind == nil || hits > behind!.matches { behind = (end, hits) }
                break
            }
        }
        return ahead ?? behind
    }

    // MARK: - Regression (re-reading an earlier line)

    /// The re-read run that waits for confirmation: where it ends and how
    /// many times it has grown.
    private var regressionPending: (end: Int, growths: Int)?
    /// A re-read never lands before the last tapped word, until the newest
    /// words show that the reader reads after that word.
    private var regressionFloor = 0
    /// The last re-read jump until the next words check it: where it landed,
    /// the state from before it, and the words said since it in earlier
    /// recognition tasks.
    private var regressionUndo: (target: Int, recognized: Int, matchStart: Int, anchor: String, said: [String])?
    private static let regressionWindowChars = 700
    private static let regressionLookAheadChars = 300
    private static let regressionMinWords = 4
    private static let regressionMinGapChars = 30
    private static let regressionGrowthsToConfirm = 2
    private static let regressionMaxGrowthChars = 40

    /// If the tail of what was just spoken matches a run of words behind
    /// `current`, jump back there. The jump needs the run to grow twice with
    /// newly spoken words, so a chance match of 4 or 5 earlier words is not
    /// enough. An aside that matches 6 earlier words in a row, with the
    /// script words next to it, can still cause a jump. undoWrongRegression
    /// then puts the highlight back. Returns true when it jumped.
    private func checkForRegression(spoken: String, fullSpoken: String, current: Int) -> Bool {
        let spokenWords = Self.regressionWords(in: spoken)
        guard spokenWords.count >= Self.regressionMinWords else { return false }
        let tail = Array(spokenWords.suffix(Self.regressionMinWords + 2))

        if regressionFloor > 0,
           Self.regressionFloorReleased(source: sourceText, current: current, floor: regressionFloor,
                                        tail: tail, matches: regressionMatch) {
            regressionFloor = 0
        }

        let end = Self.regressionEnd(
            source: sourceText, current: current, floor: regressionFloor, tail: tail,
            matches: regressionMatch
        )
        guard Self.regressionConfirmed(pending: &regressionPending, end: end),
              let end else { return false }

        // Land just after the re-read words, where the reader is now, and
        // treat everything spoken so far as consumed so matching continues
        // forward from there.
        let target = advancePastAnnotations(from: min(end + 1, sourceText.count))
        regressionUndo = (target, recognizedCharCount, matchStartOffset, spokenAnchorPrefix, [])
        recognizedCharCount = target
        matchStartOffset = target
        recentMatchPositions = []
        spokenAnchorPrefix = fullSpoken
        lastJumpAt = Date()
        return true
    }

    /// After a re-read jump, the next words must continue the text at the
    /// jump target. When they do not, the jump was wrong: put back the state
    /// from before it. Returns true when it did that.
    private func undoWrongRegression(spoken: String) -> Bool {
        guard let undo = regressionUndo,
              let kept = Self.regressionKept(source: sourceText, target: undo.target,
                                             spoken: undo.said + Self.regressionWords(in: spoken),
                                             matches: regressionMatch)
        else { return false }
        regressionUndo = nil
        guard !kept else { return false }
        recognizedCharCount = undo.recognized
        matchStartOffset = undo.matchStart
        spokenAnchorPrefix = undo.anchor
        recentMatchPositions = []
        regressionPending = nil
        return true
    }

    /// The check of the last re-read jump for a new recognition task, which
    /// starts a fresh transcript. Call it before the transcript is cleared:
    /// it keeps the words said since the jump, so that the check goes on
    /// with the new words after them. An undo matches the new transcript
    /// from the highlight before the jump.
    private func regressionUndoForNewTask() -> (target: Int, recognized: Int, matchStart: Int, anchor: String, said: [String])? {
        regressionUndo.map {
            ($0.target, $0.recognized, $0.recognized, "",
             $0.said + Self.regressionWords(in: spokenSinceJump(lastSpokenText)))
        }
    }

    private func regressionMatch(_ source: String, _ spoken: String) -> Bool {
        source == spoken || isFuzzyMatch(source, spoken)
    }

    /// The words of `text` as lowercased letters and digits.
    private static func regressionWords(in text: String) -> [String] {
        splitTextIntoWords(text.lowercased())
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    /// True when the re-read run in `pending` has grown with newly spoken
    /// words `regressionGrowthsToConfirm` times. The run grows when a later
    /// result ends it further on, by at most `regressionMaxGrowthChars`. A
    /// result with the same end (a partial that only revises words) keeps
    /// waiting. A nil end, a smaller end or a bigger step starts again.
    static func regressionConfirmed(pending: inout (end: Int, growths: Int)?, end: Int?) -> Bool {
        guard let end else {
            pending = nil
            return false
        }
        guard let previous = pending else {
            pending = (end, 0)
            return false
        }
        if end == previous.end { return false }
        guard end > previous.end, end - previous.end <= regressionMaxGrowthChars else {
            pending = (end, 0)
            return false
        }
        let growths = previous.growths + 1
        guard growths >= regressionGrowthsToConfirm else {
            pending = (end, growths)
            return false
        }
        pending = nil
        return true
    }

    /// Where the reader is when the spoken tail matches a run of words behind
    /// `current`: the char offset just after the run's last matched word.
    /// The search starts at `floor`, at most `regressionWindowChars` back,
    /// and goes on `regressionLookAheadChars` past `current`, because the
    /// highlight can be behind the reader. Nil when the best run (see
    /// regressionRun) has fewer than `regressionMinWords` words, or when it
    /// is the text just read: it ends after `current` or within
    /// `regressionMinGapChars` of it, or only stage directions follow it
    /// before `current`.
    static func regressionEnd(
        source: String, current: Int, floor: Int = 0, tail: [String],
        matches: (String, String) -> Bool
    ) -> Int? {
        let start = max(floor, current - regressionWindowChars)
        guard start < current else { return nil }
        let words = regressionSourceWords(source, from: start, to: current + regressionLookAheadChars)
        guard let run = regressionRun(words, tail: tail, matches: matches),
              run.length >= regressionMinWords else { return nil }
        let end = words[run.last].start + words[run.last].length
        guard end < current - regressionMinGapChars,
              run.last + 1 < words.count, words[run.last + 1].start < current else { return nil }
        return end
    }

    /// True when the newest words show that the reader reads after the
    /// tapped word at `floor`: they match a run of `regressionMinWords` or
    /// more words after it that ends near `current`, and no text before it
    /// matches them as well.
    static func regressionFloorReleased(
        source: String, current: Int, floor: Int, tail: [String],
        matches: (String, String) -> Bool
    ) -> Bool {
        let after = regressionSourceWords(source, from: floor, to: current + regressionLookAheadChars)
        guard let run = regressionRun(after, tail: tail, matches: matches),
              run.length >= regressionMinWords,
              after[run.last].start + after[run.last].length >= current - regressionMinGapChars
        else { return false }
        let before = regressionSourceWords(source, from: current - regressionWindowChars, to: floor)
        return run.length > (regressionRun(before, tail: tail, matches: matches)?.length ?? 0)
    }

    /// After a re-read jump to `target`: true when the words said since the
    /// jump continue the text there, false when they do not, and nil until 2
    /// words match or 2 words miss. 2 words that match the next words in
    /// order keep the jump, and 2 other words undo it. Until a word matches,
    /// a word that matches (or ends) one of the last `regressionMinWords + 2`
    /// words before `target` is neither a match nor a miss: the reader can say
    /// the re-read words again, and a revision of the transcript can put them,
    /// or the end of one, back into the words since the jump. The jump came
    /// from at most that many spoken words (the tail in checkForRegression),
    /// so these are the source words it re-read. When such words also match
    /// the next words, a later word can also match after them. After a match,
    /// a re-read word that does not continue the text means the reader went
    /// back: the count starts again from `target`. From then on a word can
    /// skip 1 source word (the recognizer dropped or misheard a word), and a
    /// skip needs 3 matching words instead of 2, so a restated aside does not
    /// keep a wrong jump through a loose match further on.
    static func regressionKept(
        source: String, target: Int, spoken: [String],
        matches: (String, String) -> Bool
    ) -> Bool? {
        let next = regressionSourceWords(source, from: target, to: source.count).map(\.word)
        let reread = regressionSourceWords(source, from: max(0, target - regressionWindowChars), to: target)
            .suffix(regressionMinWords + 2).map(\.word)
        var k = 0
        // Just after the re-read words that also match the next words.
        var ahead = 0
        var hits = 0
        var misses = 0
        var restarted = false
        var needed = 2
        for word in spoken {
            // A spoken word can skip up to 2 source words (dropped words). After a
            // restart it can skip 1.
            func match(from i: Int) -> Int? {
                next[i..<min(next.count, i + (restarted ? 2 : 3))].firstIndex(where: { matches($0, word) })
            }
            let rereadWord = reread.contains(where: { matches($0, word) || $0.hasSuffix(word) })
            if hits > 0, rereadWord, match(from: k) == nil {
                // The reader went back to the re-read words: count from the jump again.
                hits = 0
                k = 0
                ahead = 0
                restarted = true
                needed = 2
            }
            let isRereadWord = hits == 0 && rereadWord
            if let m = match(from: k), !isRereadWord {
                hits += 1
                if restarted, m > k { needed = 3 }
                k = m + 1
            } else if !isRereadWord, ahead > k, let m = match(from: ahead) {
                hits += 1
                if restarted, m > ahead { needed = 3 }
                k = m + 1
            } else if isRereadWord {
                if let m = match(from: ahead) { ahead = m + 1 }
            } else {
                misses += 1
            }
            if hits == needed { return true }
            if misses == 2 { return false }
        }
        return nil
    }

    /// True when a move to the end of the page can be the first words of a
    /// re-read: the 2 newest words do not both match the last 4 words of the
    /// page in order, and in the last `regressionWindowChars` (after `floor`)
    /// the 3 newest words match 3 words in a row, or the 2 newest words match
    /// 2 words in a row before the last 4 words. The 2-word case also needs
    /// fewer than 2 of the 3 newest words to match the last 4 words in order,
    /// so one extra word before the last word does not hold the end.
    static func regressionHoldsPageEnd(
        source: String, floor: Int, spoken: [String],
        matches: (String, String) -> Bool
    ) -> Bool {
        let words = regressionSourceWords(source, from: max(floor, source.count - regressionWindowChars), to: source.count)
        guard spoken.count >= 3, words.count > 4 else { return false }
        let last = words.suffix(4).map(\.word)
        func lastWordHits(_ said: ArraySlice<String>) -> Int {
            var k = 0
            var hits = 0
            for word in said {
                if let m = last[k...].firstIndex(where: { matches($0, word) }) {
                    hits += 1
                    k = m + 1
                }
            }
            return hits
        }
        guard lastWordHits(spoken.suffix(2)) < 2 else { return false }
        if regressionRun(words, tail: Array(spoken.suffix(3)), matches: matches)?.length == 3 { return true }
        return lastWordHits(spoken.suffix(3)) < 2
            && regressionRun(Array(words.dropLast(4)), tail: Array(spoken.suffix(2)), matches: matches)?.length == 2
    }

    /// The best run for the spoken `tail` in `words`: the most consecutive
    /// words that match tail words in order (tail words can be skipped) and
    /// end on the newest tail word. On a tie the latest run wins. `last` is
    /// the index of the run's last word.
    static func regressionRun(
        _ words: [(word: String, start: Int, length: Int)], tail: [String],
        matches: (String, String) -> Bool
    ) -> (length: Int, last: Int)? {
        var best: (length: Int, last: Int)?
        for i in words.indices {
            var length = 0
            var j = 0
            var last = -1
            var lastTail = -1
            while i + length < words.count, j < tail.count {
                if matches(words[i + length].word, tail[j]) {
                    last = i + length
                    lastTail = j
                    length += 1
                }
                j += 1
            }
            if lastTail == tail.count - 1, length >= (best?.length ?? 0) {
                best = (length, last)
            }
        }
        return best
    }

    /// The words of `source` that start in `from..<to`, as lowercased
    /// letters and digits with their char offset and length. Stage
    /// directions are left out.
    static func regressionSourceWords(
        _ source: String, from: Int, to: Int
    ) -> [(word: String, start: Int, length: Int)] {
        var out: [(word: String, start: Int, length: Int)] = []
        var pos = 0
        let words = source.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let inAnnotation = SpeechTextAlignment.annotationFlags(for: words)
        for (k, word) in words.enumerated() {
            if pos >= to { break }
            if pos >= from, !inAnnotation[k] {
                let clean = word.lowercased().filter { $0.isLetter || $0.isNumber }
                if !clean.isEmpty { out.append((clean, pos, word.count)) }
            }
            pos += word.count + 1
        }
        return out
    }

    private func advancePastAnnotations(from offset: Int) -> Int {
        SpeechTextAlignment.advancePastAnnotations(
            in: sourceText,
            ranges: annotationRanges,
            from: offset
        )
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        // Use Character arrays (not unicodeScalars) so counts match sourceText.count
        let src = Array(remainingSource.lowercased())
        let spk = Array(Self.normalize(spoken))

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            if sc == "[",
               let closingIndex = src[si...].firstIndex(of: "]") {
                si = closingIndex + 1
                lastGoodOrigIndex = si
                continue
            }

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 5 chars in spoken (STT inserted extra chars, or
                // fast reading outran the scan)
                let maxSkipR = min(5, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 5 chars in source (STT missed some chars, or
                // fast reading outran the scan)
                let maxSkipS = min(5, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // No resync found — advance spoken pointer only.
                // Do NOT advance lastGoodOrigIndex; this is a genuine mismatch,
                // not a confirmed match position.
                ri += 1
            }
        }

        while si < src.count {
            if src[si] == "[",
               let closingIndex = src[si...].firstIndex(of: "]") {
                si = closingIndex + 1
                lastGoodOrigIndex = si
            } else if !src[si].isLetter && !src[si].isNumber {
                si += 1
                lastGoodOrigIndex = si
            } else {
                break
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map { String($0) }
        let spokenWords = splitTextIntoWords(spoken.lowercased())

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0
        var isInsideAnnotation = false

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            let beginsAnnotation = sourceWords[si].hasPrefix("[")
                && sourceWords[si...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[si])
            if skipsAnnotation {
                if beginsAnnotation {
                    isInsideAnnotation = true
                }
                if sourceWords[si].contains("]") {
                    isInsideAnnotation = false
                }
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation
                matchedCharCount += sourceWords[si].count
                si += 1
                ri += 1
                // Add space separator only if there's a following word
                if si < sourceWords.count {
                    matchedCharCount += 1
                }
            } else {
                // Try skipping up to 5 spoken words (STT hallucinated words,
                // or fast reading produced a burst)
                var foundSpk = false
                let maxSpkSkip = min(5, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 5 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(5, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count {
            let beginsAnnotation = sourceWords[si].hasPrefix("[")
                && sourceWords[si...].contains(where: { $0.contains("]") })
            let skipsAnnotation = isInsideAnnotation || beginsAnnotation || Self.isAnnotationWord(sourceWords[si])
            guard skipsAnnotation else { break }
            if beginsAnnotation {
                isInsideAnnotation = true
            }
            if sourceWords[si].contains("]") {
                isInsideAnnotation = false
            }
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        let shorter = min(a.count, b.count)
        // Prefix match — only for words with at least 3 chars to avoid
        // false positives like "or" matching "organization"
        if shorter >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        // Shared prefix >= 60% of shorter word (min 3 chars shared)
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        if shorter >= 3 && shared >= max(3, shorter * 3 / 5) { return true }
        // Edit distance tolerance — stricter for very short words
        let dist = editDistance(a, b)
        if shorter <= 2 { return false } // 2-char words must be exact
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }
}
