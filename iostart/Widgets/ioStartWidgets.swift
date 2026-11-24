import SwiftUI
import WidgetKit

/// ioStart's widgets: Today, Next event and Bookmarks.
@main
struct ioStartWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        NextEventWidget()
        BookmarksWidget()
    }
}
