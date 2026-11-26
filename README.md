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

The download runs on your own iPhone using [yt-dlp](https://github.com/yt-dlp/yt-dlp) inside **a-Shell**, a free, open-source terminal app. Apple's **Shortcuts** app adds it to the share sheet, and Apple's own video encoder converts 4K.

### 1. Install (2 minutes)

1. Install **a-Shell** from the App Store (the full one, not "a-Shell mini").
2. Open a-Shell and paste these two lines, one at a time, pressing Return after each:

   ```
   curl -L https://raw.githubusercontent.com/Amoguslittleahhh/Youtube-to-MP4-Converter-/main/ashell/ytmp4.py -o ytmp4.py
   python3 ytmp4.py --setup
   ```

   It installs yt-dlp and ends with **All set!** plus a "files go to:" line. Keep that screen in mind.

### 2. Shortcut 1: "YT to MP4" (the share-sheet button)

Open **Shortcuts** → **+** (new shortcut). Name it **YT to MP4**. Then:

1. Tap the **ⓘ** (Details) button and turn on **Show in Share Sheet**. Back in the editor, the top line says *Receive **Any** input from Share Sheet*. Tap **Any** and keep only **URLs**, **Text** and **Safari web pages**. Set *If there's no input* to **Get Clipboard**.
2. Add **Get URLs from Input** (input: *Shortcut Input*).
3. Add **Choose from Menu**. Set the prompt to `Quality` and the items to `Best (up to 4K)`, `1080p` and `720p`. Under each item add a **Text** action containing the item's name.
4. Add **Text** and type exactly the following. Insert `URLs` and `Menu Result` from the variable bar; keep the quotes around URLs.
   ```
   python3 ~/Documents/bin/ytmp4.py "URLs" Menu Result
   ```
5. Add **URL Encode** (in the *Encode/Decode URL* action), set to Encode, on the Text from step 4.
6. Add **Open URLs** with the text `ashell://` followed by the *URL Encoded Text* variable.

### 3. Shortcut 2: "YT Save" (converts and saves when the download finishes)

New shortcut. It must be named exactly **YT Save**. Then:

1. Add a-Shell's **Get File** with path `ytmp4/info.json`. If there's an **as a copy** option, turn it on.
2. Add **Get Dictionary from Input**.
3. Add a-Shell's **Get File** with path `ytmp4/latest.mp4`, **as a copy** on.
4. Add **If**: *Dictionary* → key `convert` (tap the variable, choose *Get Value for Key*) **is** `yes`.
   - Inside **If**: add **Encode Media** on the *File* from step 3. Tap *Show More* → **Size: 3840×2160** (not HEVC). This turns YouTube's 4K AV1 into H.264 4K.
   - Inside **Otherwise**: add **Get Variable** → the *File* from step 3.
5. After **End If**, add **Set Name**: *If Result* → name = *Dictionary* key `title` followed by `.mp4`.
6. Add **Choose from Menu** with the prompt `Save to`:
   - **Photos** → **Save to Photo Album** (*Renamed Item*)
   - **Files** → **Save File** (*Renamed Item*, turn on *Ask Where to Save*)
   - **Share** → **Share** (*Renamed Item*). Use this to send it straight to WhatsApp.

If Get File says it can't find the file, put in the full path from the "files go to:" line that setup printed, with `/latest.mp4` or `/info.json` added.

### 4. Use it

YouTube or Safari → **Share** → **YT to MP4** → pick a quality. a-Shell opens and shows the download. When it finishes, **YT Save** opens by itself. 4K takes a minute or two to convert; then pick **Photos**, **Files** or **Share**.

If **YT to MP4** isn't in the share sheet, scroll the apps row to **More** → **Edit** and add it to Favourites.

- **Quality:** Best gives true 4K when YouTube has it, converted to H.264. Otherwise you get 1080p H.264, which needs no conversion and is lossless.
- **Updates:** yt-dlp and this script update themselves once a week. If YouTube suddenly breaks downloads, paste the two setup lines again.

### Extras

- **Age-restricted and members-only videos:** export your youtube.com cookies as `cookies.txt` (a Safari "cookies.txt" export extension from the App Store does this). Then in the **Files** app put the file in *On My iPhone › a-Shell › ytmp4*. Delete the file to stop using your account. Some of these videos may still fail, because a-Shell can't run YouTube's JavaScript.
- **Live streams:** they record from "now". Tap **ctrl** then **c** on a-Shell's keyboard bar to stop, and it saves what was recorded.

### Limits of the free route

- You build the two shortcuts by hand once. Apple only accepts ready-made shortcut files that were signed on a Mac.
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
