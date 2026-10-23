# iopix for iPhone, Mac and Apple TV

Native companions to [iopix](https://github.com/avandeputte/iopix), the self-hosted photo library.

- **iopix for iPhone**: the iopix web app in a native shell, plus
  - **Send to iopix** in the share sheet (Photos, Files, any app that shares photos or videos),
  - a button to pick photos and videos from the camera roll and send them,
  - the same folder choice as the Mac app (Send to iopix › Folder in iopix), used by the share sheet too,
  - optionally, a list of the new photos and videos in the library each time the app is opened, where you pick
    which ones to send and which to ignore.
- **iopix for Mac**: the iopix web app in its own window (Dock icon, Send Files in the toolbar and the File menu,
  drop photos on the window, downloads go to Downloads), plus a menu bar icon that keeps working with the window
  closed. It
  - watches the Photos library and lists every photo and video added to it from the moment watching is turned on;
    you pick which ones to send and which to ignore (Review… in the menu),
  - takes files and folders dropped on it (or chosen with the button),
  - lets you choose the folder in iopix: by date taken in one of iopix's layouts (2026/202610 by default), a
    pattern of your own such as `Phone/{yyyy}-{mm}`, or one fixed folder such as `Upload`; missing folders are
    created by iopix (patterns and fixed folders need an iopix release that supports them),
  - keeps a queue on disk, so nothing is lost when the Mac sleeps, goes offline or restarts.

- **iopix for Apple TV**: a native viewer (the Apple TV has no web view). Tabs: For You (On this day, Then and
  now, Events and trips, Rediscover), Folders, Albums, People, Places (a map, then places by country), Years,
  Search and Settings. Full-screen photos: ◀ ▶ move, ▲ ▼ or a click show the info panel, holding select adds to
  your favorites, ⏯ runs a slideshow (speed, shuffle, slow pan and zoom, videos: Settings). Ambient mode starts a
  slideshow by itself when the remote is left alone. "Who's watching" switches between family accounts without
  passwords once each has signed in. The Top Shelf shows On this day (or Rediscover) on the home screen; it needs
  the App Group, so a build signed with it (an Apple TV registered to the team). Nothing in the library is changed
  from the TV; favorites are the viewer's own. Same bundle id as the iPhone app.

The apps only send files. iopix does everything else on the server: it puts each file in the library's dated
folders, writes the database rows and sidecars, and skips anything that is already in the library (same
content), so sending a photo twice does no harm.

## How it signs in

The apps sign in exactly like a browser: the iPhone app's web view, or the Mac app's sign-in window, shows the
iopix page (and Cloudflare Access's page first, from outside the home network). The cookies from that sign-in are
then used for uploads. An account needs the editor or admin role to add photos; one-click accounts without a
password only work at home, as in the browser.

Cloudflare Access's sign-in expires after the session length set in Cloudflare. To keep the Mac uploading
unattended, either use the server's home-network address in Settings, or create a Cloudflare **service token**
(Zero Trust › Access › Service auth), allow it in the iopix application's policy (a *Service Auth* rule), and
enter its client ID and secret in the app's settings. They are kept in the Keychain. You still sign in to iopix
once.

## Building

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open iopix.xcodeproj
```

The Xcode project is generated from `project.yml` and not kept in git.

### Signing (once)

1. In Xcode › Settings › Accounts, add your Apple ID.
2. Put your team ID in `project.yml` (`DEVELOPMENT_TEAM`) and run `xcodegen generate` again, or pick the team in
   each target's *Signing & Capabilities* tab.
3. The iPhone app and its share extension share an App Group, `group.net.iothing.iopix`, for the sign-in and the
   queue. Xcode registers it with automatic signing. If the bundle ids `net.iothing.iopix*` are taken on your
   account, change them and the group in `project.yml`, and the group in `Shared/Core/AppConfig.swift`.
4. Run the `iopix` scheme on your iPhone, and `iopixUploader` (it builds iopix.app) on the Mac. The Mac app runs signed for this Mac
   only; turn on *Open at login* in its settings.

## TestFlight

Needs a paid Apple Developer Program membership (the free Personal Team cannot upload).

1. Put the paid team's id in `project.yml` (`DEVELOPMENT_TEAM`).
2. In App Store Connect, create the app (bundle id `net.iothing.iopix`) and an API key with the App Manager role
   (Users and Access › Integrations). Save the `.p8` file as `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8`.
3. `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh` builds, signs and uploads the iPhone app; add `tvos` for the
   Apple TV app. The build number is the build's
   date and time, so every upload counts as newer.
4. In TestFlight, add yourself (and family) as internal testers; they install from Apple's TestFlight app.

## Sharing the Mac app

`tools/release-mac.sh` (same key as TestFlight) signs iopix with your Developer ID, has Apple notarize it and
writes `build/iopix-<version>.dmg`, which opens on any Mac without warnings. A build from Xcode with the free team
only runs on your own Mac.

## Good to know

- The original of each photo is sent, as it came from the camera: edits made in Apple Photos are not, and of a
  Live Photo only the still is sent.
- Photos stored only in iCloud are downloaded first.
- On iPhone, new photos are looked for while the app is open (iOS does not let an app watch the library in the
  background). The share sheet sends while it is open; it says so.
- An ignored photo does not come back. Turning watching off and on again later lists what was added in between.
  *Also list the last 7 days* lists the recent photos again (iopix skips the ones it already has).

## Layout

| Folder | What |
| --- | --- |
| `Shared/Core` | server address, sign-in cookies, Keychain, the upload client (all targets) |
| `Shared/App` | upload queue, Photos library watcher, the web view (both apps) |
| `iOS` | the iPhone app |
| `ShareExtension` | the share sheet extension |
| `Mac` | the Mac app: window and menu bar |
| `TV` | the Apple TV app |
| `TopShelf` | the Apple TV home screen row |
