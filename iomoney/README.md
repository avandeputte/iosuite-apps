# ioMoney for iPhone and iPad

**ioMoney**, the iPhone and iPad app for [ioMoney](https://github.com/avandeputte/iosuite/tree/main/iomoney), the
household's finances in ioSuite: mostly for looking, with the few changes one makes on a phone.

- **Overview**: the net worth, now and over a month, three, a year or five; the accounts in their five groups (Cash,
  Investments, Credit cards, Loans, Assets) with each group's total. On top, what needs attention: an account whose
  bank link is behind, a bank account about to run low, the transactions that need a look.
- **An account**: its balance or value over time; for a bank account the coming 60 days (the recurring transactions
  and the transfers made at a steady pace, with the balance after each and the lowest point); its transactions.
- **Transactions**: the newest first, more as you scroll. Search by words or amounts (`$280`, `100-200`, `>500`), and
  narrow to an account, a category, a month, money out or in, or those that need a look (swipe one right, or mark
  all shown, as looked at).
- **A transaction**: the payee, the bank's own text, the category or where a transfer went, notes, tags. Edit changes
  the payee, category, notes, tags and whether it is hidden; kept as changed here, also by the next sync, and nothing
  is changed in Monarch. **Receipts**: add one from the camera, the photo library or a file; tap to open, swipe to remove.
- **Spending**: a month's money out and in by category (tap one for its transactions), and month by month over the
  past year, transfers left out.
- **Bills**: the recurring transactions on the days they fall, from the first of this month to six weeks ahead: not
  seen yet, coming up, paid. Tap one with a provider's details (account number, phone, website) to show them.
- **Investments**: what the investment accounts hold at the latest quotes, by holding or by account.

**Who sees what** is the server's business, as on the web: every call is answered as the person signed in, so a
private account shows only to its owner and the people they ticked, an admin included.

**Kept on the device**: the server's address, the name, and the app password (in the keychain). Nothing of the money:
every screen asks the server, a receipt that is opened is a temporary file removed at the next start, and the app
switcher shows the app's icon, not the accounts. With Settings › Ask for Face ID or the passcode (on by default) the
app asks each time it is opened.

Not in the app: rules, linking transfers, Tidy up, reconciling, importing a bank file, accounts and holdings by hand,
Monarch Money's settings. There is no budgeting, and no pending flag, as in ioMoney itself.

## How it talks to the server

`Authorization: Bearer <app password>` on every call, below ioMoney's address at the server's address for apps
(`https://start-api.example.com/money/api/…`). That address serves only the calls named in the server's
`iomoney/app.json` (`devices`): a call added to `Shared/API.swift` has to be added there too.

Signing in is the one sign-in of the ioSuite apps (`shared/DeviceSignIn`, see `shared/README.md`): the server's
address for apps, the name and password (and the two-step code when asked), `POST /api/auth/device`. The app password
it gets is listed and removed like every other one (Settings › Account on the web). Signing out gives it back.

## Build

Needs a Mac with Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

    brew install xcodegen
    xcodegen                   # makes ioMoney.xcodeproj from project.yml
    open ioMoney.xcodeproj     # pick your iPhone, Run

`project.yml` names the team (`DEVELOPMENT_TEAM`) and the id, `net.iothing.iomoney`. Signing is automatic.

## TestFlight

1. The app exists in App Store Connect (bundle id `net.iothing.iomoney`).
2. `tools/testflight.sh` archives, signs and uploads it, with the Apple account signed in to Xcode (or an App Store
   Connect API key: `ASC_KEY_ID=… ASC_ISSUER_ID=… tools/testflight.sh`). The build number is the time of the build.
3. In TestFlight, add yourself as an internal tester and install it from Apple's TestFlight app.

## Layout

    project.yml        the project, for XcodeGen
    Shared/            the API, the account (keychain), the models
    iOS/               the app: sign-in and the lock, overview, an account, transactions, spending, bills, investments
    tools/             testflight.sh, its export options, make_icon.py
