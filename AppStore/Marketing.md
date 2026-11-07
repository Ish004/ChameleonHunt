# Getting ChameleonHunt seen, on little time

The game has two things most indie games don't: it's **built to be shown** (a chameleon
hidden in a real room is a puzzle anyone can play from a photo), and it **spreads itself**
(a Squad game needs everyone to have it). Most of this plan leans on those two.

Ordered by how much it does for the time it takes.

---

## Before launch (one weekend)

### 1. The listing — about an hour, once
Search ranking comes mostly from the **name, subtitle and keywords**; they're written
and length-checked in `Listing.md`. The first three screenshots decide whether people
tap Get — lead with the "Can you spot it?" shot.

### 2. A 20-second preview video — an hour
It autoplays, muted, in search results. One Swarm round on the iPhone, recorded with the
screen recorder: a chameleon dropping and melting into the room → the phone handed over →
3-2-1 → a tap → FOUND. No editing needed beyond trimming.

### 3. Ask Apple's editors — 15 minutes, 3+ weeks before launch
App Store Connect → your app → **Featuring → Nominations → +** (New content / launch).
Apple's editors read these; they like AR done well, LiDAR used for something real, and
student developers. Draft:

> Chameleon Hunt is hide and seek in your real room. You hide a chameleon anywhere,
> then paint it — with colours scanned from the spot by the LiDAR scanner — until it
> vanishes; real furniture hides it as you'd expect. A friend gets a countdown to find it
> through the camera. Squad mode puts 2–6 iPhones and iPads in the same game over local
> Wi-Fi, no accounts. Built at the Apple Developer Academy.

Nominate again for every notable update — it's the one channel that can put the game in
front of millions for free.

### 4. Launch with an event — 20 minutes
App Store Connect → **In-App Events → +**. Events show up in search results and on your
product page, and can be featured. Ideas:
- **Launch week: Hide & Seek Week** — "Hide one in your room tonight."
- **Halloween Hunt** (late October) — hide them where the decorations are.
- **Holiday Hide** (December) — families together, one iPad.

Apple wants an event to be something happening in the game, with a start and an end: a
challenge counts ("Hide one your family can't find in 3 minutes"), so frame each one as a
challenge rather than an advert.

### 5. The website and the banner
`docs/` is ready (see `README.md` step 3). `docs/images/crew-banner.png` works as the
link preview and as a header for social profiles.

---

## After launch: 30 minutes a week

### Post one "Can you spot it?" — 10 minutes
After a round, tap **Share** on the results with the paint job showing: the game makes a
picture of the room with the chameleon still hidden, captioned in the game's lettering.
Post it (TikTok, Reels, Shorts, a story) with the answer in the next slide or the
comments. This format asks the viewer to *do* something, which is what those apps
reward. Film the reveal too: the seeker's face when they finally tap it.

Or make the same picture on the Mac from any screenshot:

```bash
Tools/build/storeshots card ~/Desktop/spot.png "Can you spot it?" ~/Desktop/post.png
```

A few that work:
- Hide one somewhere absurd (in the fruit bowl, on a pet bed) — "3 minutes, and he
  still didn't find it."
- Squad chaos: five phones, one living room, the scoreboard at the end.
- The paint job time-lapse: a green chameleon painted until it disappears into a
  patterned rug.

### Read the numbers — 5 minutes
App Store Connect → **App Analytics**: *impressions* (how often it's seen), *product page
views*, *conversion rate* (downloads ÷ page views). Low impressions → work on keywords.
Low conversion → change the first screenshot. Change one thing at a time.

### Try a second first screenshot — 10 minutes, once a month
**Product Page Optimization** runs an A/B test on screenshots, icon or video for you.
Test the "Can you spot it?" shot against the Squad colours shot.

### Answer reviews — 5 minutes
Reply to reviews in App Store Connect, especially the unhappy ones; people read the
replies, and a fixed complaint often becomes a raised rating.

---

## Built into the game already

- **Share** on every results screen (pass and play, and Squad), with the download link
  once `AppLinks.appStore` is filled in (see `README.md` step 4).
- **A rating prompt** after a win, from the third finished round on, once per version.
  Ratings move ranking more than almost anything else you can influence.
- **Squad** needs everyone to have the game — every game night recruits players, and
  once the store link is in, the lobby shows a QR code friends scan to get it.

---

## If there's a little money

**Apple Ads** (search ads in the App Store), *Basic* plan: set a monthly budget and a
maximum cost per install; Apple does the rest. Start small (a few dollars a day), in the
country where you and your friends are, and turn it off if the cost per install is more
than you'd pay. It's the most hands-off paid option.

---

## Local first

Launch where your friends are. With the Indonesian listing in `Listing.md`, the game
shows up for Indonesian searches (*petak umpet*, *bunglon*). A game night at the Academy,
a campus club, a class — ten people playing Squad in one room is ten downloads and a lot
of videos.

## Don't

- Name other games (Among Us, Fall Guys…) in the name, keywords or description: it's a
  rejection, and it can get the app pulled.
- Buy reviews or downloads: Apple removes them and can remove the app.
- Ask for ratings mid-game or after a loss.
