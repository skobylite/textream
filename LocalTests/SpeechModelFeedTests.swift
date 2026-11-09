// include: Textream/Textream/SpeechAnalyzerEngine.swift
// Tests for the audio feed of the macOS 26 engine (SpeechModelFeed): tap
// buffers become model buffers, and each start time follows the frames sent
// before it, also after a microphone with another format.
import Foundation
import AVFoundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

let model = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
func tapFormat(_ rate: Double) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
}
/// A tap buffer with a 440 Hz tone.
func tone(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    b.frameLength = frames
    for i in 0..<Int(frames) { b.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(format.sampleRate)) }
    return b
}

final class Sink: @unchecked Sendable {
    var sent: [(frames: Int, start: Int64, format: AVAudioFormat)] = []
}

// 48 kHz tap buffers of 1200 frames (the tap size), no grouping.
var sink = Sink()
var feed = SpeechModelFeed(format: model, groupFrames: 0) { [sink] b, start in
    sink.sent.append((Int(b.frameLength), start, b.format))
}
for _ in 0..<40 { feed.append(tone(tapFormat(48000), frames: 1200)) }
let total = sink.sent.reduce(0) { $0 + $1.frames }
check("each tap buffer gives one model buffer", sink.sent.count == 40)
check("the buffers are in the model format", sink.sent.allSatisfy { $0.format == model })
check("1200 frames at 48 kHz give about 400 frames at 16 kHz",
      sink.sent.allSatisfy { abs($0.frames - 400) <= 2 } && abs(total - 16000) <= 20)
var running: Int64 = 0
var rising = true
for s in sink.sent {
    if s.start != running { rising = false }
    running += Int64(s.frames)
}
check("each start time is the count of frames sent before it", rising)
check("the feed reports the input sizes", abs(feed.inputFrames.min - 400) <= 2 && abs(feed.inputFrames.max - 400) <= 2)

// Another microphone: 44.1 kHz buffers. A new converter, and the start times go on rising.
let before = sink.sent.count
for _ in 0..<10 { feed.append(tone(tapFormat(44100), frames: 1103)) }
let after = Array(sink.sent[before...])
check("a new tap format still gives model buffers", after.count == 10 && after.allSatisfy { $0.format == model })
check("1103 frames at 44.1 kHz give about 400 frames", after.allSatisfy { abs($0.frames - 400) <= 2 })
check("the start times do not go back after the format change", after.first?.start == running)

// finish: later buffers go nowhere.
feed.finish()
feed.append(tone(tapFormat(48000), frames: 1200))
check("no buffer is sent after finish", sink.sent.count == before + 10)

// 100 ms grouping.
sink = Sink()
feed = SpeechModelFeed(format: model, groupFrames: 1600) { [sink] b, start in
    sink.sent.append((Int(b.frameLength), start, b.format))
}
for _ in 0..<40 { feed.append(tone(tapFormat(48000), frames: 1200)) }
check("grouped buffers hold at least 100 ms", !sink.sent.isEmpty && sink.sent.allSatisfy { $0.frames >= 1600 })
check("grouped buffers are about 4 tap buffers", sink.sent.allSatisfy { $0.frames <= 1610 })
running = 0
rising = true
for s in sink.sent {
    if s.start != running { rising = false }
    running += Int64(s.frames)
}
check("grouped start times follow the frames sent", rising)
check("grouping keeps the audio: 10 groups from 40 buffers", sink.sent.count == 10)

print(fails == 0 ? "all pass" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
