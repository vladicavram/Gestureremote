import Foundation

/// Gestures the app can recognise and map to Apple TV commands.
enum Gesture: Hashable {
    case none
    case swipeUp
    case swipeDown
    case swipeLeft
    case swipeRight
    case select        // thumbs up → OK/Select
    case back          // thumbs down → go back
    case menu          // palm→fist → menu
    case playPause     // thumbs up → play / pause

    var displayName: String {
        switch self {
        case .none:       return "–"
        case .swipeUp:    return "Up"
        case .swipeDown:  return "Down"
        case .swipeLeft:  return "Left"
        case .swipeRight: return "Right"
        case .select:     return "Select"
        case .back:       return "Back"
        case .menu:       return "Menu"
        case .playPause:  return "Play / Pause"
        }
    }

    var iconName: String {
        switch self {
        case .none:       return "hand.raised.slash"
        case .swipeUp:    return "arrow.up.circle.fill"
        case .swipeDown:  return "arrow.down.circle.fill"
        case .swipeLeft:  return "arrow.left.circle.fill"
        case .swipeRight: return "arrow.right.circle.fill"
        case .select:     return "checkmark.circle.fill"
        case .back:       return "arrow.uturn.backward.circle.fill"
        case .menu:       return "list.bullet.circle.fill"
        case .playPause:  return "playpause.fill"
        }
    }
}
