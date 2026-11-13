# ioStart for iPhone and iPad

**ioStart**, the iPhone and iPad app for the bookmarks of the
[ioStart start page](https://github.com/avandeputte/iosuite/tree/main/iostart).

## ioStart

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

## How it talks to the start page

The same way the browser extension does (in the iosuite repo: `app/bookmarkext.py`, `/dav/ext`): the tree in one request, changes as ops in
one request, HTTP Basic with a sync-only app password. Signing in is the start page's own "may this app sync?" page
(`app/ncbookmarks.py`, Nextcloud's login flow v2) in the system's sign-in sheet: nobody types a password into the app,
and the app password it gets is kept in the Shared ioSuite database, listed and revoked like every other one
(Settings › Account). It lives in the phone's keychain, in the app group the app shares with its share extension.

Behind Cloudflare Access nothing more is needed than what the extension needs: `/dav` bypasses Access and the Worker
checks the app password. The sign-in sheet goes through Access like a browser does.

The start page must be version 0.47.0 or later (the sign-in page that works in one tab, and `/dav/ext/icon`).

## Build

Needs a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

    brew install xcodegen
    xcodegen                      # makes ioStart.xcodeproj from project.yml
    open ioStart.xcodeproj    # pick your iPhone, Run

`project.yml` names the team (`DEVELOPMENT_TEAM`) and the ids: `net.iothing.iostart`, its share extension
`net.iothing.iostart.share`, and the app group `group.net.iothing.iostart` both are in. Signing is automatic:
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
