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

Done: the project uses `com.ishandeepsingh.chameleonhunt`, your team, and automatic
signing. (A bundle ID can never change once a build is uploaded.)

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
- **Category**: the *first* box is Primary. Choose **Games** there (then Casual and
  Family under it). If Games is only in the second box, that's the Secondary category
  and App Store Connect says "You must select a primary category".
- The app's **Apple ID** is 6820470141 and is already in the game
  (`AppLinks.appStore` in `ChameleonHunt/UI/ShareCard.swift`): every shared picture carries
  the download link, and the squad lobby shows a **Get the game** QR code. The link only
  works once the app is live. When it is, swap the commented-out key in `docs/index.html`
  for the "Coming to the App Store" one.

## 5. Upload a build (15 min)

Nothing on the store page has to be filled in for this: no screenshots, no description,
no category. Only the app record from step 4, which exists.

1. Open `ChameleonHunt.xcodeproj` in Xcode. **Xcode → Settings → Accounts**: your Apple
   ID should be there with the team. Add it with **+** if it isn't.
2. At the top of the window, click the device name next to "ChameleonHunt" and choose
   **Any iOS Device (arm64)**. (Archive is greyed out while a simulator is chosen.)
3. **Product → Archive.** A few minutes. The Organizer window opens with the archive.
4. **Distribute App** → the first choice, **App Store Connect** (some Xcode versions
   call it *TestFlight & App Store*) → **Distribute**. Not *TestFlight Internal Only*:
   a build sent that way can never go to friends outside your account, or to the store.
   Xcode signs it, uploads it, and says the upload succeeded. The first time, macOS may
   ask for your Mac password so Xcode can use the signing key: **Always Allow**.
5. Apple then processes it: 10–30 minutes, and an email when it's done. It shows up at
   appstoreconnect.apple.com → your app → the **TestFlight** tab, as 1.0 (1).
   Export compliance is already answered in the project (standard encryption only), so
   it shouldn't ask. If the build says "Missing Compliance", click **Manage** and
   answer *None of the algorithms mentioned above*.
6. **Every later upload needs a higher build number.** Click the project in Xcode's
   left bar → the ChameleonHunt target → **General → Identity → Build**: 1 becomes 2,
   then 3. Version stays 1.0. Then archive again from step 2.

An unsigned Release archive of v7.7 builds cleanly here, with the camera and
local-network reasons, the privacy file and the icon all in it. Signing and the upload
itself need your Apple ID, so those two are yours to do.

## 6. TestFlight with your friends

The quickest way to get the game onto other people's phones. A public TestFlight link
works for anyone with the free TestFlight app.

**Yourself, and anyone on your developer account (no review, works at once)**
1. TestFlight tab → **Internal Testing → +** → name the group (e.g. "Me") → Create.
2. **Testers → +** → tick yourself. Others have to be added first under **Users and
   Access** (they get an email invitation to accept).
3. The build is added to the group by itself. On your iPhone: install **TestFlight**
   from the App Store, open it, and Chameleon Hunt is there to install.

**Your friends (needs a one-off beta review, usually under a day)**
1. TestFlight tab → **Test Information** (left side): fill in *Beta App Description*
   (two lines saying what the game is), *Feedback Email*, and your contact details
   under *Beta App Review Information*. Sign-in required: **no**.
2. **External Testing → +** → name the group (e.g. "Friends") → Create.
3. In the group: **Builds → +** → pick the build → Next → in *What to Test* write what
   you want tried (the list below) → **Submit for Review**.
4. When it says *Approved*: in the group, **Public Link → Enable Public Link**. Set a
   limit if you like (say 50). Copy the link and send it. Anyone who opens it on an
   iPhone or iPad gets TestFlight and then the game. Or add people one at a time by
   email under **Testers → +**.
5. A new build of 1.0 goes to the same group without another full review: open the
   group → **Builds → +** → pick it. A build stops working 90 days after upload.

Squad needs everyone on the same build, so tell the group to update (TestFlight does
it by itself if they've left automatic updates on).

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
  - New in v7.7: tap a chameleon. It should pop back out as the chameleon that was dropped (in the hider's skin),
    with a dark line and a coloured outline round it: pink in Swarm, the finder's colour in Squad. Walk round it:
    the outline should stay round the edge, never across the body or on the eyes. At the end of a round the ones
    nobody found come out the same way, outlined in white (Swarm) or their hider's colour (Squad).

## 7. Screenshots and the preview video (an afternoon)

Needed: **6.9" iPhone** (1320×2868) and **13" iPad** (2064×2752) — 3 to 10 each.

**A set is ready** in `screenshots/v1/`: five for iPhone (01–05) and five for iPad
(06–10), at exactly those sizes. Drag them into the two screenshot boxes on the version
page. Every one is made the same way: the screenshot inside the same drawn iPhone or
iPad, on the app icon's yellow, under a two-line caption at one size, with the chameleon
on top of the device. They're the screens the Simulator can show (home, the hunt's
intro, the lobby, Seeker's Turn, the skins); none has a chameleon hidden in a real room,
which is the shot that sells the game. Add one or two of those at the front when you
have them, as below (add lines to `screenshots/v1-spec.txt` and run the tool again).
Screenshots can only be changed with a new version of the app, so it's worth doing
before the public release.

The captions are in `screenshots/v1-spec.txt`, one line per picture. Change the words
there and run the command at the top of that file; the pictures are made again.

1. On your devices, take the shots that sell it (side button + volume up):
   - a room with a chameleon hidden in it, paint job on — the "Can you spot it?"
   - the same spot, **Show in pink** — the answer
   - FOUND on a find in Swarm
   - a Squad hunt with finds in several colours
   - the paint studio mid-paint
   - the Squad lobby and the HUNT intro (these the Simulator can do too)
2. AirDrop them to the Mac. List them in a spec file, one per line —
   `photo.png | First line / Second line | chameleon` (or add them to
   `screenshots/v1-spec.txt`). The chameleon is a colour or a skin, and optionally what
   it's doing (standing, peeking, lying, curled):

   ```
   ~/Desktop/shots/spot.png | Can you / spot it? | natural peeking
   ~/Desktop/shots/found.png | Tap it / to find it | bubblegum standing
   ~/Desktop/shots/squad.png | Who found / the most? | sky lying
   ```
3. From the project folder:

   ```bash
   sh Tools/build.sh && Tools/build/storeshots frame my-shots.txt AppStore/screenshots/final
   ```

   Phone shots become 1320×2868, iPad shots 2064×2752, landscape ones the landscape
   sizes, framed like the rest of the set. See `screenshots/v1/` for what comes out.
   (Take them on an iPhone with a Dynamic Island and a recent iPad: the drawn devices
   are an iPhone 17 Pro and a 13" iPad Pro.)
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
