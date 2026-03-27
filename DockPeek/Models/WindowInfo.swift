import AppKit

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let isOnScreen: Bool
    let isMinimized: Bool
    var thumbnail: NSImage?

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.bounds == rhs.bounds
            && lhs.ownerPID == rhs.ownerPID
            && lhs.isOnScreen == rhs.isOnScreen
            && lhs.isMinimized == rhs.isMinimized
            && lhs.thumbnail === rhs.thumbnail
    }
}
