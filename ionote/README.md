# ionotes

Save anything from the clipboard as a searchable note, on your Mac, iPhone and iPad, synced through iCloud.
A sibling of iopix: the same two-tone name ("io" in gold), with its own deep-teal note-card icon.

- **Inbox**: everything you copy (text, images, files) and every screenshot you take lands in the Inbox,
  newest first. Pick what's worth keeping and click **Save as Note** (⌘↩). The Inbox stays on this Mac.
- **Right-click › Save to ionotes**: select text in any app and save it straight to your notes.
  Images in Finder: right-click › Services › Save Image to ionotes.
- **Screenshots**: new screenshots show up in the Inbox (or go straight to notes, see Settings). Their text
  is read on the Mac with Apple's Vision framework, so a search finds words that are inside a screenshot.
- **Folders, tags and pins**: make folders like Work or AI in the sidebar and drag notes onto them (or use
  Move to Folder); add tags in a note, which show up in the sidebar and are searchable; pin notes to the top
  and pick a sort order. Right-click a folder or tag in the sidebar to give it a colour (synced too).
- **Copy and drag out**: hover a note and click copy, or press ⌘C, then paste anywhere; these copies never land
  in the Inbox. Drag a note or screenshot into Mail, Word or Finder (images go as a PNG named after the note).
  Saving an Inbox item as a note takes it out of the Inbox.
- **Search**: full-text search (SQLite FTS5) over titles, note text and text found in images, prefix-matching
  every word you type.
- **iCloud sync**: notes live in SwiftData, mirrored to the private CloudKit database of
  `iCloud.net.iothing.ionotes`, so they follow your Apple Account to other Macs, and later to an iPhone/iPad app.
- **Menu bar**: click the icon to open ionotes; right-click it to pause clipboard capture, open Settings or quit.
  Quit from the Dock (or ⌘Q) just closes the window: ionotes keeps running in the menu bar.
  ionotes starts at login in the menu bar only (a launch agent passes `--background`); the Dock icon appears
  while the window is open. Turn it off in Settings.

On **iPhone and iPad**, ionotes shows the same notes, folders, tags and colours. Paste with the clipboard button at
the bottom of the list (iOS doesn't ask permission for that button), or add photos and screenshots with the photo
button; their text is read on the device so search finds it. The clipboard Inbox stays on the Mac.

Passwords never go into the Inbox: copies that apps mark as private (concealed or transient) are skipped, and so is
anything copied while a password manager is in front (Proton Pass, 1Password, Bitwarden, KeePassXC, Passwords and
others; edit the list in Settings, or right-click an Inbox item > Remove and Never Keep Copies from that app).

## Build and run

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
the same setup as iopix.

```sh
cd ~/Documents/GitHub/ionotes
xcodegen generate
open ionotes.xcodeproj
```

In Xcode, pick the **ionotes** scheme and press ⌘R. The team id in `project.yml` is the iopix one
(`69M2JRAT8P`); change `DEVELOPMENT_TEAM` there if needed and run `xcodegen generate` again.

The first build registers the iCloud container. If Xcode shows a red iCloud container under
*Signing & Capabilities › iCloud*, click the refresh button there (or `+` and add `iCloud.net.iothing.ionotes`).

To build and install from the command line instead:

```sh
xcodegen generate
xcodebuild -project ionotes.xcodeproj -scheme ionotes -configuration Release -derivedDataPath build \
  -allowProvisioningUpdates build
pkill -x ionotes; rm -rf /Applications/ionotes.app
ditto build/Build/Products/Release/ionotes.app /Applications/ionotes.app
/System/Library/CoreServices/pbs -update && open /Applications/ionotes.app
```

### First run

- macOS asks to let ionotes read your **Desktop** (or wherever screenshots go): allow it, that is how
  screenshots are picked up.
- Newer versions of macOS may ask whether ionotes may **read the clipboard** (paste from other apps):
  allow it, or the Inbox stays empty. You can change it later in System Settings › Privacy & Security.
- **Save to ionotes** appears in the right-click menu once the app has run from `/Applications` (or Xcode)
  and macOS has refreshed its Services list. If it doesn't show, run `/System/Library/CoreServices/pbs -update`,
  or turn it on in System Settings › Keyboard › Keyboard Shortcuts › Services › Text (you can give it a
  shortcut there too).

## iPhone and iPad (TestFlight)

The `ionotesiOS` target has the same bundle id as the Mac app, so both are one app in App Store Connect.

1. In App Store Connect, create the app once (bundle id `net.iothing.ionotes`).
2. `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh` builds, signs and uploads it, with the same API key as
   iopix. The build number is the build's date and time.
3. In TestFlight, add yourself as an internal tester and install it from Apple's TestFlight app.

TestFlight builds use iCloud's **Production** environment, so deploy the schema first (see below).

## iCloud notes

- Sync needs the Mac signed in to iCloud with iCloud Drive on. The sidebar shows "Syncing with iCloud" when
  it is working.
- `/Applications/ionotes.app/Contents/MacOS/ionotes --init-cloudkit-schema` creates every record type and field in
  the Development environment (then quits), ready to deploy.
- Debug builds use CloudKit's **Development** environment. Before sharing a release build, open the
  [CloudKit Console](https://icloud.developer.apple.com), pick `iCloud.net.iothing.ionotes`, and
  *Deploy Schema Changes* to Production; for that release set `com.apple.developer.aps-environment` to
  `production` in `project.yml`.
- CloudKit only allows additive schema changes once in Production: new fields on `NoteRecord` must be
  optional or have a default, and nothing can be renamed or removed.

## How it is put together

```
Shared/            platform-neutral, ready for an iPhone/iPad target
  Models.swift       NoteRecord (SwiftData, synced), Note and InboxItem snapshots
  NotesStore.swift   source of truth for the UI; mirrors SwiftData into the search index
  Persistence.swift  ModelContainer with the CloudKit private database
  Database.swift     local SQLite: Inbox + FTS5 search index of notes
  OCR.swift          Vision text recognition
  Brand.swift        the two-colour "ionotes" name (iopix's gold, ionotes' teal)
Mac/
  App/               @main app, AppDelegate (Services, monitors)
  NotesStore+Mac.swift  copying and dragging out
  Capture/           clipboard monitor, screenshot watcher, Services provider
  Views/             main window, inbox, notes, settings, menu bar
iOS/                 the iPhone and iPad app (SwiftUI), sharing Shared/
tools/make_icon.py   draws the app icon (needs Pillow and Poppins Bold; --ios for the square iPhone/iPad tile)
tools/testflight.sh  builds the iPhone/iPad app and uploads it to TestFlight
```

The search index is rebuilt from SwiftData whenever notes change locally or arrive from iCloud,
so it never needs syncing itself. Local data lives in `~/Library/Application Support/ionotes/`.

ionotes is not sandboxed: it needs to read the screenshots folder and the clipboard. That suits a
Developer ID release like iopix's (`tools/release-mac.sh` in iopix-apps works with the scheme name changed).
