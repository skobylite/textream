//
//  SpeechAnalyzerEngine.swift
//  Textream
//

import AVFoundation
import CoreMedia
import Speech

/// One result of the macOS 26 speech model, as plain values.
struct SpeechModelResult {
    var text: String
    var isFinal: Bool
    /// The audio time range of the result, in seconds from the first buffer.
    var start: Double
    var end: Double
    /// The audio time where each word ends. Final results only: the model
    /// gives word times only for them.
    var wordEnds: [Double] = []
}

/// What SpeechRecognizer keeps of the macOS 26 engine. SpeechRecognizer
/// builds for macOS 15, so it keeps the engine as this protocol.
protocol SpeechModelSession: AnyObject {
    /// The microphone tap gives its buffers here.
    var feed: SpeechModelFeed { get }
    /// Ends the input and the results at once. The analyzer finishes in the
    /// background. The task ends when it has finished.
    func stop() -> Task<Void, Never>
}

/// Converts the tap buffers to the model's audio format and passes them on,
/// each with a start time that only goes up. The audio thread calls
/// `append`; a lock guards the state.
nonisolated final class SpeechModelFeed: @unchecked Sendable {
    let format: AVAudioFormat
    /// With grouping on, each input holds at least this many frames.
    private let groupFrames: AVAudioFrameCount
    private let send: @Sendable (AVAudioPCMBuffer, Int64) -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var group: AVAudioPCMBuffer?
    private var framesSent: Int64 = 0
    private var sizes = (min: 0, max: 0)
    private var finished = false

    /// `send` gets each input and its start frame. `groupFrames` 0 sends
    /// each converted tap buffer at once.
    init(format: AVAudioFormat, groupFrames: AVAudioFrameCount,
         send: @escaping @Sendable (AVAudioPCMBuffer, Int64) -> Void) {
        self.format = format
        self.groupFrames = groupFrames
        self.send = send
    }

    /// The smallest and largest input sent, in frames (0 before the first).
    var inputFrames: (min: Int, max: Int) {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, buffer.frameLength > 0, let converted = convert(buffer) else { return }
        guard groupFrames > 0 else {
            pass(converted)
            return
        }
        if let group, !Self.copy(converted, into: group) {
            pass(group)
            self.group = nil
        }
        if group == nil {
            group = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: groupFrames * 2 + converted.frameLength)
            if let group, !Self.copy(converted, into: group) { self.group = nil }
        }
        if let group, group.frameLength >= groupFrames {
            pass(group)
            self.group = nil
        }
    }

    /// Stops the feed. Later buffers go nowhere.
    func finish() {
        lock.lock()
        finished = true
        group = nil
        lock.unlock()
    }

    /// One converter from the tap format to the model format. It is made
    /// again when the tap format changes (another microphone).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // No priming, as in Apple's sample, so that the audio times do not drift.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The converter calls the block during convert, on this thread.
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Sends one input. Its start is the count of frames sent before it.
    private func pass(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        sizes = sizes.max == 0 ? (frames, frames) : (min(sizes.min, frames), max(sizes.max, frames))
        send(buffer, framesSent)
        framesSent += Int64(frames)
    }

    /// Adds the frames of `source` after the frames of `target`. False when
    /// they do not fit.
    private static func copy(_ source: AVAudioPCMBuffer, into target: AVAudioPCMBuffer) -> Bool {
        guard target.frameLength + source.frameLength <= target.frameCapacity else { return false }
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard from.count == to.count else { return false }
        for i in 0..<from.count {
            guard let src = from[i].mData, let dst = to[i].mData else { return false }
            memcpy(dst + Int(target.frameLength) * bytesPerFrame, src, Int(source.frameLength) * bytesPerFrame)
        }
        target.frameLength += source.frameLength
        return true
    }
}

/// Apple's SpeechTranscriber (macOS 26 and later) on one SpeechAnalyzer, fed
/// from Textream's microphone tap. It works on this Mac only.
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: SpeechModelSession {
    struct Options {
        /// Faster results from a smaller context window, but less accurate.
        var fastResults = true
        /// Groups the small tap buffers into inputs of 100 ms.
        var groupBuffers = false
    }

    /// Why the model cannot start.
    enum SetupError: LocalizedError {
        case notAvailable, unsupportedLanguage, modelNotInstalled, stopped

        var errorDescription: String? {
            switch self {
            case .notAvailable: return "not available on this Mac"
            case .unsupportedLanguage: return "language not supported"
            case .modelNotInstalled: return "model not installed"
            case .stopped: return "the model stopped"
            }
        }
    }

    let feed: SpeechModelFeed
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    /// Why the results ended: their error, or SetupError.stopped when they
    /// ended without one. Nil while they run.
    private var resultsEnd: Error?

    private init(analyzer: SpeechAnalyzer, feed: SpeechModelFeed, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.feed = feed
        self.input = input
    }

    /// Sets up the model and starts it, in this order: isAvailable,
    /// supportedLocale(equivalentTo:), the asset status (with a reservation
    /// when needed, never a download), bestAvailableAudioFormat,
    /// prepareToAnalyze, the results, the input. It first waits for
    /// `previous`, so that only one analyzer runs at a time. After each
    /// step it asks `isCurrent`, and throws CancellationError when the
    /// listening session has changed. It also throws when the results end
    /// before it returns, because SpeechRecognizer ignores an end that
    /// comes before it has the model.
    @MainActor
    static func start(localeIdentifier: String, options: Options, after previous: Task<Void, Never>?,
                      isCurrent: @escaping @MainActor () -> Bool,
                      onResult: @escaping @MainActor (SpeechModelResult) -> Void,
                      onEnd: @escaping @MainActor (Error?) -> Void) async throws -> SpeechAnalyzerEngine {
        func check() throws {
            if !isCurrent() { throw CancellationError() }
        }
        await previous?.value
        try check()
        guard SpeechTranscriber.isAvailable else { throw SetupError.notAvailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw SetupError.unsupportedLanguage
        }
        try check()
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if options.fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting,
                                            attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            try check()
            try await AssetInventory.reserve(locale: locale)
            try check()
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw SetupError.modelNotInstalled
            }
        }
        try check()
        // No format means that the assets are missing.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SetupError.modelNotInstalled
        }
        try check()
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let timescale = CMTimeScale(format.sampleRate)
        let groupFrames = options.groupBuffers ? AVAudioFrameCount(format.sampleRate / 10) : 0
        let feed = SpeechModelFeed(format: format, groupFrames: groupFrames) { buffer, start in
            input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: timescale)))
        }
        let engine = SpeechAnalyzerEngine(analyzer: analyzer, feed: feed, input: input)
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try check()
            engine.listen(to: transcriber, onResult: onResult, onEnd: onEnd)
            try await analyzer.start(inputSequence: stream)
            try check()
            if let end = engine.resultsEnd { throw end }
        } catch {
            await engine.stop().value
            throw error
        }
        return engine
    }

    /// Passes each result on. When the results end, `onEnd` gets the error,
    /// or nil when they ended without one. Nothing is passed after `stop`.
    @MainActor
    private func listen(to transcriber: SpeechTranscriber,
                        onResult: @escaping @MainActor (SpeechModelResult) -> Void,
                        onEnd: @escaping @MainActor (Error?) -> Void) {
        results = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    onResult(SpeechModelResult(result))
                }
                guard !Task.isCancelled else { return }
                self?.resultsEnd = SetupError.stopped
                onEnd(nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.resultsEnd = error
                onEnd(error)
            }
        }
    }

    func stop() -> Task<Void, Never> {
        if let finishing { return finishing }
        feed.finish()
        input.finish()
        results?.cancel()
        results = nil
        let analyzer = self.analyzer
        let task = Task { await analyzer.cancelAndFinishNow() }
        finishing = task
        return task
    }
}

@available(macOS 26.0, *)
extension SpeechModelResult {
    init(_ result: SpeechTranscriber.Result) {
        self.init(text: String(result.text.characters), isFinal: result.isFinal,
                  start: result.range.start.seconds, end: result.range.end.seconds,
                  wordEnds: result.isFinal ? result.text.runs.compactMap { $0.audioTimeRange?.end.seconds } : [])
    }
}
