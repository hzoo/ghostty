enum MIDIScale: String {
    case pentatonic, major, minor, chromatic, blues

    var intervals: [UInt8] {
        switch self {
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .major:      return [0, 2, 4, 5, 7, 9, 11]
        case .minor:      return [0, 2, 3, 5, 7, 8, 10]
        case .chromatic:  return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        case .blues:      return [0, 3, 5, 6, 7, 10]
        }
    }
}
