---
name: ChameleonHunt
description: AR hide-and-seek for friends, presented as a TV game show — Fall Guys' stage, Among Us' crew, Nintendo's polish — around a cute toy chameleon.
colors:
  stage-top: "#7D4FFF"
  stage: "#5A2EE2"
  stage-bottom: "#3A1AA4"
  card: "#2C158C"
  card-high: "#4326BC"
  ink: "#1A0B3B"
  ink-muted: "rgba(26, 11, 59, 0.66)"
  paper: "#FFFFFF"
  paper-lip: "#C9BFF0"
  lime: "#8CE04A"
  lime-lip: "#4E9C27"
  sun: "#FFD23F"
  sun-lip: "#D6960A"
  pink: "#FF4FA6"
  pink-lip: "#C11B78"
  cyan: "#3ED3FF"
  orange: "#FF8A3D"
  cherry: "#FF5656"
  text: "#FFFFFF"
  muted: "rgba(255, 255, 255, 0.8)"
typography:
  display:
    fontFamily: "Lilita One"
    fontSize: "72–96px (slams up to 180px)"
    outline: "ink, 7% of size, plus a 7% drop"
  headline:
    fontFamily: "Lilita One"
    fontSize: "44–64px"
    outline: "ink, on the stage only"
  title-on-paper:
    fontFamily: "Lilita One"
    fontSize: "22–34px"
    color: "{colors.ink}"
  button:
    fontFamily: "Lilita One"
    fontSize: "20px (26px large)"
  figure:
    fontFamily: "Lilita One"
    fontSize: "30–32px"
    fontFeature: "tnum"
  body:
    fontFamily: "SF Pro Rounded"
    fontWeight: 700
    fontSize: "Dynamic Type (subheadline–title3)"
rounded:
  chip: "9999px"
  sticker-small: "10–16px"
  plate: "18px"
  card: "22px"
  dialog: "30px"
stroke:
  outline: "3px ink"
shadow:
  sticker: "hard ink, 3–6px straight down, no blur"
  key-lip: "6px darker lip under every key"
spacing:
  gutter: "28px"
  panel: "18–20px"
  stack: "12–22px"
components:
  key-primary: { background: "{colors.lime}", lip: "{colors.lime-lip}", text: "{colors.ink}", height: "52px (66px large)" }
  key-secondary: { background: "{colors.paper}", lip: "{colors.paper-lip}", text: "{colors.ink}" }
  key-found: { background: "{colors.pink}", lip: "{colors.pink-lip}", text: "{colors.ink}" }
  key-ghost: { background: "transparent", border: "2.5px white", text: "{colors.text}" }
  clock: { background: "{colors.sun}", text: "{colors.ink}", height: "54px" }
  hud-pill: { background: "{colors.paper}", text: "{colors.ink}", height: "42px" }
  card: { background: "{colors.card}", outline: "{stroke.outline}", shadow: "6px" }
  plate: { background: "{colors.paper}", outline: "{stroke.outline}", shadow: "4px" }
---

# Design System: ChameleonHunt

**Creative north star: "Tonight's show."** Chameleon Hunt is presented like a TV game show. Fall Guys gives the show: an electric-violet stage with sunburst rays turning slowly behind the star, candy colours, chunky keys that press down into their lip, and big bouncy words on a starburst for the big moments. Among Us gives the crew: in Squad every player is their own coloured chameleon, in the lobby line-up, on the scoreboard, in the spotlight when they hide, and on the podium. Nintendo gives the polish: Lilita One lettering with a thick ink outline and a drop, white stickers with ink edges, and one job per colour.

The words stay few and plain. The fun is in the presentation, never in jokey sentences.

Derived from the shipped code: `ChameleonHunt/UI/HuntKit.swift` (tokens and components), `UI/PhaseViews.swift`, `UI/SquadViews.swift`, `UI/Notice.swift`, `Studio/StudioView.swift` and `UI/DesignSystem.swift`.

## Colour

One job per colour:

| Token | Hex | Job |
|---|---|---|
| lime | #8CE04A (lip #4E9C27) | **Go.** The primary key, what's chosen, "ready". It's also the chameleon's own green. |
| sun | #FFD23F (lip #D6960A) | **Time and first place.** The clock, the room sign, the winner's block and crown, the hint (the key once it unlocks, and what it says). |
| pink | #FF4FA6 (lip #C11B78) | **Found.** The FOUND burst, found tallies, the seeker's spotlight. |
| ink | #1A0B3B | Every outline and hard shadow, text on stickers, and the dark of the spotlight scenes. |
| paper | #FFFFFF (lip #C9BFF0) | Stickers: secondary keys, anything over the camera, dialogs, the studio's controls. |
| stage | #7D4FFF → #5A2EE2 → #3A1AA4 | The menus' background, with rays. |
| card | #2C158C / #4326BC | Grouped controls on the stage. Unchosen chips use card-high. |

- **Players** own lime, sun, pink, cyan, orange or cherry, in join order. Each colour comes with a matching chameleon tint (`Hunt.playerTints`, rendered by `MascotRenderer`). In that role a colour means "this player", not its job above.
- **In a squad, found is the finder's colour, not pink.** A found chameleon turns solid in its finder's colour, the FOUND burst is in your colour, and the feed pill is in the finder's colour; at the end the unfound ones light up in their hider's colour, so every chameleon shows who got its point. One device (Swarm, Paint & Hide) keeps pink: there's one seeker.
- **A colour is never left to explain itself** (v6.8, v6.9). Playtesters didn't know why found chameleons were different colours, so each lit-up chameleon in a squad carries a name tag in the same colour saying who found whose ("Ben found Cy's", "You found Dee's", "Ana found yours") with a magnifier, or, for one nobody found, "Cy's · not found" with a crossed-out eye. (v6.8's tags gave only the finder's name, which read as "whose" as often as "who".)
- **White means yours.** Your own chameleons are hidden during a squad hunt; with **Show mine** on they're see-through white with a white "Yours" tag — never a player colour, so they can't pass for a find.
- **Mode tiles** on the home screen (lime, orange, cyan) are identity colours only.

## Type

- **Lilita One** (bundled, SIL OFL) for titles, buttons, numbers and labels.
  - On the stage it's `ShowText`: the real letter outline stroked in ink at 7% of the size, plus an ink drop of the same amount.
  - On paper stickers it's plain ink.
  - Headlines are capitals and wrap onto two lines before shrinking (`Headline`).
  - The logo and big slams tilt −3° to −4°.
- **SF Pro Rounded, bold** for sentences: detail lines, dialog messages, hints.
- Everything scales with Dynamic Type. The outlined lettering is capped at 1.3×.

## Surfaces

- **Sticker** (`.sticker`): a flat fill, a 3pt ink edge, and a hard ink shadow 3–6pt straight down. There is no blur anywhere.
- **Card** (`.huntPanel`): a violet sticker on the stage, for grouped controls (settings sections, the lobby rules).
- **Plate** (`.huntPlate`): a white sticker. Everything over the camera sits on one, so it reads on any room.
- **Keys** (`HuntButtonStyle`) sit 6pt above a darker lip, with a flat gloss band across the top.
  - Pressing pushes the key down into its lip, with a light haptic.
  - Primary is lime, secondary is paper, `.found` is pink.
  - Ghost is a white outline for quiet options such as "Practice painting" and "Back to painting".
- **IconButton**: a round white key with one symbol (close, back, pause, help, settings).
- **Chip**: lime and pressed in when chosen, violet otherwise.

## Scenes

- **The stage** (`HuntBackground(focus:)`): the violet gradient, 9 rays at 5.5% white turning once every few minutes, and a soft glow behind the focus.
- **The spotlight** (`SpotlightStage`): the ink stage with one beam coming down onto a floor pool. It's used for SEEKER'S TURN (pink) and LOOK AWAY (in the hider's colour, with their chameleon in the light).
- **ALL HIDDEN** (squad, once yours are placed): the violet stage, the hiders lined up — ticked when done, an ink silhouette with hopping dots while still hiding — "Waiting for Ben and Dee", the clock.
- **HUNT** (squad, the first 4 seconds of the hunt on every device): HUNT slams on a lime burst, "Find all 9" / "Find Cy's 8" / "They're after yours", the crew you're hunting, a sticker in your colour ("What you find turns green"), then 3-2-1 slams on sun. The clock starts after it.
- **Camera screens** have no background:
  - top left: the way out, then a white plate saying what to do in 2–3 words;
  - bottom: one big lime key;
  - hints: white pills.

## Components (HuntKit.swift unless noted)

| Component | Use |
|---|---|
| `Headline`, `ShowText` | Screen titles and logo lettering on the stage |
| `Slam(burst:)` | FOUND, 3-2-1, SYNCED, YOU WIN: lands at 1.8× and springs to 1× on a starburst |
| `Stat` | A number on a coloured tile (sun for time, pink for found, paper otherwise) |
| `ClockPill` | The clock: sun sticker, Lilita digits, beats once a second in the last ten |
| `HUDPill` / `CamHint` | Short notes and counts over the camera |
| `FoundTally` | Little chameleons, pink when found, ink silhouettes when not; on a phone with more than four, one pink chameleon and "2/6" |
| Difficulty chips (PhaseViews.swift, `DifficultyPicker`) | Swarm's SEEKER'S TURN: Easy · Medium · Hard as `Chip`s under the stats, the chosen one lime, and one line under them saying what it means. Sideways on a phone the screen goes to two columns without the chameleon, the spotlight on the title. Squad's lobby has the same chips as the host's last choice, with the same line; guests get it as one line of the summary ("Hard · a miss costs 5 s") |
| Penalty flash | A cherry sticker, "−5 s", tilted, beside the clock for a second when a miss costs time (Swarm, Medium and Hard), with a warning haptic. In Squad the hunt's bottom line becomes "Missed · wait 5 s" with a cherry hand, counting down |
| `HintKey` | The hint, bottom right of every hunt: a plain sun key, "Hint". It asks first (a `Notice`; "Keep looking" is the main key), and that card is where the cost is said in full: "For the rest of this hunt, each one you find earns half the coins." (v7.4 also had a HALF COINS tag on the key; it was removed as clutter, since the card already says it before anything is spent) |
| `CoinIcon`, `CoinPill`, `CoinsEarned` | The coin (sun, ink edge, darker ring). Over the camera, bottom left: this hunt's coins on a paper pill that pops as it climbs, with a cherry HALF tag once the hint is on. On the results: a sun sticker "+110" with one line under it (what it was for, or what you have); on a phone held sideways just the sticker, in the stats row |
| Skins shop (SkinShop.swift) | A full page like Settings: the coins on a paper sticker, then a grid of cards (the chameleon in the skin, its name, one key). The key is the price on sun, "Wear" on paper, or a lime Wearing tag; a skin out of reach isn't a key at all, just its price and "580 more". Buying asks first. One line at the bottom says skins are looks only |
| Hunt menu (SquadViews.swift) | The squad hunt's top-left key (three lines) opens a `DropCard`: GAME, a **Show mine** switch (`PaperToggleStyle`) with one line under it, then **Give up** and **Leave game** as paper keys. Both ask first (a `Notice`; "Keep looking" / "Stay" is the main key). In pass-and-play, Give up is on the pause screen |
| `ChameleonTagLayer` (SquadViews.swift) | Name tags over chameleons in a squad: a small sticker, Lilita text, in the finder's colour with a magnifier ("Ben found Cy's"), the hider's with a crossed-out eye ("Cy's · not found"), or white with a person ("Yours") |
| `Avatar` | A player's chameleon (front view, their tint) on a white token |
| `CrewLineup` | The lobby line-up: chameleons with name plates in their colour, crown on the host |
| `NameField` | The editable name, on a paper sticker that turns sun while editing |
| `LoadingDots` | Three hopping dots, used instead of the system spinner |
| `RowOrColumn` / `RowOrColumnLayout`, `ActionBar` | Bars that fit a phone: a row if it fits, otherwise stacked, big action on top; stacked keys share one width (`huntKeysFill`) |
| `FlowLayout` | Chips that wrap onto more rows (settings, the host's lobby choices) |
| `SpotlightStage` + `.spotlightSubject()` | The dark stage; the beam finds the marked view wherever the layout puts it |
| `Confetti` | A win only |
| `Notice` / `NoticeView` (Notice.swift) | Every question and message: a white sticker card with a symbol tile, a Lilita title, one sentence, at most two keys |
| `DropCard` (DesignSystem.swift) | The studio's drop-downs (pose, options, colour), used instead of popovers and menus |
| `ShareCard` (ShareCard.swift) | The shared picture: the camera's view of the room, and a violet strip with the headline in outlined Lilita ("Can you spot it?", "Found in 0:49") and the mascot. The share sheet itself is the system's — the one system surface we use, because it's where the player's apps and friends are |
| Reconnecting banner (SquadViews.swift) | A sun sticker with hopping dots near the bottom: "Reconnecting to Ana". The game carries on under it |
| `ColourPanel` (StudioView.swift) | The game's colour picker: shade square, hue bar, recent colours, "Pick from the room" |

## Play

The home chameleon performs and responds: its colour washes up from the feet with a bright edge (the game's own
blend), tap makes it do the trick or pop back out, it breathes while idle, and the stage tilts with the device
(Home Screen parallax). A white "Tap me" sticker shows until the first tap. Cheap by design: two pictures and a
few transforms (a 36-frame drag-spin was tried and dropped for lag). In the studio, Magic camouflage is a secondary (paper) key beside the
big lime Done: a helper never outranks the way forward. Paged screens (How to play) swipe only their content; the
dots and the button stay fixed.

## Sound

Made in code (`Core/SoundSynth.swift`), small and bright like the look: sine tones with
quick envelopes and a little noise, the way toy and chiptune sounds are built.

| Moment | Sound |
|---|---|
| Any key or chip going down | A very quiet click, in time with the key pressing into its lip |
| A chameleon dropped | A plop |
| FOUND (yours) | A two-note bell, rising |
| Someone else's find | One softer, lower bell |
| 3-2-1, and the last ten seconds | A woodblock tick, with the clock's beat |
| The hunt starts | A bright two-note "go" |
| A win (or a draw you're in) | A short C–E–G fanfare |
| Time's up / someone else won | A gentle falling phrase — no sad trombone |
| Someone joins the lobby | A bubble pop |
| Poking the home chameleon | A springy boing |

It follows the ring/silent switch, mixes with music, and has a Sound effects switch in
Settings. Nothing is longer than about a second.

## Motion

- **Slam.** Scale 1.8 → 1 on a spring (response 0.34, damping 0.52), tilted −4°.
- **Keys.** Keys, chips and cards press down into their lip (spring 0.18/0.6).
- **Lobby and podium.** Lobby chameleons pop in (scale 0.5 → 1). The podium blocks rise. The scoreboard rows arrive from last place up, 0.15s apart.
- **Dialogs.** A Notice bounces in (0.7 → 1).
- **The stage.** The rays turn slowly.
- **Reduce Motion.** The rays and dots stand still. Slams and dialogs fade in. The clock dims instead of beating. Confetti is skipped.

## Home and capability

The home is a title screen: logo (tilted, outlined), the chameleon on its disc in the skin being worn (tap it; it
does its trick), the coins as a paper key beside the practice-painting icon (it opens the skins shop), and the
two main games as keys with one line each — **Squad** (lime, "Everyone on their own phone") and **Swarm** (paper,
"One phone, passed round") — and under them **Paint & Hide** as a smaller outline key (with a NEEDS LIDAR tag where
it's locked). Help, settings and practice painting are round icon keys in the corners. Nothing else: no tagline, no
headings. (Until v6.8 the keys were Pass & Play and Squad, with Paint & Hide and Swarm on a second screen; Paint &
Hide was the main game. Playtesting found Squad and Swarm the ones people wanted, so they're one tap from home.) On a
phone the keys stack; on its side they sit right of the chameleon. The Squad lobby shows one sticker saying
which game the room gets: "Full game" (lime), "Ben maps the room for everyone" or "Lite · flat surfaces only" (both
paper; sun and the player colours already have jobs).

## Host and guests

Only the host gets controls in the lobby: mode cards (equal height), chips, **Start**. A guest gets the same card as a
read-only summary — the mode on a lime icon tile with its one line, then `Stat` tiles for how many, the hide time
and the hunt time, then the host's chameleon with "Waiting for Ana" and `LoadingDots` — with nothing that looks
tappable (Among Us and Jackbox do the same). Guests feel a tick when the host changes something. Wherever someone
waits for the host, the host is named ("Waiting for Ana", "Time's up · waiting for Ana").

## The hunt's keys

Every hunt keeps the camera clear: the way out (pause, or the squad menu), the clock and the count top left, the
scores top right, one line of what to do ("Tap what you spot · closer is easier") and the **Hint** key bottom right
(when hints are on and not yet used). Giving up and leaving are one step away, in the menu or on the pause screen
(v6.9; they used to sit on the bottom bar). A seeker who gave up sees "You gave up · the rest are lit up".
Chameleons still to be found fade with distance (clear within 1 m, faintest from 4 m, more gently when they're
spread over a big space); the line says so because players otherwise think it's a bug. If the device loses its
place in the room (put down, camera covered), the chameleons are hidden and the line under the clock reads "Look
around · finding the room again" until it has it back; nothing is ever drawn somewhere it isn't.

## A phone on its side

Every screen fits an iPhone in landscape (height under 500pt). Home puts the chameleon left and the name and keys
right; Seeker's Turn, Look Away and Paused put the chameleon or title beside the rest; squad results put the board left
(scrolling) and the result and keys right; the lobby's columns start at the top; the studio's brush bars sit side by
side, its tools fold into two columns, and its colour card puts the shade square beside the controls (the rails and
bottom bar step aside while a card is open). A four-way tie skips the podium: three blocks can't show it.

## Copy

- A screen says what it is in two or three words ("SPOT CHECK", "LOOK AWAY", "SYNC UP").
- Buttons say exactly what they do ("Show paint job", "Show in pink", "Done painting", "Finish scan", "Clear all", "Keep scanning"). The same action has the same words everywhere: Spot Check and the results both say "Show in pink"; going back is "Back to painting" or "Back to hiding".
- Detail lines are one short sentence. There are no jokes or puns in sentences.
- Exclamation-style energy lives only in the slams.
- No jargon: no "LiDAR" except where a device requirement must be named, and no "mesh" or "keyframes".
- Scan problems name the real reason: "Too fast", "The spot moved", "Can't see the surface".

## Accessibility

- **Targets.** Keys are 52/66pt, icon keys 52pt, chips 46pt, toggles 48pt, studio rail buttons 72×60.
- **Labels.** Outlined lettering carries an accessibility label and the header trait. Stats and board rows read as one element. The clock reads "n seconds left".
- **Modals.** Dialogs and drop cards are marked modal.
- **Dynamic Type** throughout. Reduce Motion is handled as above.

## Do's and Don'ts

**Do**
- Take colours, radii and outlines from `enum Hunt`, and give every sticker the ink edge and a hard shadow.
- Put the way out first, top left, on every camera screen. Pin full-page close buttons top right.
- End a screen with one big lime key.
- Show players as their chameleon, in their colour.
- Ask questions with a `Notice` via `@Environment(\.showNotice)`.

**Don't**
- Put a `ForEach` or a clock (`TimelineView`, `Countdown`) inside `ViewThatFits`: SwiftUI can measure the hidden choice on its background render thread and Swift 6 stops the app. Use `RowOrColumnLayout`, `FlowLayout`, or choose from the size.
- Give one screen two ways back: the way out is top left.
- Use a system alert, confirmation dialog, menu, popover, colour picker or spinner.
- Use blur shadows, glass or gradients (the stage gradient is the one exception).
- Use lime, sun or pink for anything but go, time/first place and found (players and mode tiles aside).
- Write jokes, puns or chatty sentences. Speech bubbles are out.
- Make a target smaller than 44pt.

## Rejected directions

1. Cream menus with rounded cards: they looked AI-made.
2. A trail-camera theme: it didn't match the cute chameleon.
3. Nintendo with speech bubbles and jokey lines: too kid-like and wordy. Its Lilita lettering was kept.
4. GeoGuessr restraint with SF black italic: the font wasn't liked, and it wasn't different enough.

<!-- Provenance: v6.7 adds Sound, ShareCard and the reconnecting banner (written from Core/SoundSynth.swift, UI/ShareCard.swift, UI/SquadViews.swift; built while Xcode's licence was unaccepted, so not captured). Updated for v6.5 from HuntKit.swift, SquadViews.swift, PhaseViews.swift, StudioView.swift and the iPad Pro 13" / iPhone 17 Pro captures in .impeccable/review/v65/ (portrait, landscape and the largest standard text size), after the finish review. Originally written from the v6.0 build (HuntKit.swift, PhaseViews.swift, SquadViews.swift, Notice.swift, StudioView.swift, DesignSystem.swift) and the iPad Pro 13" Simulator captures in .impeccable/review/v6/. No shipping rasters were generated: the mascot, crew and tally chameleons are rendered at runtime from the game's mesh by MascotRenderer (MascotImage); Lilita One is the SIL OFL font the user approved downloading (Fonts/OFL.txt). -->
