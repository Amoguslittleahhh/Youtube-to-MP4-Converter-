# YT to MP4

Share a YouTube video from your iPhone and get back an MP4 that plays everywhere, including WhatsApp, iMessage, Telegram and Discord. Best quality by default (up to 4K).

There are two ways to use it:

| | **Free: App Store only** | **Paid: the full app** |
|---|---|---|
| Cost | Free | $99/yr Apple Developer membership |
| Needs | a-Shell + Shortcuts (both App Store) | TestFlight |
| Looks like | Share sheet → quality menu → saved | Custom app with progress, quality picker, Google sign-in |

---

## Free: App Store only

The download runs on your own iPhone using [yt-dlp](https://github.com/yt-dlp/yt-dlp) inside **a-Shell**, a free, open-source terminal app. One Apple **Shortcuts** shortcut adds it to the share sheet, and Apple's own video encoder converts 4K.

### 1. Install (2 minutes)

1. Install **a-Shell** from the App Store (the full one, not "a-Shell mini").
2. Open a-Shell and paste these two lines, one at a time, pressing Return after each:

   ```
   curl -L https://raw.githubusercontent.com/Amoguslittleahhh/Youtube-to-MP4-Converter-/main/ashell/ytmp4.py -o ytmp4.py
   python3 ytmp4.py --setup
   ```

   It installs yt-dlp and ends with **All set!** plus a "files go to:" line. Keep that screen in mind.

### 2. Build the shortcut (one time, about 5 minutes)

Open **Shortcuts** → **+**. Name it exactly **YT to MP4**. Then tap **ⓘ** (Details) and turn on **Show in Share Sheet**.

Add these actions in order. Words in *italics* are variables you pick from the bar above the keyboard.

| # | Action | Set it to |
|---|---|---|
| 1 | **If** | *Shortcut Input* **contains** `ytmp4-save` |
| 2 | ↳ **Get Dictionary from Input** | *Shortcut Input* |
| 3 | ↳ a-Shell **Get File** | *Dictionary* → key `file` (tap the variable → *Get Value for Key*). Turn on **as a copy** if shown. |
| 4 | ↳ **If** | *Dictionary* → key `convert` **is** `yes` |
| 5 | ↳↳ **Encode Media** | *File*, then *Show More* → **Size 3840×2160** (not HEVC) |
| 6 | ↳↳ **Set Name** | *Encoded Media* → *Dictionary* key `name` followed by `.mp4` |
| 7 | ↳ **Otherwise** → **Get Variable** | *File* |
| 8 | ↳ **End If** → **Share** | *If Result* |
| 9 | **Otherwise** → **List** | `Best (up to 4K)`, `1080p`, `720p` |
| 10 | ↳ **Choose from List** | *List* |
| 11 | ↳ **Text** | `python3 ~/Documents/bin/ytmp4.py "`*Shortcut Input*`" `*Chosen Item* |
| 12 | ↳ **URL Encode** | *Text* |
| 13 | ↳ **Open URLs** | `ashell://`*URL Encoded Text* |
| 14 | **End If** | |

Here's what each half does:
- **Otherwise half (steps 9–13):** runs when you share a video. It asks for the quality and starts the download in a-Shell.
- **If half (steps 2–8):** runs when a-Shell reopens the shortcut after the download. It converts 4K to H.264 if needed, then opens the iPhone **Share** menu. From there tap **Save Video** (Photos), **Save to Files**, or **WhatsApp**.

The file is named after the video's title.

**Optional:** delete steps 9–10 and the *Chosen Item* in step 11 to always get the best quality with no question asked.

If Get File can't find the file, check the "files go to:" line from setup. The `file` value is relative to that folder.

### 3. Use it

YouTube or Safari → **Share** → **YT to MP4** → pick a quality. a-Shell opens and shows the download. When it finishes, the shortcut opens again by itself, converts 4K if needed (a minute or two), and shows the Share menu: **Save Video**, **Save to Files** or **WhatsApp**. Files are named after the video.

If **YT to MP4** isn't in the share sheet, scroll the apps row to **More** → **Edit** and add it to Favourites.

- **Quality:** Best gives true 4K when YouTube has it, converted to H.264. Otherwise you get 1080p H.264, which needs no conversion and is lossless.
- **Updates:** yt-dlp and this script update themselves once a week. If YouTube suddenly breaks downloads, paste the two setup lines again.

### Extras

- **Age-restricted and members-only videos:** export your youtube.com cookies as `cookies.txt` (a Safari "cookies.txt" export extension from the App Store does this). Then in the **Files** app put the file in *On My iPhone › a-Shell › ytmp4*. Delete the file to stop using your account. Some of these videos may still fail, because a-Shell can't run YouTube's JavaScript.
- **Live streams:** they record from "now". Tap **ctrl** then **c** on a-Shell's keyboard bar to stop, and it saves what was recorded.

### Limits of the free route

- You build the shortcut by hand once. Apple only accepts ready-made shortcut files that were signed on a Mac.
- a-Shell comes to the screen while it downloads, so keep it open for long videos.
- 4K conversion uses Apple's **Encode Media**, which needs a phone that can play AV1. A 15 Pro Max can.

---

## Paid: the full app (TestFlight)

The Swift app in this repo (`App/`, `ShareExtension/`, `Core/`) is a native iOS 26 app:

- a share extension with a quality picker (up to 4K);
- on-device H.264 conversion;
- Google sign-in for age-restricted and members-only videos;
- live recording;
- Save to Photos, Save to Files, and Share.

GitHub Actions builds it and uploads it to TestFlight, so no Mac is needed, but it does need the **$99/yr Apple Developer Program**.

1. **Create an API key.** In [App Store Connect](https://appstoreconnect.apple.com) go to **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **+** (Access: **Admin**).
   - Note the **Issuer ID** and **Key ID**.
   - Download the `.p8`, then rename it to `.txt` in Files so you can copy its text.
2. **Add the secrets.** In this repo go to **Settings** → **Secrets and variables** → **Actions** and add `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the whole key text).
3. **Run the workflow.** Go to **Actions** → **iOS** → **Run workflow** on `main`. The first run registers the app IDs and asks you to create the app.
4. **Create the app.** In App Store Connect: **Apps** → **+** → **New App**, with bundle ID `io.github.amoguslittleahhh.ytmp4`.
5. **Add yourself as a tester.** In the app's **TestFlight** tab, add yourself to an internal group with automatic distribution.
6. **Run the workflow again.** The app then appears in **TestFlight**.

Signing files live encrypted on the `signing` branch, managed by fastlane match, with a password derived from your API key.

## Notes

- `clients.json` holds the YouTube client settings the paid app uses. It's fetched at runtime, so most YouTube breakages are fixed by editing it.
- JavaScript challenge solver: yt-dlp's [EJS](https://github.com/yt-dlp/ejs) (Unlicense; bundles meriyah ISC and astring MIT).
- Only download videos you have the right to save. Respect YouTube's Terms of Service and creators' rights.
