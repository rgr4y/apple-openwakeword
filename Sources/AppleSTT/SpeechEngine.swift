// Apple on-device Speech Recognition engine.
//
// Two backends, selected at runtime:
//   • SpeechAnalyzerEngine  — macOS 26+   (SpeechAnalyzer / SpeechTranscriber)
//   • SFSpeechEngine        — macOS 13-25 (SFSpeechRecognizer, on-device mode)
//
// Both conform to SpeechEngineProtocol so the rest of the daemon is backend-agnostic.

import AVFoundation
import Foundation
import Speech

// MARK: - Protocol

protocol SpeechEngineProtocol: AnyObject {
    /// Returns false if the required speech locale is not installed.
    func checkAvailability() async -> Bool

    /// Feed a chunk of 16 kHz mono Float32 samples.
    func feedSamples(_ samples: [Float])

    /// Signal end of the utterance. The engine will call onFinalTranscript
    /// with the accumulated text and then reset for the next utterance.
    func finishUtterance()

    /// Called on every partial result during transcription.
    var onPartialTranscript: ((String) -> Void)? { get set }
    /// Called with the final transcript when the utterance ends.
    var onFinalTranscript: ((String) -> Void)? { get set }
    /// Called if an unrecoverable error occurs.
    var onError: ((Error) -> Void)? { get set }

    func stop()
}

// MARK: - Factory

func makeSpeechEngine(language: String) -> SpeechEngineProtocol {
    if #available(macOS 26.0, *) {
        return SpeechAnalyzerEngine(language: language)
    } else {
        return SFSpeechEngine(language: language)
    }
}

// MARK: - SpeechAnalyzer backend (macOS 26+)

@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: SpeechEngineProtocol {
    var onPartialTranscript: ((String) -> Void)?
    var onFinalTranscript:   ((String) -> Void)?
    var onError:             ((Error) -> Void)?

    private let language: String
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Never>?
    // Accessible from finishUtterance() without relying on the hung task
    private var lastPartialText: String = ""
    private var accumulatedText: String = ""
    private var finalFired = false

    init(language: String) {
        self.language = language
    }

    func checkAvailability() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return resolveLocale(installed: installed) != nil
    }

    func feedSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if continuation == nil {
            startAnalyzerSession()
        }
        guard let buf = makePCMBuffer(samples) else { return }
        continuation?.yield(AnalyzerInput(buffer: buf))
    }

    func finishUtterance() {
        log("SpeechAnalyzer: finishUtterance — lastPartial=\"\(lastPartialText)\" accumulated=\"\(accumulatedText)\"", debug: true)
        // Close input stream
        continuation?.finish()
        continuation = nil

        // Don't wait for the task — it may hang indefinitely on transcriber.results.
        // Fire the final callback immediately with whatever we have, then cancel.
        if !finalFired {
            finalFired = true
            let text = accumulatedText.isEmpty ? lastPartialText : accumulatedText
            log("SpeechAnalyzer: firing onFinalTranscript(\"\(text)\") from finishUtterance", debug: true)
            onFinalTranscript?(text)
        }

        analyzerTask?.cancel()
        analyzerTask = nil
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        lastPartialText = ""
        accumulatedText = ""
        finalFired = false
    }

    // MARK: - Private

    private func startAnalyzerSession() {
        lastPartialText = ""
        accumulatedText = ""
        finalFired = false
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont

        let lang = language
        let onPartial = onPartialTranscript
        let onError = onError

        analyzerTask = Task { [weak self] in
            log("SpeechAnalyzer task: started", debug: true)
            let installed = await SpeechTranscriber.installedLocales
            guard let locale = self?.resolveLocale(installed: installed) else {
                onError?(SpeechEngineError.noInstalledLocale(lang))
                return
            }
            log("SpeechAnalyzer task: locale=\(locale.identifier)", debug: true)

            do {
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    preset: .progressiveTranscription
                )
                let analyzer = SpeechAnalyzer(modules: [transcriber])

                let sourceFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )!
                let inputStream: AsyncStream<AnalyzerInput>
                if let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber]),
                   targetFormat != sourceFormat,
                   let converted = makeConvertedStream(stream, from: sourceFormat, to: targetFormat) {
                    log("SpeechAnalyzer task: resampling \(sourceFormat.sampleRate)Hz → \(targetFormat.sampleRate)Hz", debug: true)
                    inputStream = converted
                } else {
                    inputStream = stream
                }

                log("SpeechAnalyzer task: calling analyzer.start()", debug: true)
                try await analyzer.start(inputSequence: inputStream)
                log("SpeechAnalyzer task: analyzer.start() returned — iterating results", debug: true)

                for try await result in transcriber.results {
                    guard !Task.isCancelled else {
                        log("SpeechAnalyzer task: cancelled during results iteration", debug: true)
                        break
                    }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    log("SpeechAnalyzer task: result isFinal=\(result.isFinal) text=\"\(text)\"", debug: true)
                    if result.isFinal {
                        if !text.isEmpty {
                            if let s = self, !s.accumulatedText.isEmpty { self?.accumulatedText += " " }
                            self?.accumulatedText += text
                        }
                        onPartial?(self?.accumulatedText ?? text)
                    } else {
                        if !text.isEmpty { self?.lastPartialText = text }
                        let preview = (self?.accumulatedText ?? "").isEmpty ? text : "\((self?.accumulatedText)!) \(text)"
                        onPartial?(preview)
                    }
                }

                log("SpeechAnalyzer task: results sequence ended", debug: true)
                // Task completed naturally (rare) — fire final if finishUtterance didn't already
                if let s = self, !s.finalFired {
                    s.finalFired = true
                    let finalText = s.accumulatedText.isEmpty ? s.lastPartialText : s.accumulatedText
                    log("SpeechAnalyzer task: firing onFinalTranscript(\"\(finalText)\") from task end", debug: true)
                    s.onFinalTranscript?(finalText)
                }
            } catch {
                if (error as NSError).code == NSUserCancelledError || Task.isCancelled {
                    log("SpeechAnalyzer task: cancelled", debug: true)
                } else {
                    log("SpeechAnalyzer task: error — \(error)")
                    onError?(error)
                }
            }
        }
    }

    private func resolveLocale(installed: [Locale]) -> Locale? {
        let installedIDs = installed.map { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() }
        guard !installedIDs.isEmpty else { return nil }

        let configured = language.replacingOccurrences(of: "_", with: "-").lowercased()

        // Build a priority-ordered list of candidate identifiers to try, mirroring george's logic:
        // 1. Exact configured language (e.g. "en-us")
        // 2. System current locale if it shares the language prefix (e.g. current=en-AU when lang=en)
        // 3. OS preferred languages that share the prefix
        // 4. For bare "en", hardcode "en-us" as the last fallback before giving up
        var candidates: [String] = [configured]

        let langCode = String(configured.split(separator: "-").first ?? Substring(configured))
        let prefix = langCode + "-"

        let currentID = Locale.current.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if currentID.hasPrefix(prefix) { candidates.append(currentID) }

        for pref in Locale.preferredLanguages {
            let n = pref.replacingOccurrences(of: "_", with: "-").lowercased()
            if n.hasPrefix(prefix) { candidates.append(n) }
        }

        if langCode == "en" { candidates.append("en-us") }

        // Deduplicate while preserving order
        var seen = Set<String>()
        let orderedCandidates = candidates.filter { seen.insert($0).inserted }

        // First try exact candidate matches
        for candidate in orderedCandidates {
            if installedIDs.contains(candidate) {
                return installed[installedIDs.firstIndex(of: candidate)!]
            }
        }

        // Fall back to any installed locale sharing the language prefix, preferring en-us for English
        let prefixMatches = zip(installedIDs, installed).filter { $0.0.hasPrefix(prefix) || $0.0 == langCode }
        if langCode == "en", let usMatch = prefixMatches.first(where: { $0.0 == "en-us" }) {
            return usMatch.1
        }
        return prefixMatches.first?.1
    }

    private func makePCMBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buf.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }
        return buf
    }

    private func makeConvertedStream(
        _ source: AsyncStream<AnalyzerInput>,
        from srcFormat: AVAudioFormat,
        to dstFormat: AVAudioFormat
    ) -> AsyncStream<AnalyzerInput>? {
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }
        return AsyncStream { continuation in
            Task {
                for await input in source {
                    let capacity = AVAudioFrameCount(
                        Double(input.buffer.frameLength) * dstFormat.sampleRate / srcFormat.sampleRate
                    )
                    guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat,
                                                     frameCapacity: capacity) else { continue }
                    var err: NSError?
                    converter.convert(to: out, error: &err) { _, status in
                        status.pointee = .haveData
                        return input.buffer
                    }
                    if err == nil { continuation.yield(AnalyzerInput(buffer: out)) }
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - SFSpeechRecognizer backend (macOS 13-25)

final class SFSpeechEngine: SpeechEngineProtocol {
    var onPartialTranscript: ((String) -> Void)?
    var onFinalTranscript:   ((String) -> Void)?
    var onError:             ((Error) -> Void)?

    private let language: String
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var bestTranscript: String = ""

    init(language: String) {
        self.language = language
        let locale = Locale(identifier: language)
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    func checkAvailability() async -> Bool {
        guard let recognizer else { return false }
        guard recognizer.isAvailable else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func feedSamples(_ samples: [Float]) {
        if request == nil { startSession() }
        guard let req = request, !samples.isEmpty else { return }
        guard let buf = makePCMBuffer(samples) else { return }
        req.append(buf)
    }

    func finishUtterance() {
        request?.endAudio()
        // task will deliver final result via callback
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        bestTranscript = ""
    }

    // MARK: - Private

    private func startSession() {
        guard let recognizer else {
            onError?(SpeechEngineError.noInstalledLocale(language))
            return
        }

        bestTranscript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req

        let onPartial = onPartialTranscript
        let onFinal = onFinalTranscript
        let onError = onError

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.bestTranscript = text
                if result.isFinal {
                    onFinal?(text)
                    // Reset so continuous speech auto-starts the next segment
                    self?.request = nil
                    self?.task = nil
                } else {
                    onPartial?(text)
                }
            }
            if let error {
                // NSError 301 = cancelled, not a real error
                let nsErr = error as NSError
                if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 301 { return }
                // Code 1110 = no speech detected — not fatal, just reset quietly
                if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 1110 {
                    self?.request = nil
                    self?.task = nil
                    return
                }
                onError?(error)
                self?.request = nil
                self?.task = nil
            }
        }
    }

    private func makePCMBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buf.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }
        return buf
    }
}

// MARK: - Errors

enum SpeechEngineError: Error, CustomStringConvertible {
    case noInstalledLocale(String)
    case engineUnavailable

    var description: String {
        switch self {
        case .noInstalledLocale(let lang):
            return "No installed speech locale for language '\(lang)'"
        case .engineUnavailable:
            return "Speech recognition engine unavailable"
        }
    }
}
