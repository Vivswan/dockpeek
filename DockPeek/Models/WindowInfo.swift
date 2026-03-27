import AppKit

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let isOnScreen: Bool
    let isMinimized: Bool
    let isOnOtherSpace: Bool
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
            && lhs.isOnOtherSpace == rhs.isOnOtherSpace
            // Identity (===) comparison is intentional: a new capture produces a new
            // NSImage object, so SwiftUI sees it as changed and re-renders the thumbnail.
            // Pixel-level equality would be too expensive for diffing.
            && lhs.thumbnail === rhs.thumbnail
    }
}
