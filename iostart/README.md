# iostart-apps

ioSuite's native apps. For now one: **ioStart**, the iPhone and iPad app for the bookmarks of the
[ioSuite start page](https://github.com/avandeputte/iosuite).

## ioStart

- The whole tree, as the start page has it: folders, links with their sites' icons, search over everything.
- Add, rename, move, reorder (Edit, then drag) and delete; a change here reaches the start page at once, and every
  browser that syncs with it (the ioSuite Bookmarks extension) at its next sync.
- **Share sheet**: in any browser (Vivaldi, Safari, Chrome…) tap Share › ioStart to bookmark the page, with a
  folder picker that remembers the last folder. The first time, the app has to be turned on under *More* at the end
  of the share sheet's row of apps.
- **Built-in browser**: a bookmark opens inside the app (WebKit), or in the phone's default browser: Settings ›
  Open bookmarks. Press and hold a bookmark for the other way, and to copy or share its address.

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

## Layout

    project.yml        the project, for XcodeGen
    Shared/            in the app and the extension: the API, the account (keychain), the tree, the folder picker
    iOS/               the app: sign-in, folders, editor, built-in browser, settings
    ShareExtension/    Share › ioStart
    .github/workflows/ a check that it still builds, on every pull request (unsigned, for the simulator)
