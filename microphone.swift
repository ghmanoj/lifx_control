import AVFoundation
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct MusicEnvelope {
    var calibration: [Double] = []
    var threshold: Double? = nil
    var active = false
    var attack = 0
    var quiet = 0
    var smoothed = 0.0

    // Called at 10 Hz. Ignore the room's noise floor and isolated clicks.
    mutating func update(rms: Double) -> UInt16? {
        let db = 20 * log10(max(rms, 0.000001))
        guard let gate = threshold else {
            calibration.append(db)
            if calibration.count == 20 {
                let sorted = calibration.sorted()
                threshold = max(-42, sorted[15] + 18)
            }
            return nil
        }
        if !active {
            attack = db > gate ? attack + 1 : 0
            if attack >= 4 { active = true; quiet = 0 }
        } else {
            quiet = db < gate - 4 ? quiet + 1 : 0
            if quiet >= 3 { active = false; attack = 0 }
        }
        let normalized = active ? min(1, max(0, (db - (gate - 4)) / 20)) : 0
        // Keep softer passages dim while louder passages reach full brightness.
        let level = normalized * normalized
        let delta = (level > smoothed ? 0.40 : 0.25) * (level - smoothed)
        // Limit each update to about 6% brighter or 4% dimmer.
        smoothed += min(0.06, max(-0.04, delta))
        if !active && smoothed < 0.005 { smoothed = 0 }
        return UInt16(((0.02 + 0.98 * smoothed) * 65535).rounded())
    }
}

if CommandLine.arguments.contains("--self-test") {
    func rms(_ db: Double) -> Double { pow(10, db / 20) }
    var envelope = MusicEnvelope()
    for _ in 0..<20 { precondition(envelope.update(rms: rms(-55)) == nil) }
    let idle = UInt16((0.02 * 65535).rounded())
    for db in [-57.0, -53, -51, -49, -54, -52, -45, -40, -39] {
        precondition(envelope.update(rms: rms(db)) == idle)
    }
    // A single loud click does not activate the light.
    precondition(envelope.update(rms: rms(-20)) == idle)
    precondition(envelope.update(rms: rms(-55)) == idle)
    var previous = idle
    for _ in 0..<60 {
        let value = envelope.update(rms: rms(-20))!
        precondition(abs(Int(value) - Int(previous)) <= 3854)
        previous = value
    }
    precondition(envelope.active && envelope.smoothed > 0.9)
    for _ in 0..<100 {
        let value = envelope.update(rms: rms(-55))!
        precondition(abs(Int(value) - Int(previous)) <= 3854)
        previous = value
    }
    precondition(!envelope.active)
    precondition(envelope.update(rms: rms(-55)) == idle)
    // Soft sustained sound stays dim; louder sound has strong contrast.
    for _ in 0..<60 { _ = envelope.update(rms: rms(-34)) }
    let soft = envelope.update(rms: rms(-34))!
    precondition(soft < UInt16(0.20 * 65535))
    for _ in 0..<60 { _ = envelope.update(rms: rms(-20)) }
    let loud = envelope.update(rms: rms(-20))!
    precondition(loud > UInt16(0.90 * 65535))
    // A louder room calibrates to a higher threshold.
    var noisyRoom = MusicEnvelope()
    for _ in 0..<20 { _ = noisyRoom.update(rms: rms(-38)) }
    for db in [-39.0, -35, -33, -37] {
        precondition(noisyRoom.update(rms: rms(db)) == idle)
    }
    print("Noise gate tests passed")
    exit(0)
}

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: break
case .notDetermined:
    let permission = DispatchSemaphore(value: 0)
    var allowed = false
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        allowed = granted
        permission.signal()
    }
    permission.wait()
    if !allowed { fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.") }
default:
    fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
}

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else {
    fail("No microphone available. Select MacBook Microphone in System Settings > Sound > Input.")
}

// Only the latest RMS level is shared; audio is never stored or transmitted.
let lock = NSLock()
var latestRMS: Double? = nil
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    var sum = 0.0
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Double(channels[channel][frame])
            sum += sample * sample
        }
    }
    let rms = sqrt(sum / Double(Int(buffer.frameLength) * Int(buffer.format.channelCount)))
    lock.lock()
    latestRMS = rms
    lock.unlock()
}
do { try engine.start() } catch { fail("Unable to start microphone: \(error.localizedDescription)") }

FileHandle.standardError.write(Data("Calibrating room noise for two seconds. Keep music paused until ready.\n".utf8))
var envelope = MusicEnvelope()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(100))
timer.setEventHandler {
    lock.lock()
    let rms = latestRMS
    lock.unlock()
    guard let rms = rms else { return }
    let wasCalibrating = envelope.threshold == nil
    let value = envelope.update(rms: rms)
    if wasCalibrating, let threshold = envelope.threshold {
        FileHandle.standardError.write(Data(String(format: "Ready. Play music now (noise gate: %.1f dBFS).\n", threshold).utf8))
    }
    guard let value = value else { return }
    var brightness = value.littleEndian
    let result = withUnsafeBytes(of: &brightness) { bytes in
        Darwin.write(STDOUT_FILENO, bytes.baseAddress!, bytes.count)
    }
    if result != 2 { engine.stop(); exit(1) }
}
timer.resume()
RunLoop.main.run()
