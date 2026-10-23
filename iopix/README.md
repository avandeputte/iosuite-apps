# iopix for iPhone and Mac

Two small native companions to [iopix](https://github.com/avandeputte/iopix), the self-hosted photo library.

- **iopix for iPhone**: the iopix web app in a native shell, plus
  - **Send to iopix** in the share sheet (Photos, Files, any app that shares photos or videos),
  - a button to pick photos and videos from the camera roll and send them,
  - optionally, sending every new photo and video automatically whenever the app is opened.
- **iopix Uploader for Mac**: a menu bar app that
  - watches the Photos library and sends every photo and video added to it from the moment watching is turned on,
  - takes files and folders dropped on it (or chosen with the button),
  - keeps a queue on disk, so nothing is lost when the Mac sleeps, goes offline or restarts.

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
4. Run the `iopix` scheme on your iPhone, and `iopixUploader` on the Mac. The Mac app runs signed for this Mac
   only; turn on *Open at login* in its settings.

## Good to know

- The original of each photo is sent, as it came from the camera: edits made in Apple Photos are not, and of a
  Live Photo only the still is sent.
- Photos stored only in iCloud are downloaded first.
- On iPhone, automatic sending runs while the app is open (iOS does not let an app watch the library in the
  background). The share sheet sends while it is open; it says so.
- Turning watching off and on again later sends what was added in between. *Also send the last 7 days* sends the
  recent photos again (duplicates are skipped by iopix).

## Layout

| Folder | What |
| --- | --- |
| `Shared/Core` | server address, sign-in cookies, Keychain, the upload client (all targets) |
| `Shared/App` | upload queue, Photos library watcher, the web view (both apps) |
| `iOS` | the iPhone app |
| `ShareExtension` | the share sheet extension |
| `Mac` | the menu bar app |
