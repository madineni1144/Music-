# Website and Android accounts

The main and demo websites load `music-account.js`, which adds a Profile button with email/password registration, login, display-name editing and sign-out. The Android apps in `madineni1144/sam` load this website in a WebView, so they use the same interface and backend accounts. Browser and device sessions are separate; creating an account once is sufficient to log in on the other clients.

## Sessions

Browser requests use a 30-day Secure, HttpOnly, SameSite=Strict cookie scoped to `/api/auth`. The website never stores passwords or session tokens in localStorage. It checks the current session whenever Profile is opened and handles expired sessions by returning to login. Existing iOS Bearer-token responses and routes remain compatible.

Browser account mutations must come from `https://madinenimusic.madineni.xyz`. Set `MUSICAPP_PUBLIC_ORIGIN` in the backend environment if the public origin changes. Serve the UI and `/api/auth` from that same HTTPS origin. The browser cookie intentionally does not support an HTTP LAN URL. Reverse-proxy routes must forward `/api/auth` to the backend and preserve Origin, X-Music-Client and Cookie headers; authentication responses must not be cached.

No schema changes beyond the existing authentication module are introduced. Accounts remain optional: music endpoints remain public, playlists shared, and favorites device-local. Password reset and email verification are not implemented.

## Deploy on the existing Ubuntu checkout

Run `git pull --ff-only` while on `feature/audio-pipeline`, then `sudo systemctl restart musicapp.service`. If Git reports a local conflict, stop and preserve the local edits before resolving it. Open the public website over HTTPS and refresh it; Profile should be visible. Reload the Android app's website too. This change does not provide a rebuilt APK or modify iOS source.

## Verification

`node --test backend/tests/auth.test.cjs` checks API behavior using a database test double: browser cookie issuance, profile update and revocation, expired sessions, invalid login, validation, duplicate email, rate limiting, cross-origin rejection, and the existing iOS Bearer contract. These checks do not establish live PostgreSQL integration or phone behavior.

Manual checks after deployment:

1. Create an account in the website Profile panel. Confirm it shows the email and display name.
2. Close and reopen the browser and check Profile to verify the session persists.
3. Sign out, try an incorrect password, then log in successfully.
4. Save a display name containing punctuation or angle brackets; confirm it displays as plain text.
5. Log in on Android and iOS with the same account; verify the edited name there.
6. Sign out on one client; verify that client's session is revoked. Other device sessions are independent.
7. Confirm music playback still works while signed out.

Full Xcode, browser and physical Android tests remain required.
