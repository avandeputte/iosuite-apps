# shared

Code that every native app compiles in (each app's `project.yml` lists the folder as a source).

## DeviceSignIn

The one sign-in of ioStart, ioPix, ioNote, ioHealthSync, ioRecipe and ioMoney: the same screen, wording and behaviour in each.

- Fields: **Server address** (the server's address for apps, e.g. `https://start-api.example.com`), **Name**,
  **Password**; a **Code** field appears only when the server answers that the account has two-step sign-in.
- `POST <app base>/api/auth/device` with `{name, password, code?, label, scope: ""}`. The app base is the address
  with the app's folder added (ioStart `/`, ioPix `/pix`, ioNote `/notes`, ioHealth `/health`, ioRecipe `/recipes`, ioMoney `/money`), not twice when the
  address already ends in it. ioPix, ioNote, ioHealth, ioRecipe and ioMoney also try the plain address (an app on a hostname of its
  own) when the folder answers 404, and check with the new password that it really is that app.
- 200 → `{name, password, scope, user, settings}`: the app password goes in the Keychain (in the app group where
  widgets and extensions read it), the address and name in defaults. The typed password is never kept.
  401 with `twoStep` → the Code field; 401 → wrong name or password; 429 → wait `Retry-After` seconds;
  403 → the account has no access to the app.
- Every request after that: `Authorization: Bearer <app password>`.
- Sign out: `DELETE <app base>/api/auth/device` with the Bearer header, then the Keychain item is removed.
- A 401 later (the password was removed in Settings › Account): the sign-in screen again, address and name filled in.
