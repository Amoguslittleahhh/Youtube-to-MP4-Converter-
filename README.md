# YT to MP4

A minimal iPhone app (iOS 26) that adds **YT to MP4** to the share sheet. Share any YouTube video and you get an MP4 back: the best quality by default (up to 4K), with a quality picker if you want something else. You can save it to **Photos** or **Files**, or share it straight to WhatsApp.

- Every file is **H.264 + AAC MP4 with "faststart"**, so it plays and previews in WhatsApp, iMessage, Telegram, Discord, Instagram and Signal.
- ≤1080p is copied losslessly. YouTube only offers 1440p and 4K as AV1, so the app converts those to H.264 on the iPhone's hardware encoder. That needs AV1 hardware, which the iPhone 15 Pro and newer have.
- **Live streams:** tap Record, then Stop & Save. Finished streams download like normal videos.
- **Age-restricted and members-only videos:** sign in with your Google account (person icon, top right of the app).
  - Fallback: import a `cookies.txt` file.
  - Age-restricted videos also need your Google account to be age-verified, the same as in the YouTube app.

Everything is built in the cloud by GitHub Actions and installed through TestFlight. **No Mac is needed.**

## One-time setup (all from your iPhone, in Safari)

1. **Apple Developer Program.** You need a paid membership ($99/yr); TestFlight requires it. You can enrol in the *Apple Developer* app.
2. **Create an API key.**
   1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **+**.
   2. Name it `GitHub` and set Access to **Admin**.
   3. Note the **Issuer ID** and **Key ID**.
   4. Tap **Download** to get the `.p8` file. You can only download it once.
   5. In the Files app, long-press the `.p8` → **Rename** to `key.txt`, open it, and **Select All → Copy**.
3. **Add three GitHub secrets.** Go to this repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: the whole text of the key, including the `-----BEGIN PRIVATE KEY-----` lines
4. **Run the build.** Go to **Actions** → **iOS** → **Run workflow** (branch `main`). The first run registers the app IDs and then stops with a message asking you to create the app record.
5. **Create the app record.** In App Store Connect: **Apps** → **+** → **New App**:
   - Platform: iOS
   - Name: anything unique (the name on your home screen is still "YT to MP4")
   - Bundle ID: `io.github.amoguslittleahhh.ytmp4`
   - SKU: `ytmp4`
6. **Add yourself as a tester.** In the app's **TestFlight** tab → **Internal Testing** → **+**:
   - create a group,
   - add yourself,
   - turn on **automatic distribution**.
7. **Run the workflow again.** About 15 minutes later, plus Apple's processing time, the app appears in the **TestFlight** app. Install it.

Every push to `main` builds and uploads a new version automatically.

## Using it

- **From YouTube or Safari:** tap **Share** → **YT to MP4**. If you don't see it, tap **More**, then **Edit**, and add it to Favourites.
- **Or** open the app and paste a link.
- Up to 1080p downloads right in the share sheet. 1440p/4K conversion and live recording open the app automatically, because share extensions have tight memory limits.

## If YouTube breaks something

YouTube changes its internals regularly. The client settings the app uses live in [`clients.json`](clients.json), and the app reads them from this repo every time it runs. Most fixes are an edit to that file (mirroring what [yt-dlp](https://github.com/yt-dlp/yt-dlp) changed), with no new build needed.

## Notes

- Signing files are kept on this repo's `signing` branch, managed by fastlane match. They are AES-encrypted with a password derived from your secret API key. If you ever replace the API key, delete the `signing` branch so it's recreated.
- The JavaScript challenge solver is yt-dlp's [EJS](https://github.com/yt-dlp/ejs) (Unlicense; bundles meriyah ISC and astring MIT). It runs in JavaScriptCore.
- Download only videos you have the right to save; respect YouTube's Terms of Service and creators' rights.
