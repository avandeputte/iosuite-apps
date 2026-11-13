# iosuite-apps

*The iPhone, iPad, Mac and Apple TV apps of the ioThing suite.*

Each app is a folder of this repository and builds on its own. The servers they talk to are in
[iosuite](https://github.com/avandeputte/iosuite).

| Folder | App | For | Server |
|---|---|---|---|
| [`iopix/`](iopix/) | ioPix | iPhone, iPad, Mac, Apple TV, and the Mac menu bar uploader | [iopix](https://github.com/avandeputte/iosuite/tree/main/iopix) |
| [`ionote/`](ionote/) | ioNote | Mac, iPhone, iPad | [ionote](https://github.com/avandeputte/iosuite/tree/main/ionote) |
| [`iohealth/`](iohealth/) | ioHealthSync | iPhone: Apple Health data to your own server | [iohealth](https://github.com/avandeputte/iosuite/tree/main/iohealth) |
| [`iostart/`](iostart/) | ioStart | iPhone, iPad: the bookmarks of the start page | [iostart](https://github.com/avandeputte/iosuite/tree/main/iostart) |

## Build

Every app has a `project.yml` for [XcodeGen](https://github.com/yonaskolb/XcodeGen); its README has the schemes.

```sh
git clone https://github.com/avandeputte/iosuite-apps && cd iosuite-apps/ionote
xcodegen generate
open *.xcodeproj
```

`tools/testflight.sh` in an app's folder archives and uploads a TestFlight build from a Mac. The workflows in
`.github/workflows/` (one per app) check that an app still builds when a pull request changes its folder; nothing is
signed or uploaded there.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
