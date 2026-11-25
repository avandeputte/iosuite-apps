# ioStart for iPhone and iPad

**ioStart**, the iPhone and iPad app for the
[ioStart start page](https://github.com/avandeputte/iosuite/tree/main/iostart): your day, your news feeds and the
bookmarks, a tab each. The app opens on the tab it was last on.

## Today

What the start page's Today card lists (`/dav/ext/today`), with what you switched off there (Customize) left out here too:

- Today's events, tasks and birthdays in one list: what is late first, then birthdays, all-day events, then by the hour.
  Under them the coming days, as far as your Today card goes (the week, or the days you chose).
- Tap a task's circle to tick it off in ioTask; tap it again to take that back. A repeating task moves on to its next time.
- The week's bills from ioMoney, with the accounts about to run low and the bank links that are behind.
- A row opens its app (ioCalendar on that day, the task, the person, ioMoney) as bookmarks open: Settings › Open bookmarks.
- With no connection it shows what the start page said last, and says so.

## News

The start page's feed reader (`/api/news…`): the same feeds, and what is read or starred is the same on both.

- All feeds, Starred, then each folder with its feeds and how many articles are unread; the News tab shows the total.
- A list shows Unread or All, the newest first; pull down to have the start page look for new articles; search titles
  and text. Swipe an article right to mark it read or unread, left to star it; the check marks everything read.
- An article opens as the feed has it, in the phone's type and dark mode, and is marked read. The arrows step through the
  list; a link in the text, and Open the page, open as bookmarks do.
- + follows a feed by its address or its site's (the start page finds the feed). Swipe a feed to rename it, move it to
  a folder, take its headlines off the start page, or unfollow it. Importing and exporting OPML stay on the start page.

## Bookmarks

- The whole tree, as the start page has it: folders, links with their sites' icons, search over everything.
- Add, rename, move, reorder (Edit, then drag) and delete; a change here reaches the start page at once, and every
  browser that syncs with it (the ioStart Bookmarks extension) at its next sync.
- **Share sheet**: in any browser (Vivaldi, Safari, Chrome…) tap Share › ioStart to bookmark the page, with a
  folder picker that remembers the last folder. The first time, the app has to be turned on under *More* at the end
  of the share sheet's row of apps.
- **Built-in browser**: a bookmark opens inside the app (WebKit), or in the phone's default browser: Settings ›
  Open bookmarks. Press and hold a bookmark for the other way, a private page, and to copy or share its address.
  The globe in the bookmark list opens a new page (press and hold it for a private one).
  - Address bar: tap the page's name; the whole address is selected, so typing replaces it. Type an address or words
    to search for (Google, DuckDuckGo, Bing, Startpage, Ecosia or Kagi: Settings › Search with). The bookmarks that
    match show while you type. Bare names get https://, machines at home (`localhost`, an IP address, names ending in
    .local, .lan, .home, .internal or .home.arpa) http://; "3.14" or an email address are searched for.
  - Back and forward (press and hold either for the pages before or after, or swipe from the edge), reload or pull
    down to reload, share, bookmark this page, and under ⋯ Find on page, Copy address, Open in my browser, new pages
    and private ones.
  - A page's own dialogs (alert, confirm, prompt) show; a page that does not open says why, with Try again; a page
    whose process iOS stopped loads again. Sound and video stop when you tap Done.
  - Sites see a mobile Safari user agent, so they serve their full mobile pages.
  - Settings › Clear browsing data forgets the sign-ins, cookies and caches of normal pages.
- **Private pages**: nothing of them is kept, no history, cookies, sign-ins or cache: they live in memory and are gone
  when the page closes, and they share nothing with normal pages. Dark bars and the crossed-out eye next to the
  address show which is which.

## Widgets and Siri

- **Widgets** (iOS 17 and later), from what the start page reads in ioCalendar and ioTask (`/dav/ext/today`):
  - *Today* (small, medium, large, and the lock screen's rectangular one): what is left of today's events, with
    their time and calendar colour, or the next one when the day is done; medium and large add the tasks due today,
    with how many are late.
  - *Next event* (small, and the lock screen's rectangular, inline and round ones).
  - *Bookmarks* (small: 4, medium: 8): pick them under Edit Widget; each opens in the built-in browser.
  
  They refresh about every 20 minutes, when an event ends, and whenever the app comes to the front. Tapping an event
  opens its day in ioCalendar, a task opens in ioTask (through the app: `iostart://open?url=`, `iostart://open?id=`
  for a bookmark). Without the start page they show its last answer, with a crossed-out cloud.
- **Siri and Shortcuts**, no setup needed: "Add a task in ioStart" (title, due date, list), "Add an event in
  ioStart" (title, start, end, all day, calendar), "What's on today in ioStart" (a spoken summary), "Open
  ‹bookmark› in ioStart". The same four are actions in the Shortcuts app.

Both need the start page with `/dav/ext/today`, `/calendars`, `/tasks` and `/events` (iosuite PR #234). The sign-in
gives the phone an app password with full access (scope ""), which they use.

## How it talks to the start page

The same way the browser extension does (in the iosuite repo: `app/bookmarkext.py`, `/dav/ext`): the tree in one
request, changes as ops in one request, `Authorization: Bearer <app password>`. It calls only GET `/dav/ext`,
`/dav/ext/rev`, `/dav/ext/tree`, `/dav/ext/icon/{id}`, `/dav/ext/today`, `/dav/ext/calendars` and POST
`/dav/ext/sync`, `/dav/ext/tasks`, `/dav/ext/events`: what the server's port for devices (8443) serves.

Signing in is the one sign-in of the ioSuite apps (`shared/DeviceSignIn`, see `shared/README.md`): the server's
address for apps, the name and password (and the two-step code when asked), `POST /api/auth/device`. The app password
it gets is listed and removed like every other one (Settings › Account); it lives in the phone's keychain, in the app
group the app shares with its share extension and widgets. Signing out gives it back.

## Build

Needs a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

    brew install xcodegen
    xcodegen                      # makes ioStart.xcodeproj from project.yml
    open ioStart.xcodeproj    # pick your iPhone, Run

`project.yml` names the team (`DEVELOPMENT_TEAM`) and the ids: `net.iothing.iostart`, its share extension
`net.iothing.iostart.share`, its widgets `net.iothing.iostart.widgets`, and the app group `group.net.iothing.iostart` they all are in. Signing is automatic:
Xcode registers the ids and the group with the team on the first build.

## TestFlight

1. The app exists in App Store Connect (bundle id `net.iothing.iostart`).
2. `tools/testflight.sh` archives, signs and uploads it, with the Apple account signed in to Xcode (or an App Store
   Connect API key: `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh`). The build number is the time of the build.
3. In TestFlight, add yourself as an internal tester and install it from Apple's TestFlight app.

## Layout

    project.yml        the project, for XcodeGen
    Shared/            in the app and the extension: the API, the account (keychain), the tree, the folder picker
    iOS/               the app: sign-in, folders, editor, built-in browser, settings
    ShareExtension/    Share › ioStart
    tools/             testflight.sh and its export options
