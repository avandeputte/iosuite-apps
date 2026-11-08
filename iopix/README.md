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
  - **Send to iopix** in the Share menu (Finder, Photos, Preview, Safari) and Finder's right-click Services / Quick Actions,
  - **watched folders** and **memory cards / cameras** (a drive with a DCIM folder): new photos are listed to review or import,
  - **notifications** (new photos to review, uploads done, an optional daily On this day), a **Dock badge** and
    progress bar,
  - **desktop picture** and a **screen saver folder** (Pictures › iopix Screen Saver for macOS's photo screen saver)
    from On this day, favorites, random photos or a person, a desktop **widget** (Rediscover, favorites or an album, picked with Edit "iopix"),
  - **Shortcuts** actions (Send to iopix, Show On this day, Search iopix, Review new photos) and iopix people,
    folders, places and albums in **Spotlight**,
  - **offline folders**: favorites, albums or people kept as originals in Pictures › iopix Offline.

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

## Build and run

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

## iPhone and iPad

The iPhone and iPad app is native: Explore, Photos (filters, search, saved searches, selection with bulk
actions), People and Faces, Places with a map, Folders, Albums, Tags, Trash, Import, Detected content,
History, Settings (Account, Display, Editing, Library, AI, Server and Security, as in the web app), Tools for
admins (the checks and suggestion pages: Metadata consistency and quality, Duplicate and Damaged files, Date and
Place suggestions, Jersey numbers, Clothing matches, Wrongly rotated, Place tags), and editing a photo (details, tags,
location, faces, rotate, crop, adjustments, edit log). It needs iopix 1.78 or later for background sending,
one-request uploads and the converted copies of videos the phone can't play; older servers still work, with
the slower paths. Settings and Tools follow the web app of ioPix 1.143 or later (one Settings menu, Settings ›
Server through the suite's shared endpoints, app passwords under Account); the ages and birthdays from ioContacts
and the menu of the other ioThing apps (the ioPix mark top left, when others are installed) need 1.114 to 1.117.
"Open in iopix" shows the same photo in the web app.

## How it signs in

The apps sign in exactly like a browser: the iPhone app's web view, or the Mac app's sign-in window, shows the
iopix page (and Cloudflare Access's page first, from outside the home network). The cookies from that sign-in are
then used for uploads. An account needs the editor or admin role to add photos; one-click accounts without a
password only work at home, as in the browser.

Cloudflare Access's sign-in expires after the session length set in Cloudflare. To keep the Mac uploading
unattended, either use the server's home-network address in Settings, or create a Cloudflare **service token**
(Zero Trust › Access › Service auth), allow it in the iopix application's policy (a *Service Auth* rule), and
enter its client ID and secret in the app's settings, or on the connect screen the first time (iPhone, iPad, Mac
and Apple TV). They are kept in the Keychain and sent with every request, so Cloudflare's sign-in page is skipped
and the app goes straight to iopix's own sign-in; the Apple TV, which can't show Cloudflare's page, needs one to
connect from outside. If Cloudflare refuses the token, the connect screen says so. You still sign in to iopix once.

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
- Sending or ignoring a photo in the review list on one device takes it off the review list on your other
  devices too (iPhone, iPad and Mac signed in to the same iCloud, with iCloud Photos on). A photo just taken
  joins in once it has reached iCloud Photos.
- An ignored photo does not come back. Turning watching off and on again later lists what was added in between.
  *Also list the last 7 days* lists the recent photos again (iopix skips the ones it already has).
- The apps only ever talk to the server address you gave them: a redirect to another site (a sign-in page in
  front of the server, for example) is not followed, and the app asks you to sign in instead.
- If an upload is cut short (iPhone put away, the Mac went to sleep) the photo stays in the queue and is sent
  the next time the app is open. A photo the server refuses is marked failed and kept in the list.
- A server on the home network may be plain `http://`; the apps try that when `https://` does not answer.

## Layout

| Folder | What |
| --- | --- |
| `Shared/Core` | server address, sign-in cookies, Keychain, the upload client (all targets) |
| `Shared/App` | upload queue, Photos library watcher, the web view (both apps) |
| `iOS` | the iPhone app |
| `ShareExtension` | the share sheet extension |
| `Mac` | the Mac app: window, menu bar and extras |
| `MacShare`, `MacWidget` | the Mac Share menu entry and widget |
| `TV` | the Apple TV app |
| `TopShelf` | the Apple TV home screen row |

## License

GPL-3.0-or-later (the GNU General Public License, version 3 or later), see [LICENSE](LICENSE).
