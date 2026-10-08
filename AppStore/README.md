# Getting ChameleonHunt onto TestFlight and the App Store

Everything in this folder is ready to use. Work down the list; each step says where.

| File | What it is |
|---|---|
| `Listing.md` | Every field App Store Connect asks for, written and length-checked (plus an Indonesian listing) |
| `Marketing.md` | How to get it seen with little time |
| `screenshots/` | Framed store screenshots, and the tool that makes them |
| `../docs/` | The website: landing page, privacy policy, help page (publish with GitHub Pages) |

---

## 0. Accept Xcode's licence (needed after every Xcode update)

Xcode updated itself to 27.0 and won't build until its licence is accepted. In Terminal:

```bash
sudo xcodebuild -license accept
```

Then open the project in Xcode and build once (⌘B). The last round of changes (sound,
sharing, the rating prompt, reconnecting) was written while Xcode was locked, so this is
the first full build of them — if anything fails to compile, paste the error to Claude.

## 1. Check your account and team (5 min)

- developer.apple.com/account → **Membership details**. Note the **Team ID** and the
  **Entity type**.
  - *Individual, your name*: you're the seller; the app is yours.
  - *The Academy / a university*: the store will show them as the seller. Ask your
    Academy mentors first — about publishing rules and who owns the app.
- appstoreconnect.apple.com → **Business**: the free-apps agreement must be active.

## 2. Make the bundle ID yours (5 min) — before the first upload

The project still uses `com.dzikryaji.chameleonhunt`. A bundle ID can never change once
uploaded, so if that isn't you:

1. Xcode → project → target **ChameleonHunt** → **Signing & Capabilities**.
2. **Team**: yours. **Bundle Identifier**: e.g. `com.<yourname>.chameleonhunt`.
3. Keep **Automatically manage signing** on.

## 3. Publish the website (15 min)

App Store Connect needs a **Privacy Policy URL** and a **Support URL**. The pages are in
`docs/`, styled like the game.

1. Open `docs/support.html` and replace both `SUPPORT-EMAIL` with an address you're
   happy to publish (a new Gmail just for the game is fine).
2. Push the project to a GitHub repository.
3. GitHub → the repo → **Settings → Pages** → Source: *Deploy from a branch* → Branch:
   `main`, folder **`/docs`** → Save.
4. A minute later: `https://<you>.github.io/<repo>/` (landing),
   `/privacy.html`, `/support.html`.

## 4. Create the app in App Store Connect (10 min)

**Apps → + → New App**: iOS · Name `Chameleon Hunt: AR Hide & Seek` · Primary language
English (U.K.) · your bundle ID · SKU `chameleonhunt1` · Full access.

Then, from `Listing.md`:

- **App Information**: subtitle, category **Games → Casual, Family**, content rights,
  age rating (answers → 4+).
- **Pricing and Availability**: Free, all countries, and **untick "Apple Silicon Macs"
  and "Apple Vision Pro"** (the game needs a camera in your hand).
- **App Privacy**: Data Not Collected; privacy policy URL.
- Write down the app's **Apple ID** number (App Information). Put it in
  `ChameleonHunt/UI/ShareCard.swift` → `AppLinks.appStore`:
  `URL(string: "https://apps.apple.com/app/id<number>")` — then every shared picture
  carries the download link, and the squad lobby shows a **Get the game** QR code for
  friends in the room who don't have it yet. Also swap it into `docs/index.html` (the
  commented-out key).

## 5. Upload a build (15 min)

1. Xcode: run destination **Any iOS Device (arm64)** → **Product → Archive**.
2. Organizer → **Distribute App → App Store Connect → Upload**. Defaults are right.
3. 15–30 minutes later it appears under **TestFlight**. (Export compliance is already
   answered in the project: standard encryption only.)
4. Next time: raise **Build** (target → General) by one before archiving.

## 6. TestFlight with your friends (a week)

- **Internal testing** (people on your team): instant, no review.
- **External testing** (anyone): create a group, add emails or turn on a **public
  link**. The first build needs a short beta review (usually within a day).
- What to check, on real devices — the Simulator can't do any of it:
  - A full Squad game with 3+ phones, host on a LiDAR device and host on a non-LiDAR one.
  - Turn one guest's Wi-Fi off for 10 seconds mid-hunt, then back on: they should see
    "Reconnecting to …" and carry on with their chameleons.
  - The host quits mid-game: guests should get "Host left" straight away.
  - Sound (silent switch off), Share from the results, the rating prompt (TestFlight
    shows it every time; the store at most three times a year).
  - Swarm on the iPhone and the 13" iPad: is the difficulty right on both?
  - A phone without LiDAR hides one on a table; the iPad should see it on the table, not sunk into it.
  - Put the iPad face down mid-hunt for ten seconds, then pick it up: the chameleons should fade out and come
    back in the same places.

## 7. Screenshots and the preview video (an afternoon)

Needed: **6.9" iPhone** (1320×2868) and **13" iPad** (2064×2752) — 3 to 10 each.

1. On your devices, take the shots that sell it (side button + volume up):
   - a room with a chameleon hidden in it, paint job on — the "Can you spot it?"
   - the same spot, **Show in pink** — the answer
   - FOUND on a find in Swarm
   - a Squad hunt with finds in several colours
   - the paint studio mid-paint
   - the Squad lobby and the HUNT intro (these the Simulator can do too)
2. AirDrop them to the Mac. List them in a spec file, one per line —
   `photo.png | Caption | colour`:

   ```
   ~/Desktop/shots/spot.png | Can you spot it? | natural
   ~/Desktop/shots/pink.png | Tap it to find it | bubblegum
   ~/Desktop/shots/squad.png | Every find in your colour | sun
   ```
3. From the project folder:

   ```bash
   sh Tools/build.sh && Tools/build/storeshots frame my-shots.txt AppStore/screenshots/final
   ```

   Phone shots become 1320×2868, iPad shots 2064×2752, landscape ones the landscape
   sizes — on the game's violet stage with the caption in its lettering and a chameleon
   peeking over the edge. See `screenshots/demo/` for what comes out.
4. **Preview video** (optional, strongly recommended — it plays by itself in search
   results): a 15–30 s screen recording on the iPhone of one Swarm round, from the
   drop to FOUND. Upload it on the same page as the screenshots.

## 8. Submit (10 min)

On the version page: screenshots, promotional text, description, keywords, support
URL, build, and the **Review notes** from `Listing.md` (with a link to a one-minute
video of a real Squad game — reviewers usually have one device). **Add for Review →
Submit.** Review usually takes one to two days.

**Release**: choose *Manually release this version*, so you pick launch day — then
see `Marketing.md` for what to line up before it.
