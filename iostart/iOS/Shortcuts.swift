import AppIntents

/// The actions Siri and Spotlight know without any setup in the Shortcuts app.
struct ioStartShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add a task with \(.applicationName)",
                "New task in \(.applicationName)",
                "Remind me in \(.applicationName)",
            ],
            shortTitle: "Add a task",
            systemImageName: "checklist")
        AppShortcut(
            intent: AddEventIntent(),
            phrases: [
                "Add an event in \(.applicationName)",
                "Add an event with \(.applicationName)",
                "New event in \(.applicationName)",
            ],
            shortTitle: "Add an event",
            systemImageName: "calendar.badge.plus")
        AppShortcut(
            intent: ShowTodayIntent(),
            phrases: [
                "Show today in \(.applicationName)",
                "What's on today in \(.applicationName)",
                "What's my day in \(.applicationName)",
            ],
            shortTitle: "Show today",
            systemImageName: "sun.max")
        AppShortcut(
            intent: OpenBookmarkIntent(),
            phrases: [
                "Open \(\.$bookmark) in \(.applicationName)",
                "Open a bookmark in \(.applicationName)",
            ],
            shortTitle: "Open bookmark",
            systemImageName: "bookmark")
    }
}
