import AppKit
import AVFoundation
import CoreMIDI
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "midi")

/// Converts MIDI note number to frequency in Hz.
private func noteToFreq(_ note: UInt8) -> Float {
    440.0 * powf(2.0, (Float(note) - 69.0) / 12.0)
}

// MARK: - Tone Synthesizer

/// Minimal additive synth that plays tones directly through speakers.
/// Each voice is a decaying sine — percussive, pleasant, zero configuration.
private class ToneSynth {
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 44100
    private let maxVoices = 8

    // Ring buffer of active voices
    private struct Voice {
        var freq: Float = 0
        var phase: Float = 0
        var amplitude: Float = 0
        var decay: Float = 0      // amplitude multiplier per sample
        var active: Bool = false
    }

    private var voices: [Voice]
    private let lock = NSLock()

    init() {
        voices = [Voice](repeating: Voice(), count: maxVoices)
    }

    func start() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let srcNode = AVAudioSourceNode { [weak self] _, _, frameCount, bufferList -> OSStatus in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            let buf = ablPointer[0]
            let frames = Int(frameCount)
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            self.lock.lock()
            // Zero the buffer
            for i in 0..<frames { data[i] = 0 }

            for v in 0..<self.voices.count where self.voices[v].active {
                let phaseInc = self.voices[v].freq / Float(self.sampleRate)
                for i in 0..<frames {
                    let p = self.voices[v].phase * 2.0 * .pi
                    // Fundamental + soft harmonics for warmth
                    let sample = (sinf(p) + 0.3 * sinf(p * 2) + 0.1 * sinf(p * 3))
                        * self.voices[v].amplitude * 0.7
                    data[i] += sample
                    self.voices[v].phase += phaseInc
                    if self.voices[v].phase > 1.0 { self.voices[v].phase -= 1.0 }
                    self.voices[v].amplitude *= self.voices[v].decay
                }
                if self.voices[v].amplitude < 0.001 {
                    self.voices[v].active = false
                }
            }
            self.lock.unlock()

            return noErr
        }

        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5

        do {
            try engine.start()
            logger.info("ToneSynth audio engine started")
        } catch {
            logger.error("ToneSynth failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
    }

    /// Trigger a note with the given frequency and velocity (0-127).
    /// Duration is controlled by decay — roughly 80ms of audible tone.
    func play(freq: Float, velocity: UInt8) {
        let amp = Float(velocity) / 127.0 * 0.3  // keep it gentle
        // Decay to ~0.001 in ~80ms at 44100Hz ≈ 3528 samples
        // 0.001 = amp * decay^3528  →  decay = (0.001/amp)^(1/3528)
        let targetSamples: Float = 3528
        let decay = powf(0.001 / amp, 1.0 / targetSamples)

        lock.lock()
        // Find a free voice, or steal the quietest
        var idx = 0
        var minAmp: Float = .greatestFiniteMagnitude
        for i in 0..<voices.count {
            if !voices[i].active { idx = i; break }
            if voices[i].amplitude < minAmp {
                minAmp = voices[i].amplitude
                idx = i
            }
        }
        voices[idx] = Voice(freq: freq, phase: 0, amplitude: amp, decay: decay, active: true)
        lock.unlock()
    }

    /// Kill all voices immediately.
    func allOff() {
        lock.lock()
        for i in 0..<voices.count { voices[i].active = false }
        lock.unlock()
    }
}

// MARK: - GlossaliaMIDI

final class GlossaliaMIDI {
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private let keyMap: MIDIKeyMap
    private let synth = ToneSynth()

    init(scale: MIDIScale = .pentatonic) {
        self.keyMap = MIDIKeyMap(scale: scale)
    }

    func start() {
        if client != 0 || source != 0 {
            return
        }

        // Start built-in audio synth (always — this is what you hear)
        synth.start()

        // Also create CoreMIDI virtual source for DAW/external synth use
        let status = MIDIClientCreate("Glossolalia" as CFString, nil, nil, &client)
        guard status == noErr else {
            logger.error("MIDI client create failed: \(status)")
            return
        }
        let srcStatus = MIDISourceCreate(client, "Glossolalia" as CFString, &source)
        if srcStatus == noErr {
            logger.info("MIDI source 'Glossolalia' created (endpoint \(self.source))")
        } else {
            logger.error("MIDI source create failed: \(srcStatus)")
        }
    }

    func stop() {
        synth.allOff()
        synth.stop()

        if source != 0 {
            sendCC(controller: 123, value: 0, channel: 0)
            MIDIEndpointDispose(source)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }

        client = 0
        source = 0
    }

    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let command = modifiers.contains(.command)
        let velocity: UInt8 = shift ? 127 : 70

        switch keyCode {
        case 49: // Space — rest
            return
        case 36: // Return — power chord (root + fifth)
            let root = keyMap.defaultRootNote
            playNote(root, velocity: 127, duration: 0.12)
            playNote(root + 7, velocity: 127, duration: 0.12)
            return
        case 51: // Delete — pitch bend down
            sendPitchBend(value: 0, channel: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendPitchBend(value: 8192, channel: 0)
            }
            return
        case 48: // Tab — 3-note arpeggio
            let root = keyMap.defaultRootNote
            for (i, interval): (Int, UInt8) in [(0, 0), (1, 4), (2, 7)] {
                let note = root + interval
                let delay = Double(i) * 0.04
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.playNote(note, velocity: velocity, duration: 0.1)
                }
            }
            return
        case 53: // Escape — all notes off
            synth.allOff()
            sendCC(controller: 123, value: 0, channel: 0)
            return
        default:
            break
        }

        guard let note = keyMap.midiNote(forKeyCode: keyCode) else { return }

        // Modifier chord voicing:
        //   plain     = single note
        //   option    = power chord (root + fifth)
        //   command   = octave doubling (root + octave)
        //   opt+shift = full triad (root + third + fifth)
        let duration: TimeInterval = shift ? 0.15 : 0.08
        playNote(note, velocity: velocity, duration: duration)

        if option && shift {
            // Full triad
            playNote(note + 4, velocity: loweredVelocity(velocity, by: 10), duration: duration)
            playNote(note + 7, velocity: loweredVelocity(velocity, by: 15), duration: duration)
        } else if option {
            // Power chord — fifth above
            playNote(note + 7, velocity: loweredVelocity(velocity, by: 10), duration: duration)
        } else if command {
            // Octave doubling
            playNote(note + 12, velocity: loweredVelocity(velocity, by: 20), duration: duration)
        }
    }

    // MARK: - Private

    /// Play a note through both the built-in synth and MIDI output.
    private func playNote(_ note: UInt8, velocity: UInt8, duration: TimeInterval) {
        guard note <= 127 else { return }
        synth.play(freq: noteToFreq(note), velocity: velocity)
        sendNoteOn(note: note, velocity: velocity, channel: 0)
        scheduleNoteOff(note: note, delay: duration)
    }

    private func scheduleNoteOff(note: UInt8, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendNoteOff(note: note, channel: 0)
        }
    }

    private func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        send(bytes: [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F])
    }

    private func sendNoteOff(note: UInt8, channel: UInt8) {
        send(bytes: [0x80 | (channel & 0x0F), note & 0x7F, 0])
    }

    private func sendPitchBend(value: UInt16, channel: UInt8) {
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8((value >> 7) & 0x7F)
        send(bytes: [0xE0 | (channel & 0x0F), lsb, msb])
    }

    private func sendCC(controller: UInt8, value: UInt8, channel: UInt8) {
        send(bytes: [0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F])
    }

    private func loweredVelocity(_ velocity: UInt8, by amount: UInt8) -> UInt8 {
        let delta = velocity.saturatingSubtraction(amount)
        return max(delta, 1)
    }

    private func send(bytes: [UInt8]) {
        guard source != 0 else { return }
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = UInt16(bytes.count)
        withUnsafeMutableBytes(of: &packet.data) { buf in
            for (i, b) in bytes.enumerated() where i < buf.count {
                buf[i] = b
            }
        }
        var packetList = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(source, &packetList)
    }
}

private extension UInt8 {
    func saturatingSubtraction(_ value: UInt8) -> UInt8 {
        self > value ? self - value : 0
    }
}
