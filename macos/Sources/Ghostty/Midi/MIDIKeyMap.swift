struct MIDIKeyMap {
    static let defaultRootKeyCode: UInt16 = 6
    private let baseNote: UInt8 = 48  // C3
    private let intervals: [UInt8]

    init(scale: MIDIScale) {
        self.intervals = scale.intervals
    }

    // macOS hardware keycodes -> (row, col) physical position
    // Row 0 = ZXCV (C3), Row 1 = ASDF (C4), Row 2 = QWER (C5), Row 3 = 1234 (C6)
    //
    // Columns wrap through the scale with octave offsets, so a 10-key row
    // in pentatonic gives two octaves (C D E G A | C' D' E' G' A').
    private static let keyCodeToPosition: [UInt16: (row: Int, col: Int)] = [
        // Row 0: Z X C V B N M , . /
        6: (0, 0), 7: (0, 1), 8: (0, 2), 9: (0, 3), 11: (0, 4),
        45: (0, 5), 46: (0, 6), 43: (0, 7), 47: (0, 8), 44: (0, 9),
        // Row 1: A S D F G H J K L ; '
        0: (1, 0), 1: (1, 1), 2: (1, 2), 3: (1, 3), 5: (1, 4),
        4: (1, 5), 38: (1, 6), 40: (1, 7), 37: (1, 8), 41: (1, 9), 39: (1, 10),
        // Row 2: Q W E R T Y U I O P [ ] backslash
        12: (2, 0), 13: (2, 1), 14: (2, 2), 15: (2, 3), 17: (2, 4),
        16: (2, 5), 32: (2, 6), 34: (2, 7), 31: (2, 8), 35: (2, 9),
        33: (2, 10), 30: (2, 11), 42: (2, 12),
        // Row 3: 1 2 3 4 5 6 7 8 9 0 - =
        18: (3, 0), 19: (3, 1), 20: (3, 2), 21: (3, 3), 23: (3, 4),
        22: (3, 5), 26: (3, 6), 28: (3, 7), 25: (3, 8), 29: (3, 9),
        27: (3, 10), 24: (3, 11),
    ]

    private func position(forKeyCode keyCode: UInt16) -> (row: Int, col: Int)? {
        return Self.keyCodeToPosition[keyCode]
    }

    func midiNote(forKeyCode keyCode: UInt16) -> UInt8? {
        guard let pos = position(forKeyCode: keyCode) else { return nil }
        let octave = pos.col / intervals.count
        let scaleIndex = pos.col % intervals.count
        let note = Int(baseNote) + (pos.row * 12) + (octave * 12) + Int(intervals[scaleIndex])
        guard note >= 0 && note <= 127 else { return nil }
        return UInt8(note)
    }

    var defaultRootNote: UInt8 {
        midiNote(forKeyCode: Self.defaultRootKeyCode) ?? baseNote
    }
}
