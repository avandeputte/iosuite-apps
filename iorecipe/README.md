# ioRecipe for iPhone and iPad

**ioRecipe**, the iPhone and iPad app for [ioRecipe](https://github.com/avandeputte/iosuite/tree/main/iorecipe), the
family's recipes in ioSuite: the recipes as cards, one recipe to cook from, and the ways to add one.

## The recipes

- All of them, the family's, your own or your favourites; those with a tag or in a cookbook (the filter button); by
  title, the newest or the best rated first; search finds words in the title, the ingredients, the steps and the tags.
- A card shows the recipe's first photo, how long it takes, what it makes, everyone's average rating, a heart on your
  favourites and a lock on a recipe only you see.
- Without a connection the app shows what the server said last: the list, every recipe that was opened, and their
  photos.

## One recipe

- Its photos (swipe; tap for a large one, pinch to look closer), the times, what it makes.
- **Amounts for the servings you want**: − and + go from a quarter to ten times the recipe, the way the web page does
  it (`1 1/2 cups` becomes `3 cups`, `2-3 tbsp` becomes `4-6 tbsp`); "As written" goes back.
- Tap an ingredient to tick it off, a step to strike it out. The screen stays on while a recipe is open
  (Settings › Keep the screen on).
- The heart makes it one of your favourites, the stars are your rating (tap your rating again to take it away).
- Under ⋯: **Share ingredients** (the ones not ticked off, for the servings shown, as text: to Reminders, Notes, a
  message), the cookbooks it is in, and for who may change it: Edit, Add a photo, Take a photo, Delete. Press and
  hold a photo to show it on the card or delete it; press and hold a step to give it a picture.

## Adding a recipe

- **New recipe**: the form (title, description, what it makes, times, ingredients and steps a line each, notes, tags,
  where it is from, the family's or your own).
- **From a web page**: paste its address; the server fetches the page and keeps the recipe on it. The same from any
  browser: Share › ioRecipe (the first time, turn it on under *More* at the end of the share sheet's row of apps).
- **From pasted text** and **from a photo of a recipe** (a page of a book, a card; from the library or the camera):
  the server makes a draft of it, which opens in the form to be looked over before it is saved. A photo is read on
  your server (Tesseract); the menu offers it only when the server can.

What an account may do is what it may do on the web: viewers read the family's recipes, members also keep recipes of
their own, editors change the family's.

Not in the app: export and import as files, making and renaming cookbooks, the settings, and sending the ingredients
to an ioTask list (the app's password is for ioRecipe only, so the server cannot ask ioTask with it).

## How it talks to the server

`Authorization: Bearer <app password>` on every call, below ioRecipe's address at the server's address for apps
(`https://start-api.example.com/recipes/api/…`). That address serves only the calls named in the server's
`iorecipe/app.json` (`devices`): a call added to `Shared/API.swift` has to be added there too.

Signing in is the one sign-in of the ioSuite apps (`shared/DeviceSignIn`, see `shared/README.md`): the server's
address for apps, the name and password (and the two-step code when asked), `POST /api/auth/device`. The app password
it gets is listed and removed like every other one (Settings › Account on the web); it lives in the keychain, in the
app group the app shares with its share extension. Signing out gives it back.

## Build

Needs a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

    brew install xcodegen
    xcodegen                    # makes ioRecipe.xcodeproj from project.yml
    open ioRecipe.xcodeproj     # pick your iPhone, Run

`project.yml` names the team (`DEVELOPMENT_TEAM`) and the ids: `net.iothing.iorecipe`, its share extension
`net.iothing.iorecipe.share`, and the app group `group.net.iothing.iorecipe` both are in. Signing is automatic: Xcode
registers the ids and the group with the team on the first build.

## TestFlight

1. The app exists in App Store Connect (bundle id `net.iothing.iorecipe`).
2. `tools/testflight.sh` archives, signs and uploads it, with the Apple account signed in to Xcode (or an App Store
   Connect API key: `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh`). The build number is the time of the build.
3. In TestFlight, add yourself as an internal tester and install it from Apple's TestFlight app.

## Layout

    project.yml        the project, for XcodeGen
    Shared/            in the app and the extension: the API, the account (keychain), the models, the amounts
    iOS/               the app: sign-in, the cards, a recipe, the form, import, settings
    ShareExtension/    Share › ioRecipe
    tools/             testflight.sh, its export options, make_icon.py
