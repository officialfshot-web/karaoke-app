# Karaoke 🎤

Pick a song from your YouTube Music library and it plays with synced, scrolling lyrics (from lrclib.net).
Tap a lyric line to jump there, use **− / +** to fix sync (saved per song), tap 🔍 if it grabbed the wrong lyrics.

## 1. Host it (free, ~3 min)
**GitHub Pages:** make a public repo named `karaoke-app`, upload everything in this folder **except `ios/`**,
then go to Settings → Pages → Branch: `main` → Save. Your URL is `https://YOUR-USERNAME.github.io/karaoke-app/`.

(Netlify Drop also works: drag this folder onto app.netlify.com/drop.)

## 2a. Quickest install: Home Screen (no Mac needed, never expires)
On iPhone open the URL in **Safari** → Share → **Add to Home Screen**.

## 2b. Real app via Xcode (your Mac, free Apple ID, re-install every 7 days)
1. Xcode → File → New → Project → iOS **App**, name `Karaoke`, Interface **SwiftUI**.
2. Replace the generated `KaraokeApp.swift` with `ios/KaraokeApp.swift`, delete `ContentView.swift`.
3. Set `appURL` at the top of the file to your hosted URL.
4. Drag `icon-1024.png` into Assets → AppIcon.
5. Target → Signing & Capabilities → Team: your Apple ID (Personal Team).
   Then Target → Info → add **Privacy - Microphone Usage Description** = `Sing along with live studio effects.` (the voice studio crashes without it).
   If Xcode shows Swift concurrency errors: Build Settings → **Default Actor Isolation** → `nonisolated`.
6. Plug in your iPhone, pick it as the run target, press ▶.
   On the phone: Settings → General → VPN & Device Management → trust your Apple ID.
   Also turn on Settings → Privacy & Security → **Developer Mode** if asked.

Free Apple IDs make the app expire after 7 days; just hit ▶ in Xcode again.

## 3. Sign in to your YouTube Music account (optional)
Without signing in you can still use **Paste link** (YouTube Music → Share → Copy link).
To see your liked songs and playlists:

1. console.cloud.google.com → create a project.
2. APIs & Services → Library → enable **YouTube Data API v3**.
3. OAuth consent screen → External → fill in app name + your email → under **Test users** add your Google account.
4. Credentials → Create credentials → OAuth client ID:
   - **For the Home Screen app:** type *Web application*. Authorized JavaScript origin `https://YOUR-USERNAME.github.io`,
     Authorized redirect URI `https://YOUR-USERNAME.github.io/karaoke-app/` (exact, with trailing slash).
     Paste the client ID into `GOOGLE_CLIENT_ID` at the top of `app.js` (then re-upload app.js).
   - **For the Xcode app:** type *iOS*, bundle ID = your Xcode project's bundle identifier.
     Paste that client ID into `iosClientID` in `KaraokeApp.swift`.
5. Tap **Sign in**. (Google says "unverified app", so tap Continue. That's normal for a personal app.)

YouTube Music likes show up under **Liked songs**.

## Notes
- Some official music videos are blocked from playing outside YouTube. If one won't play, search for an "audio" or "lyrics" upload.
- Vocals aren't removed. YouTube's player doesn't let apps touch its audio.
