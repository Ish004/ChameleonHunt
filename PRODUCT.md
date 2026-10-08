# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Primary (confirmed 2026-09-25): the user's friends at their academy, in their early twenties, playing together for
bragging rights — passing one iPad round, or each on their own iPhone or iPad in a squad game. They play the games
their age group plays together (Fall Guys, Among Us, GeoGuessr); a kids'-game tone in the words puts them off,
but big, fun, over-the-top presentation is welcome. No patience for setup; the next round starts in one tap.

Secondary: people who enjoy the craft of matching colours by hand and want it genuinely hard.

Whoever holds the device was usually just handed it, mid-conversation, often standing up in someone's home.

## Product Purpose

ChameleonHunt is augmented-reality hide-and-seek for LiDAR iPads and iPhones. One person hides a chameleon in the
real room and makes it disappear into its surroundings; the other gets a countdown to find it and tap it through the
camera. In a squad game everyone plays at once on their own device. Success is a round that is fair, sneaky, over quickly, and ends with both players walking over to look at
where it was — and wanting another round immediately.

## Positioning

The chameleon is hidden in the player's actual room and camouflaged from real LiDAR and camera data: the hider paints
it with colours taken from a scan of the spot, or lets it camouflage itself, and real furniture hides it. A board or
screen-only hide-and-seek game cannot do this; the hiding place is the living room itself.

## Operating Context

- Played standing and walking around a room, often in mixed lighting, holding a large iPad in landscape.
- One device, handed between people (no accounts, no network):
  - **Classic** — place one chameleon, walk round the spot so the iPad scans it, paint it in a 3D studio (fingers
    or Apple Pencil, or one-tap Magic camouflage), check it in AR, hand over.
  - **Swarm** — drop up to 10 quickly around the room; each camouflages itself from the camera. The seeker finds
    as many as they can before time runs out.
  - A round is: hide → hand over → 3-2-1 → hunt with a clock → result → play again.
- **Squad** — several devices on the same Wi-Fi (MultipeerConnectivity; no accounts, no server). One hosts a room
  with a four-letter code; the others join from a list of nearby rooms; up to six players. Everyone syncs their AR
  view by pointing at the same spot (ARKit collaborative session), then:
  - **Free-for-all** — everyone hides a few at once, then everyone hunts everyone else's. A point per find, a point
    per chameleon of yours nobody found.
  - **Hider vs all** — one player hides a swarm while the rest look away, then the rest race to find them. The
    hider rotates each round.
  - The host's device keeps the rules and the clock (Core/SquadRules.swift); first tap wins a find.

## Capabilities and Constraints

- Requires an iPad or iPhone with LiDAR; iOS/iPadOS 18+. Without LiDAR only the paint studio demo is available.
- Native SwiftUI + RealityKit/ARKit. Only one RealityKit view can render at a time; camera screens overlay the live
  AR view.
- No difficulty presets (removed at the user's request); the seeker's time and the clue live in a settings sheet.
- The part of a chameleon behind a real object disappears the moment it's covered, even mid-swing, in chunks,
  with a soft fading edge round the cut; mostly covered, all of it goes. It only comes back once the view has
  settled.
- The scan ring only fills for camera pictures that were actually kept; when a scan can't be used, the app says
  why (too fast, too dark, the spot moved, no solid surface…).
- Changing the pose in the paint studio keeps the paint (it follows the body parts).
- Shiny, reflective and glowing surfaces (TVs, mirrors, glossy tables) are the weak spot for camouflage: the app
  warns about them, and on them the chameleon borrows part of the live camera image — more the more the view there
  differs from the scan — but never all of it, so painting still matters.
- The build number is shown in the app for testing (AppVersion.swift) and bumped with every change.

## Brand Commitments

- Name: ChameleonHunt.
- The mascot is the game's own chameleon mesh, rendered as a chunky vinyl-toy (MascotRenderer): big head and eyes,
  bean body, stubby legs, coiled tail. The user likes this chameleon.
- Voice: as few words as possible. A screen says what it is in two or three words; controls say what they do. No
  jokes, puns or exclamation marks in the copy ("too cringe", user, 2026-09-25). No technical jargon (no "LiDAR",
  "mesh", "keyframes") anywhere a player can see it.
- The look is a TV game show: Nintendo polish combined with Fall Guys (the stage, candy colours, chunky keys,
  bouncy big words) and Among Us (each squad player is their own coloured chameleon; spotlight scenes for the
  tense moments) — the user's direction, 2026-09-25. Rejected on the way: cream-and-rounded-cards menus (looked
  AI-made), a moody "trail cam" look (didn't match the cute chameleon), a Nintendo look with speech bubbles and
  jokey copy (too kid-like, too wordy), and a restrained GeoGuessr look (font not liked; not different enough).
- Nothing may look like the system: alerts, menus, pop-ups and the colour picker are all the game's own.
- Type: Lilita One (bundled, SIL OFL; the user approved the download) for titles, buttons, numbers and labels,
  with a thick ink outline on the stage; SF Pro Rounded for sentences.
- The design stays grounded in Apple's Human Interface Guidelines for iPad (user's instruction).

## Evidence on Hand

- The rendered mascot in four poses (standing, curled, lying, clinging) and the app icon, generated from the mesh.
- No testimonials, ratings, press, or player counts exist; do not invent any.

## Product Principles

1. Get to the fun fast: every screen asks for one thing, and "again" is always one tap.
2. The room is the board: nothing on screen should hide the camera for longer than it has to.
3. Fair to the seeker: never a round with nothing to find, never a chameleon that blinks or glitches its position.
4. Few words: the room, the chameleon and the score do the talking; copy stays out of the way.
5. Nothing techy on screen.

## Accessibility & Inclusion

- Readable at arm's length by people standing up; large touch targets (the iPad is held two-handed and passed around).
- Instructions short, icons alongside words.
- Honour Reduce Motion for decorative animation.
