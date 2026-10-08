# ChameleonHunt

AR hide-and-seek for iPads and iPhones — best with LiDAR, playable without — inspired by *Meccha Chameleon*. Hide a chameleon in the real room,
make it disappear into its surroundings, and see who can find it.

The build number is in settings (`AppVersion.swift`). If it doesn't match what you expect, the device is running an
older build — bump it with every change so "it didn't work" can never be confused with "it didn't install".

Three ways to play. Since v6.8 the home screen leads with the first two:

- **Squad** (the main game): everyone hides and hunts at once on their own phone or iPad, same Wi-Fi, with a live
  leaderboard (see *Squad* below).
- **Swarm**: one phone or iPad passed round. Drop up to ten around the room; each one camouflages itself; the seeker
  finds as many as they can.
- **Paint & Hide** (was "Classic", and until v6.8 the main game): place a chameleon, scan the spot, paint it in a 3D
  studio until it disappears, hand over. Needs LiDAR.

## With and without LiDAR

LiDAR (Pro iPhones and iPads) maps the room in 3D. It's what lets real furniture hide a chameleon, lets you hide one
on any surface, and gives Paint & Hide its scan to paint from. The app checks for it and adapts:

| | With LiDAR | Without LiDAR |
|---|---|---|
| **Paint & Hide** | Full | Locked ("Needs LiDAR"): the painting is done from a 3D scan of the spot |
| **Swarm** | Full | **Lite**: chameleons go on the flat surfaces ARKit finds, and only people walking past hide them |
| **Squad** | see below | see below |
| **Practice painting** | Yes | Yes |

**Without LiDAR, flat surfaces hide chameleons** (v6.3). A phone without LiDAR has no depth sensor, but ARKit still
finds flat surfaces — tables, walls, counters, the floor. Those are now used as blockers: a chameleon under a table
or round a wall hides, chunk by chunk, just like with LiDAR. What it can't do is the sofa, the lamp or a person's
leg (people do hide them, from the camera image). In a squad, the LiDAR device's room map adds the rest.

**Where it can't go, you still see it** (v6.5). Before a phone without LiDAR has found a surface, placing showed
nothing at all, so it wasn't clear anything was happening. Now a faded grey chameleon floats a little ahead of the
camera until there's somewhere to put it, then turns solid on the surface; the hint says "Sweep slowly over a floor
or table".

**Squad adapts to the whole room** (`SquadRules.roomSupport`, shown in the lobby):

- **Everyone has LiDAR → the full game**, with no trade-offs: every device sees through its own sensor.
- **Some do → one device maps the room for everyone.** The host if it has LiDAR, otherwise the first player who
  does. It sends its 3D map of the room two seconds into hiding, again whenever it has grown, and at the hunt (packed to a few
  hundred kilobytes, `Core/RoomShare.swift`, relayed through the host like everything else). The phones without
  LiDAR use it to hide chameleons on any surface, and to have furniture hide chameleons from them. They work out
  what's in front by tracing rays through the map, chunk by chunk, just like the LiDAR devices do with their depth
  sensor. The lobby says "Ben maps the room for everyone"; the mapper gets a reminder to walk around.
- **Nobody does → Lite**: flat surfaces only; only people hide chameleons. Everyone's on the same terms, so it's
  still fair.

**What each device does in a mixed squad** (say an iPad Pro and two phones without LiDAR):

| | iPad (LiDAR) | Phone without LiDAR |
|---|---|---|
| **Where it can hide one** | Any surface: floor, shelf, sofa arm, a wall | Any surface of the iPad's room map once it has arrived (a couple of seconds into hiding). Until then, and anywhere the map doesn't reach, the flat surfaces the phone has found itself |
| **What hides a chameleon from it** | Everything real, from its own depth sensor | Things in the room map (furniture, walls), flat surfaces it found itself, and people |
| **Seeing the others' chameleons** | Yes. A phone's chameleon is set down onto the iPad's own scan of the surface it's on (v6.8) | Yes. It sits where the hider put it |

Everyone's chameleons are shared as places in the room, measured from the host's reference point (see v6.8), so
it doesn't matter which device hid which: every device can find every chameleon. Each chameleon's camouflage is
sent to everyone when the hunt starts, and from then on each device keeps it matching the room from its own camera.

The app now runs on iPhones as well as iPads (it used to be iPad-only), so friends can join a squad from their
phones. Every screen was checked at phone size. Rows of buttons stack, the scores drop under the clock, big words
shrink to fit, and the paint studio's bar splits into two rows.

## Who it's for

The user's friends at their academy, in their early twenties, playing together for bragging rights. That decides a
lot: very few words on screen and no jokes in them, no jargon anywhere a player can see it, finger painting by
default with a one-tap **Magic camouflage**, and "again" always one tap away. People who enjoy matching colours by
hand come second.

## Design

**A TV game show.** Chameleon Hunt now takes after the party games the players (friends in their early twenties)
actually play together: **Fall Guys** for the show, **Among Us** for the crew, and **Nintendo** for the polish.
Four looks were tried and rejected on the way here: warm cream menus with rounded cards ("looks AI-made"), a moody
trail-camera theme ("doesn't match the cute chameleon"), a Nintendo look with speech bubbles and jokey lines ("too
kid-like", "cringe"), and a restrained GeoGuessr look (the font wasn't liked and it didn't feel different enough).
What stayed from those: the short, plain copy, and the Lilita One lettering the user liked. The kit is
`UI/HuntKit.swift`:

- **The stage** (Fall Guys). Menus sit on electric violet with sunburst rays turning slowly behind the chameleon.
  Buttons are chunky stickers sitting on a darker lip that press down into it, with a haptic. Big moments get big
  words on a starburst that bounce into place: 3-2-1, FOUND, SYNCED, YOU WIN, with confetti for a win.
- **The crew** (Among Us). In Squad, every player is their own coloured chameleon: lined up in the lobby under the
  room sign, as their token on the scoreboard, standing in the spotlight when it's their turn to hide (everyone else
  gets LOOK AWAY), and on the podium at the end with the winner wearing the crown. The tense one-device moment,
  SEEKER'S TURN, gets the same dark stage and spotlight.
- **The polish** (Nintendo). Lilita One lettering with a thick ink outline and a drop; white stickers with ink edges
  and hard shadows for anything over the camera, so it reads on any room; one job per colour: lime is go, sun
  yellow is time and first place, pink is found, and players own their colour.
- **Few words.** A screen says what it is in two or three words; buttons say exactly what they do ("Show paint
  job", "Done painting", "Finish scan", "Clear all").
- **Nothing looks like the system.** Every question is the game's own card (`UI/Notice.swift`), not an iOS alert;
  the paint studio's pose menu, options and colour picker are the game's own drop-down cards; **Settings** is a
  full page of the same stickers and chips.

It stays grounded in Apple's Human Interface Guidelines: touch targets of 44 points and up, Dynamic Type (the
lettering scales too, capped at a third larger so it still fits), SF Symbols, the safe area, and Reduce Motion
turning the rays, bounces, confetti and the clock's beat into stillness and fades.

**The home screen is a title screen** (v6.4), the way the best-loved party games do it (Among Us, Fall Guys,
Crossy Road): the logo, the chameleon doing its trick in the middle, and the two main games as big keys with a line
each — **Squad** (everyone on their own phone) and **Swarm** (one phone, passed round) — with **Paint & Hide** as a
smaller key under them (NEEDS LIDAR where it's locked). Help, settings and practice painting are small round buttons
in the corners. (v6.4–v6.7 had Pass & Play and Squad here, with Paint & Hide and Swarm a screen further in.) The
earlier home, with a tagline, group headings, three cards with a line each and a text button, was too much to read
at once.

The chameleon's trick: the disc's colour washes up it from the feet, with a bright edge where it's changing (the way
chameleons blend in during the game), until only its eyes are left; then it hops back to green on a new colour. Tap
it and it does the trick on the spot, or pops back out. It breathes while it waits, and the stage tilts a little as
the device does, like the iOS Home Screen's parallax.

**The chameleon is a toy, not a specimen** — big head, big eyes, a bean of a body, stubby legs and a thick coiled
tail — and `MascotRenderer` draws it from the game's own mesh, in its own colours or blended into another.

**The studio** keeps the layout of iPad painting apps (Procreate above all). A finger on the chameleon paints; a
finger dragged anywhere else turns the view. With "Only Draw with Apple Pencil" switched on in iPadOS it starts in
Pencil mode. The brush goes from 0.15 cm to 8 cm (the size bar is squared, so the fine sizes get as much room as
the big ones), **Clear all** wipes the paint (undoable), and **changing the pose keeps the paint**: every pose is
built from the same thirty body parts, so each bit of paint is carried to the same place on the same part — the
head's paint stays on the head, a stripe down the tail stays on the tail wherever it's curled to
(`Core/PoseTransfer.swift`).

## Paint & Hide and Swarm

**Paint & Hide.** Place it (sitting, napping, sunbathing, or climbing a wall — pinch to resize, twist to turn), walk round
it so the iPad can scan the spot, paint it in the studio until it disappears, check it in the room, hand over.

**Swarm.** Drop up to ten around the room. There's no reticle: the chameleon itself, in its bright toy colours,
follows where you aim, and the wide **Drop** button puts it down, facing a random way and (on a floor or shelf) in a
different pose from the last. As it lands, the room's colours wash over it from the feet up. The next one waits off
stage until that's finished, so you always see each one disappear. It keeps camouflaging itself from the camera
while you walk around (see *Living camouflage*). Hand over; the seeker picks **Easy, Medium or Hard** (see v7.0) and gets the set time plus a few seconds for each
chameleon after the first. Found ones turn pink; when time runs out the rest light up.

## v7.4: coins, skins, a hint with a price, and nobody left a chameleon short

**Coins** (`Core/Coins.swift`, `App/Wallet.swift`). The game's one currency, earned by playing and kept on the
device. Three things borrowed from games that do this well:
- *Quicker pays more, but slow still pays* (the shape of [Kahoot's scoring](https://support.kahoot.com/hc/articles/115002303908)):
  a find pays the full amount the instant the hunt starts, sliding to half by the end.
- *Earned currency buys looks, never an edge* ([Among Us's Beans](https://among-us.fandom.com/wiki/Beans), Fall
  Guys' Kudos, Crossy Road's coins): coins buy skins and nothing else.
- *A cost is fixed, applied once, and printed on the button* before it's pressed.

| | Easy | Medium | Hard |
|---|---|---|---|
| A find, at the start of the hunt → at the end | 20 → 10 | 30 → 15 | 50 → 25 |

Paint & Hide's one chameleon pays 40 → 20. In a squad, each of your own that nobody found pays 10 at the end of the
round, and coming top (or level top) pays 30. A guest's find pays when the host has counted it.
- During a hunt the coins so far sit bottom left and pop with each find. The results show what the round paid
  ("+110" and, in a squad, "60 finds · 20 never found · 30 top") and what you have.

**The hint, any time, for half the coins.** There's no waiting for it any more (it used to unlock near the end, or
halfway in a squad). The key is there from the start and asks first: "An arrow points to the nearest one. For the
rest of this hunt, each one you find earns half the coins." Once it's on, the coin count wears a HALF tag for the
rest of the hunt. (v7.4 also printed HALF COINS on the key itself; v7.5 took that off — the card says it, and the
key is a plain "Hint".) Settings (one device) and the host (squad) can still switch hints off altogether.

**Skins** (`Core/ChameleonSkin.swift`, `UI/SkinShop.swift`). Sixteen: Classic (free); eight colours at 150;
Bumblebee, Tiger, Zebra, Ladybird and Strawberry at 400; Gold at 1,000 and Rainbow at 1,500. The coin key on the
home screen opens the shop: every skin on a card, with one key that says what tapping does (the price, "Wear", or
a Wearing tag), and for one you can't afford yet, how many more coins it takes.
- A skin is the chameleon's own colours: on the home screen, following your aim while you hide, and as it lands
  before the room's colours wash over it. Once it has blended in, every skin is the room's colours: **skins change
  nothing about how well a chameleon hides**, and in a squad nobody else sees yours.
- Patterns are painted from the chameleon's shape (`MascotRenderer.Pattern`), so they sit the same in every pose.
  `Tools/build/preview <dir> --skins` renders them all.
- Different *shapes* (hats and the like) aren't in this version: the shape feeds the texture layout, the poses and
  the pieces that fade behind furniture, so it's a job of its own.

**Squad: everyone hides the same number.** In testing one player got three of four down before time ran out, and
lost the points for the fourth. Now, when the hide clock runs out:
- anyone short has the rest **placed for them**: "Time's up · placing the rest where you point", each one dropped
  wherever the camera is pointing as soon as that's somewhere a chameleon can go, the next once it has blended in;
- the host waits for that (four seconds a chameleon, plus six) before the hunt starts;
- stopping short with "Done hiding" is gone when there's a clock.
- The host can also choose **No limit** for hiding: the hunt starts when everyone's done. (Only then does "Done
  hiding" let someone stop short, in case they can't find anywhere for the last one.)

**To check on devices:** the skin on the aim and the drop; auto-placing at time-up on a phone without LiDAR
(it needs a surface to be found); whether 20/30/50 a find feels right against the prices.

## v7.3: the room's own colours, measured; and the drop that wasn't there

**v7.2's colour fix overshot.** It stopped RealityKit tone-mapping the chameleons' textures, which had drawn them
7–13% darker than the room; without it they were drawn about 10% *brighter* (a chameleon over carpet shown at 201
was drawn at 224, measured from the next round of screenshots). Pale ghosts instead of dark blobs, and easier to
spot than ever. Neither way of drawing a texture shows it as the camera picture's own colour, and nothing documents
what either does. So the game no longer assumes:

- **It measures, on the device** (`ARSessionController.calibrateColours`). Once a round, as soon as tracking is
  steady, it shows a strip of eight known greys for a fraction of a second along the very bottom edge of the camera
  view, drawn exactly as a chameleon is, takes a picture of what the view shows, and reads the strip back. It also
  compares the camera picture as shown with the camera's own pixel values at a grid of points.
- **From that it works out what to store** (`Core/DisplayCurve.swift`): for each colour wanted on screen, the
  texture value that shows as it. Every chameleon's texture goes through that table on its way to the GPU
  (`ChameleonActor.uploadSkin`); what the chameleon has learned and what's sent to other players stays in the
  camera's colours.
- **A reading is only used if it makes sense**: a grey ramp that climbs, and that agrees with what the screenshots
  showed for bright greys (±15%). Otherwise it tries again, up to five times a round.
- **Until a reading succeeds**, the curve fitted to the four chameleons measured in the screenshots is used (a
  stored value t shows as about 255·(t/255)^0.48), which lands them within about 2% of the room on those surfaces.
- The studio is as it always was: its paint and its scanned room are both drawn RealityKit's default way, so they
  agree with each other.
- **Debug info** (Settings) has a Colours line: "measured: 40→… 136→… 232→… · feed shown ×…", or why not.
  *Debug: measure colours* off uses the fitted curve only.

The tell and the levels of v7.2 are unchanged: on top of a true match, Hard is drawn 1.3% off it from a step away.

**"I tap Drop, the count goes up, and nothing's there."** After Back to hiding. On SEEKER'S TURN the camera had
been covered or pointed at nothing for a few seconds, so the device had started finding its place in the room again
(v7.2). Back to hiding didn't wait for that: placing still found a surface (ARKit can estimate one without knowing
where it is), the drop was accepted, and the new chameleon was created hidden, as every chameleon is while tracking
is lost. Earlier builds had the same hole after any interruption.
- A drop is now refused, and the aim preview shows as not placeable, unless the dropped chameleon can be shown.
- Back to hiding leaves a search for the room running, and the screen says "Look around · finding the room again"
  until it's found.
- Back to hiding after some were found un-finds them.
- The device now has to be blind for 3 s (was 2.5) before it searches for the room again.

## v7.2: darker than the room, vanishing on a drop, floating after a pause

Three bugs from playtesting Swarm on Hard, and a retune. All of it is in the code Swarm and Squad share.

**Chameleons were darker than what they stood on.** Sometimes a hunt on Hard was properly hard and sometimes the
same hiding places were easy, because the chameleons showed as darker patches; on a white desk they were grey
blobs. Measured from two playtest screenshots: every chameleon was darker than the surface beside it by about the
same factor, with its tint intact: 7% on a mid-grey carpet, 10–13% on a white desk.
- Cause: RealityKit puts everything it draws through tone mapping, unlit materials included, unless told not to,
  and tone mapping darkens bright colours most. The camera picture behind isn't tone-mapped. A chameleon's texture
  is made of colours sampled from that picture, so it was always drawn darker than the thing it was copying. A busy
  carpet hid a 7% patch; a plain desk didn't hide 13%.
- Fix, as shipped in v7.2: draw chameleon textures without tone mapping (`UnlitMaterial(applyPostProcessToneMap:
  false)`). **That overshot**: they came out too bright instead. v7.3 keeps the untone-mapped drawing and measures
  what it does, so the colours stored are the ones that show right.

**The tell.** With exact colours, a chameleon on a plain surface would be truly invisible. So each level now draws
it a chosen amount off a perfect match (darker on anything but near-black, where it's lighter), more right next to
it. `HuntDifficulty.tell`, applied where the texture is composed (`LiveSkin`), never to the paint itself:

| | Easy | Medium | Hard |
|---|---|---|---|
| Off the match from a step away or more | 4.5% | 2.6% | 1.3% |
| Right next to it (within 35 cm) | 7.5% | 5.8% | 4.5% |
| Catches up with a new view in about | 0.8 s | 0.4 s | 0.2 s |
| Camouflage (phone / 13" iPad) | 0.64 / 0.77 | 0.74 / 0.87 | 0.84 / 0.95 |
| Fully clear within · faintest, from | 1.0 m · 20%, 4.0 m | 0.8 m · 15%, 3.8 m | 0.65 m · 12%, 3.8 m |

- **Catching up** is new: what's behind a chameleon changes with every step the seeker takes, and one that's slow
  to follow shows as a patch of the old view, worst on a plain table with something behind it. Harder levels update
  more often and move further each time; the nearest chameleons are updated first.
- Easy is a little easier than it was and Hard a little harder; Hard stays visible from a little further away.
  (This table replaces the camouflage and distance rows of v7.0's.)

**A dropped chameleon vanished, with no melting in.** Every chameleon was hidden the instant tracking was anything
but perfect, and for most of a second after. ARKit reports "moving too fast" or "not enough detail here" (a plain
white desk, close up) for a frame or two all the time while still knowing where it is. Now those states hide
nothing unless they last over a second during a hunt, and nothing at all while hiding (`Core/TrackingGuard.swift`).

**After a pause with the iPad put down, the chameleons were floating in the air.** With its camera covered ARKit
can't see, and doesn't notice being lifted off the floor; when it can see again it carries on from where it thought
it was and draws everything a metre out. Fading the chameleons while it was blind (v6.8) hid the wrong moment.
- When hiding ends, when a hunt is paused, and every 20 s during a hunt while all is well, the game saves ARKit's
  map of the room (`captureHuntMap`).
- If tracking is lost for more than 2.5 s during a hunt (long enough to have been moved), the session starts again
  from that map (`refindRoom`). ARKit then tracks nothing until it has matched the camera's view against the map;
  when it has, the room's coordinates are the saved ones and every chameleon is back on its spot.
- Meanwhile the chameleons stay hidden, taps don't count, Swarm's clock holds, and the screen says "Look around ·
  finding the room again".
- The same in Squad, on each device by itself.

**To check on devices**
- Hard on a white desk and on a carpet: the chameleons should be the room's colour, a touch darker, and plainer
  from a hand's width away (v7.3).
- Drop one on a plain desk: it should melt in, not vanish.
- Pause a hunt, put the device face down for a minute, pick it up, resume: "Look around…", then the chameleons
  back in place. If it never finds the room, say so: the fallback is the pause menu.
- Debug info (Settings) now has a line for all of this: hunt map saved or not, hidden or shown, exact or
  tone-mapped colours, the level.

## v7.1: Swarm and Squad hide chameleons the same way

An audit of the two games side by side. They were always built on the same parts — one stage (`AR/ScatterStage`),
one chameleon (`AR/ChameleonActor`), one visibility loop (`ARSessionController.updateActors`) — but four things
had drifted apart. All four are fixed, so the only differences left are the ones multiplayer needs.

**The same in both, from the same code**
- Dropping: the same function, size (0.8), random facing, pose that changes each drop, colour sampled from the
  spot, and the melt-in.
- While hiding: living camouflage at full strength, kept for good.
- The hunt: the same strength for the screen size (`ScreenDifficulty`), fading with distance (`DistanceFade`),
  **harder when they're all hidden close together and a little easier spread over a big space** (`RoomSpread`), a
  little easier right up close, and real things hiding them chunk by chunk.
- Fading out while tracking is lost; the Hint key and its arrow; Give up.

**What differed, and now doesn't**
- **Shiny surfaces.** A chameleon dropped on this device may borrow up to 95% of the live picture on glass and
  gloss. Squad's copies of *other players'* chameleons were made without that allowance, so on a shiny spot they
  were easier to see than the same chameleon in Swarm. Both now use one number (`ScatterStage.shineLivingCap`).
- **Staying put.** Squad chameleons sit on ARKit anchors, which move with ARKit's corrections to its map. Swarm's
  were left at plain coordinates, so after the device was put down and picked up they could end up a little off
  their spot. Swarm's are anchored the same way now.
- **Difficulty.** Swarm had Easy, Medium and Hard; Squad always played Easy. The host now picks the level in the
  lobby (Easy by default; guests see "Hard · a miss costs 5 s"), and it does exactly what it does in Swarm:
  camouflage, distance fade and how near a tap must land. A miss costs the same seconds: off the clock in Swarm,
  and in Squad, where the clock is shared, as seconds in which that player's taps don't count ("Missed · wait 5 s").
- **Taps.** Both games now take a tap through the same code. A tap on a chameleon that's already lit up (found,
  or your own with Show mine on) is neither a find nor a miss; in Swarm on Medium or Hard it used to cost time.

**Different on purpose**
- Squad only: syncing, other players' chameleons set down onto this device's LiDAR scan, finds in the finder's
  colour with name tags, your own hidden during the hunt, the hide clock, the live scores.
- Swarm only: found ones turn pink (one seeker), and the seeker gets a few extra seconds per chameleon (in Squad
  the host sets the time outright).
- Another player's chameleon starts the hunt from a half-size copy of its camouflage (sent over the network) and
  then keeps matching the room from this device's own camera, as Swarm's do.
- When the Hint key unlocks: your Settings choice in Swarm (1:00 or 0:30 left, or off), halfway or off in Squad
  (the host's choice).

## v7.0: Swarm difficulty

Playtesters found one-device Swarm a little too easy once they knew it. **SEEKER'S TURN** now has **Easy · Medium ·
Hard** (the seeker picks; it's remembered). Easy is the game as it was. Each step turns up every lever a little
(`Core/SwarmDifficulty.swift`):

| | Easy | Medium | Hard |
|---|---|---|---|
| Camouflage during the hunt (phone / 13" iPad) | 0.69 / 0.82 | 0.77 / 0.90 | 0.84 / 0.95 |
| Fully clear within | 1.0 m | 0.8 m | 0.6 m |
| Faintest (and from) | 20% from 4.0 m | 14% from 3.6 m | 10% from 3.2 m |
| How near a tap must land | 26 pt | 20 pt | 14 pt |
| A miss costs | nothing | 2 s | 5 s |
| Extra time per chameleon after the first | 12 s | 9 s | 6 s |

- A line under the choice says what it means ("Hardest to spot. A miss costs 5 s.").
- During the hunt the bottom line says it again ("Tap what you spot · a miss costs 5 s"), and a cherry "−5 s"
  appears beside the clock when a miss costs time. Tapping all over the screen used to be a way to find them; on
  Medium and Hard it isn't.
- The camouflage never goes above 0.95, so a little of the paint always shows and the lag as you move stays
  catchable. A big space still makes every level a little easier (v6.9).
- The results say the level ("4/6 · FOUND · HARD"), and so does a shared picture ("Swarm on Hard").
- On a phone held sideways, Seeker's Turn goes into two columns (no room for the chameleon as well).
- Squad got the same levels in v7.1 (the host picks).

## v6.9: the second squad test

**A guest's finds didn't count.** In a game where Ana hid four and Ben three, Ben found two of Ana's, but the
scoreboard gave him 0 finds and 0 points, and on Ana's screen both chameleons carried her own tags. Cause: a tap
shows FOUND on the tapper's phone at once and is sent to the host once. If the connection blinked at that moment
(common with MultipeerConnectivity on a phone), the send failed without a word. The phone kept showing FOUND, the
host never heard of it, and nothing noticed they disagreed. Now:
- A guest's phone keeps each unanswered find and sends it again every second (and again after reconnecting) until
  the host's game shows it found, by them or by someone quicker. The host takes a repeat as no change.
- Taps stop when your clock reaches 0, and the host waits 1.5 s after time's up before ending the round, for finds
  still on their way.
- If a find never got through before the end, the results show it as not found rather than keep the old FOUND.
- A second, smaller bug: when a chameleon's anchor arrived before its details, that device briefly forgot everyone's
  names and colours (found ones flashed pink).
- Tested between two Simulators over the network, with the guest's first find deliberately lost; and in the core
  tests with the same game (4 hidden against 3, repeated finds): Ben 2 found, 2 points; Ana 3 found plus 2 never
  found, 5 points.

**Your own chameleons are hidden during the hunt.** Seeing them confused people. The hunt's top-left key is now a
**menu**: **Show mine** (off by default, remembered) shows them as see-through white with a "Yours" tag — nothing
like a find or a camouflaged one — over whatever's in front of them. **Give up** and **Leave game** are there too,
so the camera view has only the clock, the scores and the Hint key. Someone who isn't hunting (the hider in hider vs
all, or after giving up) always sees their own. In pass-and-play, **Give up** moved to the pause screen.

**Tags say who found whose.** "Ben found Cy's", "You found Dee's", "Ana found yours" on a sticker in the finder's
colour (the chameleon's colour too). At the end, "Cy's · not found" in Cy's colour. Every find shows on every
device, including on the hider's own screen.

**Longer times.** Squad: hide 1, 2, 3 or 5 minutes (was up to 2), hunt 2, 3, 5, 8 or 10 (was up to 5).
Pass-and-play: 1 to 10 minutes (was up to 3).

**A big space is a little easier** (`Core/RoomSpread.swift`). The game measures how far apart the two furthest
chameleons are:
- Within about 3.5 m of each other (a living room), nothing changes: playtesting said that's right.
- Spread further, up to 9 m and more (a house), they get a little easier: at most 12% less camouflage, clear from
  1.5 m instead of 1 m, and no fainter than 30% instead of 20%.

**Close up, a little easier everywhere.** Fully clear within 1 m (was 0.8 m), and within 0.4 m the camouflage
eases off by 8%, fading back by 1 m.

**The iPad's camera "zoomed in".** Checked: the game already shows everything the camera sees. The 13-inch iPad
Pro's screen has the same shape as its camera picture, so nothing is cropped. The picture just covers less than
your eyes do, and the 2024 iPad Pro has one rear camera, so there's no wider view to zoom out to.

## v6.8: what the first real squad games turned up

A squad game on an iPad Pro and a phone without LiDAR turned up the problems below. Each one lists what caused it
and what changed.

**A chameleon hidden from the phone vanished, for everyone.** The friend who hid it couldn't see it either when
they went back to the spot. Two things combined:
- A phone without LiDAR knows where a table is only from ARKit's estimate of its plane, which can be a centimetre
  or three off. Since v6.3 those planes also hide chameleons on the phone. So when the estimate sat a little above
  the real table top, the table the chameleon stood on counted as something in front of it, and it faded out on
  its own hider's screen.
- On the iPad, the chameleon arrived at the phone's estimated height, a little inside the real table. The iPad's
  LiDAR scan of the table then hid it.

Fixes:
- The surface a chameleon stands on no longer hides it. Hits within a thin band around its feet, inside its
  footprint, are passed through (`ChameleonChunks.supportRegion`). A wall in front, a shelf above and a table it's
  under still hide it (tested).
- A LiDAR device sets the others' chameleons down on its own scan. It looks straight down from just above each
  one; if there's an up-facing surface within 12 cm, the chameleon moves onto it. It is never moved onto the
  underside of something it's hidden beneath.
- During the hunt, your own chameleons (the faint ones) show through everything, so you can always find them.

**Chameleons moved after the iPad was put down** (reworked in v7.2, which fixes the cause). With the camera face down on the floor, ARKit sees nothing, loses
track and guesses where the iPad went. When it's picked up, ARKit takes a moment to recognise the room and correct
itself, and until it does everything is drawn where it wrongly thinks it is. Now:
- While tracking is lost, the chameleons fade out. They fade back in 0.8 s after tracking is normal again, so the
  wrong places are never seen.
- Every chameleon follows ARKit's corrections, including found ones and ones placed from the host's reference point.

**Syncing was the worst part.** Every device had to merge its map of the room with every other device's before
hiding could start. With four players that's six pairs, all of which had to succeed. Now only the host matters:
- The host drops a reference point in the room as syncing starts. A device is synced as soon as it has that point,
  meaning its map has merged with the host's.
- Chameleons are sent with where they are relative to that point, so every device sees everyone's without matching
  every other device's map. With four players that's three syncs, all with the person everybody's standing next to.
- The screen says "Stand by Ana. Point where they point." If it takes a while, it shows tips in turn.

Gameplay is unchanged: a chameleon still sits in the same real spot on every device. If its hider's own anchor
arrives (a little more precise close up), it moves onto that.

**Harder to spot from further away** (`Core/DistanceFade.swift`). During a hunt, a chameleon still to be found is
fully visible within 0.8 m, fades smoothly as you back away, and shows at 18% from 4 m on. Never invisible, so a
sharp eye can still catch one across the room. Found ones and your own don't fade. This applies in every mode.

**Give up.** Every hunt has a Give up key, and it asks first.
- In pass-and-play, the rest light up and the round ends.
- In a squad, you see the rest lit up in their hider's colours, with tags, and can't claim any more. If everyone
  still hunting gives up, the round ends.

**The hint is a key now** (see *The hint key*). It no longer appears by itself; it unlocks, and using it is the
seeker's choice. In a squad the host turns hints on or off in the lobby (on means halfway).

**What the colours mean.** Testers didn't know why found chameleons were different colours. In a squad hunt, each
found one now carries a name tag in the finder's colour: "Ben", or "You", with a magnifier. At the end, or once
you've given up, each one nobody found says whose it is ("Cy's"), with a crossed-out eye, in the hider's colour.

**Paint & Hide stood out** because the light and shadows in the room had changed since the scan. During the hunt
the painted chameleon now takes on a little (35%) of what the camera sees behind it, which evens those out. The
paint job still does most of the work, so painting still matters. The distance fade helps too.

**Squad and Swarm up front.** The home screen's two big keys are Squad ("Everyone on their own phone") and Swarm
("One phone, passed round"). Paint & Hide is a smaller key under them. How to Play starts with Squad and Swarm.

**Found while testing:** on an iPhone in Swarm with more than four chameleons, the found tally squeezed the clock
until the time disappeared. On a phone the tally now reads "2/6" once there are more than four, and the clock never
shrinks.

**To check on devices** (the Simulator has no camera):
- A squad syncing with the host only: a phone that hasn't matched the other phone should still see its chameleons.
- A phone's chameleon on a table, seen from the iPad: it should sit on the table, not in it.
- The iPad face down for a while in a hunt, then picked up: the chameleons should fade out and come back in place.
- The distance fade: is 4 m right for a living room?
- Name tags following the chameleons smoothly.

## v6.7: ready for the App Store

A pass over the whole app for launch. **Built while Xcode 27's licence was unaccepted**
(`sudo xcodebuild -license accept` unlocks it): the core tests, the UI kit, the sound
player, the share card and the rating prompt were compiled and checked; the one-line hooks
into the game and squad screens were checked by reading. Build once before testing.

**Fixes**
- **No auto-lock during a game.** A seeker scanning the room without touching the screen
  was locked out after 30 seconds on an iPhone — the camera stopped and, in a squad, the
  phone dropped out of the game. The screen now stays on everywhere except the home screen.
- **A pass-and-play hunt pauses by itself** if the app goes to the background (a call, a
  notification tapped), instead of the seeker's time running out.
- **Dropping out of a squad game isn't the end.** A player whose phone loses Wi-Fi or is
  locked mid-game keeps their place and their chameleons for 30 seconds (marked with a
  Wi-Fi sign on the others' boards); their phone looks for the room again and asks back in,
  with a "Reconnecting to Ana" banner meanwhile. A host who leaves on purpose now says so,
  so guests get "Host left" at once instead of waiting.
- **Joining**: games already under way no longer show in Games nearby (they stay findable
  for their own players only); a join that's turned down or times out says so instead of
  the button quietly resetting; and a guest now knows the host by the room it asked to join
  (in a room everyone connects to everyone, so the first connection isn't always the host).
- **Copy**: no screen says "iPad" on an iPhone any more ("Hold steady and move slowly",
  "Look around slowly"), and no raw system errors ("AR session failed: …").
- The camera permission now says what it's for in plain words.

**New**
- **Sound**, made in code (`Core/SoundSynth.swift`, played by `App/Sound.swift`): soft
  clicks on keys and chips, a plop for a drop, a two-note bell for FOUND (a softer one for
  someone else's find), woodblock ticks for 3-2-1 and the last ten seconds, a short fanfare
  for a win, a gentle falling phrase for time's up, a pop when someone joins the lobby, and
  a boing when you poke the home chameleon. It follows the silent switch, mixes with music,
  and has a Sound effects switch in Settings. `Tools/build/sounds <dir>` writes them as WAVs.
- **Share** on every results screen: a picture of the room from the camera with the show's
  strip underneath (`UI/ShareCard.swift`). With the paint job showing it says "Can you spot
  it?" — a puzzle anyone can play from a photo; in pink, it's the answer. Once the game has
  an App Store link (`AppLinks.appStore`), every shared picture carries it.
- **A rating prompt** after a win, from the third finished round, once per version
  (`UI/ReviewPrompt.swift`).
- **How to play opens by itself** on the very first launch.
- **Get the game**: a QR code in the squad lobby for friends in the room who don't have the
  app (`UI/InviteCode.swift`); it appears once `AppLinks.appStore` is set.
- **Dark and tinted app icons** (iOS 18+ home screens): the chameleon on its own, rendered
  from the game's mesh (`Tools/build/storeshots icons`).
- Settings shows "Version 1.0" in App Store builds (the build label stays in test builds).

**For the App Store**
- `ChameleonHunt/PrivacyInfo.xcprivacy`: no tracking, nothing collected, and the reason
  for the one "required reason" API the game uses (settings saved on the device). Uploads
  without it are rejected.
- The app requires ARKit (`UIRequiredDeviceCapabilities`), so it can't be installed where
  it can't play.
- `AppStore/`: the listing, length-checked (with an Indonesian one), a step-by-step
  submission guide, and a low-time marketing plan. `docs/`: the website — landing page,
  privacy policy, help — ready for GitHub Pages.
- `Tools/build/storeshots`: frames screenshots into App Store pictures in the game's look
  (6.9" iPhone and 13" iPad, portrait or landscape), and renders the crew in all six
  colours. Examples in `AppStore/screenshots/demo/`.

**To check on devices** (the Simulator can't): the reconnect after a real Wi-Fi drop — in
one Simulator run a guest gave up sooner than its 25 seconds and it wasn't clear why, so
the connection code logs what it does in debug builds (`[squad]` in Xcode's console); the
share picture and sheet; the sounds' levels next to each other.

## A little easier on a phone, a little harder on a big iPad (v6.6)

Playtesting found Swarm and Squad a very little too hard on an iPhone and a very little too easy on a 13-inch iPad:
the same chameleon is about a centimetre tall on a phone's screen where it's two and a half on the iPad, and small
things are much harder to pick out. So during the hunt the chameleons follow the room's colours slightly less on a
small screen and slightly more on a big one (`Core/ScreenDifficulty.swift`). It's worked out from the screen's
physical size, so it's a sliding scale rather than phone-or-iPad. How strongly they match the room during the hunt,
out of 1:

| iPhone 17 Pro (6.3") | Pro Max (6.9") | iPad mini (8.3") | iPad Pro 11" | iPad Pro 13" |
|---|---|---|---|---|
| 0.686 | 0.698 | 0.726 | 0.783 | 0.820 |

It was 0.75 everywhere; it moves by at most 0.07 either way. What shows through instead is a little more of the
colour they were given where they were hidden, which is a little wrong from anywhere else — what a sharp eye
catches. Paint & Hide is unchanged: its chameleon doesn't adapt to the room at all (until v6.8, which gives it a
little during the hunt).

## Squad

Several iPhones and iPads in the same room, each player on their own (with or without LiDAR: see above). No accounts and no server: devices
find each other on the local network (or Bluetooth) with MultipeerConnectivity, and nothing leaves the room.

1. **Host or join.** One player taps **Host game** and gets a four-letter room code. Everyone else sees the room in
   **Games nearby** and taps **Join**. Up to six players. Names are set in settings or on this screen.
2. **Lobby.** The host picks the mode, how many to hide, and the hide and hunt times, and taps **Start** (it needs
   two players). Everyone else sees what's been picked as a summary — the mode, then tiles for how many, the hide
   time and the hunt time — and "Waiting for Ana" with the host's chameleon, the way Among Us and Jackbox do it:
   only the host gets controls, so a guest is never shown chips and tiles that look tappable but aren't (v6.5).
   Guests feel a tick when the host changes something.
3. **Sync up.** Everyone stands by the host and points where the host points. The host's device drops a reference
   point in the room; ARKit's collaborative session merges each device's map with the host's, and a device that has
   the host's reference point is synced (a tick by its name). Once everyone is, hiding starts by itself. From then
   on a chameleon hidden on one device appears in the same real spot on all of them. (Until v6.8 every device had to
   merge with every other one: see v6.8.)
4. **Hide**, against a gold clock, with the same aim-and-drop as Swarm. Nobody sees anyone else's chameleons yet.
   Two seconds after your last one lands (time to Undo), you're done: the screen goes to **ALL HIDDEN**, with
   everyone's chameleon lined up — ticked when they're done, a dark silhouette with dots while they're still hiding
   — "Waiting for Ben and Dee", and the clock (v6.6).
5. **Hunt.** Every device shows the same intro at the same moment: **HUNT** on a starburst, whose chameleons you're
   after ("Find all 9", or "Find Cy's 8"), the colour your finds will turn, then 3-2-1. The hunt's clock starts when
   it ends; taps don't count before (v6.6), or after time's up. Then tap what you spot. The first tap on a
   chameleon wins it, and you can't claim your own — which you don't see during the hunt unless you turn on **Show
   mine** in the menu (v6.9). **A find turns the finder's colour** — Ana's green, Ben's yellow — on every device,
   with a **name tag** saying who found whose ("Ben found Cy's", v6.9). A live mini leaderboard sits in the corner,
   and a feed in the finder's colour says it too. The **Hint** key unlocks halfway (if the host left hints on). The
   **menu** key, top left, has Show mine, **Give up** (lights up the rest for you and takes you out of the hunt; if
   everyone still hunting gives up, the round ends) and Leave game.
6. **Results**: a ranked scoreboard — a point for every find, a point for every chameleon of yours nobody found — and
   the unfound ones light up in the room in their hider's colour, with a tag saying whose they were ("Cy's · not
   found"), so every chameleon out there shows who got its point. The host taps **Play again** (no re-sync needed)
   or goes back to the lobby.

Times: the host picks 1, 2, 3 or 5 minutes to hide, or no limit (2 minutes by default), and 2, 3, 5, 8 or 10 to
hunt (3 by default). When the hide clock runs out, anyone short has the rest placed for them (v7.4). In
pass-and-play the seeker's time goes from 1 to 10 minutes (2 by default).

Two modes:

- **Free-for-all** — everyone hides a few (1–5), then everyone hunts everyone else's.
- **Hider vs all** — one player hides a swarm (3–10) while everyone else's screen says **LOOK AWAY**; then the rest
  race to find them, and the hider scores for every one that survives. The hider rotates each round.

**Keeping every device in step** (v6.3). A second round in testing jammed: clocks disagreed, a phone's taps did
nothing for a minute, and time ran out with nothing happening. The cause was the connection, not the rules: every
chameleon's camouflage was sent at the start of the hunt as a big message and relayed by the host to everyone, the
room map went round every 8 seconds, and the host relayed every AR update as must-arrive — so the small messages
that matter (a tap, "round over") queued behind megabytes. Now:

- Big things (camouflage, at half size; the room map) go as file transfers, which don't block messages.
- AR updates ARKit marks as droppable stay droppable when the host passes them on.
- The room map is sent when hiding starts, again only when it has grown by 15%, and once at the hunt.
- Clocks: the host stamps when each phase started, and every device measures how far its clock is from the host's
  (quick pings, trusting the fastest round trip), so every clock shows the same time however late a message lands.
- The host re-sends the whole game every 3 seconds, and devices never go back to an older version, so anyone who
  missed something catches up by themselves.
- A tap counts on your screen straight away (FOUND, and it turns your colour); the host still decides who got it
  first. Since v6.9 a guest's phone sends each find again every second until the host's game has it (see v6.9).
- If time runs out before the host's "round over" arrives, the screen says so instead of sitting there.

**The crash when a squad game started** (v6.5). The iPad stopped about two seconds into hiding, twice — once
hosting, once joining an iPhone's game. The iPad's own crash reports (read from the device over USB) both say the
same thing: the app was stopped inside the "finished sending" callback of the room map. The iPad was the device
mapping the room both times (it's the one with LiDAR), and the first map goes out two seconds into hiding. That
callback was written inside main-thread-only code, so Swift 6 marked it main-thread-only too; MultipeerConnectivity
calls it on its own background queue, and Swift 6 stops the app when that happens rather than risk a data race. The
map is now sent with no callback at all (nothing used it), and the two other system callbacks of the same kind (the
AR session watcher and the world-map fetch) are marked as safe to run anywhere.

While checking every screen, a second crash of the same family turned up in the Simulator, on the results screen:
SwiftUI measured a layout it wasn't showing on its background render thread, and the scoreboard's rows were built
there. The hunt's live mini-board, the lobby's chips and the sync roster were built the same way, so they could have
crashed mid-hunt whenever a score changed. They now use layouts that are always built on the main thread
(`RowOrColumnLayout`, `FlowLayout` in `UI/HuntKit.swift`); the rule is written down there. No crash in 60+ launches
of every screen since.

How it's built: the game is plain data (`Core/SquadRules.swift`, tested). The host's device is the referee: every
player's action goes to it as an intent ("I placed one", "I found that one"), it applies the rules and sends everyone
the new state, and it keeps the clock. So there's one answer to "who tapped first", and a device that drops out and
back in just gets the latest state. AR map updates and each chameleon's camouflage (sent when the hunt starts, so it
looks the way it did where it was hidden) go through the host too (`App/Squad/PeerLink.swift`,
`App/Squad/SquadGame.swift`). If the host leaves, everyone gets **Host left** and goes back to the room list.

## The hint key

The hint is the seeker's choice, at any moment of the hunt, for half that hunt's coins from then on (v7.4; before
that it unlocked near the end, and before v6.8 it appeared by itself). A sun **Hint** key sits bottom right; it
asks before it costs anything, and the card it opens says what it costs. It can be switched off altogether: in Settings for
pass-and-play, by the host in a squad's lobby (guests see "Hint costs half your coins" or "No hints"). In Paint & Hide it names the pose and the size. In Swarm and Squad an arrow at the
edge of the screen points to the nearest one still hidden (never your own); "It's in view" once it's on screen.
There's also a **3-2-1 countdown** before the clock starts, so the seeker is looking at the room — not at the hider —
when it does.

## Requirements

- iPhone or iPad running iOS/iPadOS 18 or later. LiDAR (Pro models) for the full game; without it, Swarm is lite
  and Paint & Hide is locked. Squad needs two or more devices on the same Wi-Fi (the first time, allow **Local
  Network** access when asked).
- Fingers paint; an Apple Pencil takes over automatically when it touches the glass
- Xcode 26 or later (built with Xcode 27)

The paint studio also has a **demo room** that needs no LiDAR (see below).

## Run it on the iPad

```bash
open /Users/ish/Downloads/Sendy-main/ChameleonHunt/ChameleonHunt.xcodeproj
```

1. Plug in the iPad, unlock it, tap **Trust**.
2. Choose the iPad as the run destination and press **⌘R**.
3. First run only: **Settings → General → VPN & Device Management →** trust your developer certificate, then relaunch.
4. Allow camera access.

Signing uses team `845R88VCU9` (set in Xcode). Debug builds are compiled with `-O` because painting and baking
are CPU-heavy; switch `SWIFT_OPTIMIZATION_LEVEL` back to `-Onone` if you need to step through code.

## How to play (and what to test)

### 1. Choose
On the home screen tap **Squad**, **Swarm** or **Paint & Hide**. The seeker's time, when the hint key unlocks and your
name are in settings (the gear).

### 2. Place

**The chameleon holds still while you aim** (v6.1, `Core/AimStabilizer.swift`). It used to sit exactly where the
centre of the screen hit the room, recomputed every frame: the LiDAR mesh is rough by a centimetre and its triangles
tilt a few degrees, a hand is never still, and it turned to face the camera every frame. So it shivered and swivelled,
and "Hide here" put it wherever the last noisy reading was. Now small wobbles change nothing, a real move is followed
quickly and smoothly, aiming at a different surface jumps straight there, level surfaces are treated as exactly
level, and it only turns to face you once you've walked well round. In the tests a shaky aim moves it under a
millimetre a frame, with no tilt or swivel, and a steady pan keeps within 3 cm. The preview's model also stopped
being rebuilt every frame, which was part of the lag.

- **Chameleon:** aim at a shelf, table, floor or wall; a see-through chameleon follows the aim point. Pick
  **Sitting / Napping / Sunbathing** from the portraits (on a wall it climbs automatically). Pinch to resize, twist
  (or drag sideways) to turn, then tap **Hide here**.
- **Swarm:** aim and tap **Drop** once per chameleon; **Undo** takes the last one back, **Done** hands over.
- **Shiny spots:** if you're aiming at something glossy, glass or mirror-like, a hint says "Shiny. Matte spots hide
  better." Those surfaces look different from every step the seeker takes, which is exactly why camouflage struggles
  there (see *Living camouflage* for what the app does about it).

### 3. Scan
Walk slowly round it. The ticks on the floor fill in on whichever side a good picture was just taken from; the ring
at the bottom of the screen shows the same thing as a percentage. At 90% it finishes by itself. If you can't get all
the way round, **Finish scan** appears at 45% (and whatever the percentage, once the ring has stalled somewhere you
genuinely can't walk round — the ceiling, the top of a wardrobe).

**The ring only counts pictures that were kept** (v6). It used to light up for any look at the spot, so a fast walk
round could fill it while every blurred frame was thrown away, and the scan then failed at "100%" with a vague "walk
around a little more slowly". Now every frame that's turned down is turned down for a reason the app counts — too
fast, too dark or plain, tracking lost, the spot off-centre, too close, too far, something in the way, or **the spot
moved** (the depth at the spot no longer matches: it's on a person or a pet). While you scan, the top of the screen
says the live reason ("Slow down", "The spot moved…"); if a scan still can't be used, the game's own card names the
main one with what to do about it, and **Keep scanning** carries on from what's genuinely done (the ring never shows
anything that wasn't captured). If the pictures were fine but there's no solid surface round the spot, it says
**Can't see the surface** and offers **Move it** or **Scan again**.

### 4. Paint

**Done painting** is the one big key, bottom right (on a phone, full width at the bottom); **Magic camouflage** is a
smaller white button beside it. It used to be the biggest thing on the screen and drowned Done out.

**Magic camouflage got smoother, then much faster** (v6.2–6.3, `Camouflage.paintAll`): the bottom couple of centimetres now ease into the
colour of the surface right beside them (from almost anywhere that's what's behind the bottom of a chameleon, and a
line of wrong colour along the bottom was the most common giveaway), and a light edge-preserving smoothing takes out
the speckle a noisy scan leaves, without blurring real edges. In the tests the bottom edge matches the floor twice as
closely, speckle drops by about 40% and a hard edge stays sharp. v6.2 did this texel by texel and a small chameleon
took seconds; v6.3 colours ~2.5 mm patches once and blends each texel from the patches around it (which is the
smoothing too), so it takes 0.03–0.06 s at any size and looks the same (0.02 apart on average).

One finger paints, two turn the model, pinch zooms; two-finger tap undoes, three redoes. (With an Apple Pencil, the
Pencil paints and fingers move the view — it switches by itself.) **Magic camouflage** paints the whole thing to
match the room in one go — including the lower half of its sides, which it used to leave white: the scan's camera
positions are all above the chameleon, so it now also imagines a seeker crouching or sitting at a few heights round
it, and paints the belly edge with the surface right beside it. **Copy room** paints whatever is behind it from where you're looking; **Pick colour**
grabs a colour from the room. Tap **Done** when it's hidden.


### 5. AR check — putting it back

While you paint, the AR camera is off and the iPad loses track of where it is. So when you come back:

1. **Point the iPad at the area and sweep it slowly.** That's the whole procedure. Twice a second the app takes the
   shape of what you scanned and tries to fit it onto the LiDAR mesh of what it can see now — at the spot you're
   aiming at, tried at eight different facings, letting the scan itself decide which one is right (iterative closest
   point over facing and position; both scans share gravity, so tilt is already correct). When the same fit comes
   back twice in a row and is confident, the character goes back by itself and the HUD says *"Matched your scan
   (3 cm, 21°)"*.

   **Why this rather than recognizing the room?** ARKit's own relocalization matches camera imagery, so it only works
   from roughly where you stood when you scanned — and nobody comes back at that angle. You sit down to paint, then
   walk back from somewhere else entirely, which is why it used to fail nearly every time and drop you into placing it
   by hand. Shape doesn't care where you stand. In tests it recovers the spot to within 3 cm and 7° from three
   completely different viewpoints (from the side, from behind, standing over it), in about 30 ms an attempt.

   The saved world map is still tried in the background, because when it *does* work it is instant. But it is no
   longer allowed to reset the session to try — that reset wipes every mesh anchor ARKit has built, which is exactly
   what the shape search needs.

2. **Placing it by hand** is still there, and after about ten seconds the button appears — but it's now the fallback,
   not the destination. The same shape fit runs on a hand placement (clamped to 8 cm so a bad aim can't drag the
   character across the room), and it keeps searching while you aim, so if it recognizes the spot first it just puts
   itself back.

   Two things must line up before it appears on its own, which is what stops it from turning up somewhere random or
   under the floor:
   - ARKit must actually recognize the room from the map saved when you finished scanning (it reports "relocalizing"
     and then "normal"). Tracking that merely looks fine isn't enough — the saved coordinates would land in a brand
     new coordinate system.
   - The spot must still *be* a surface: the app casts a short ray along the spot's own up direction and checks it
     lands on the scanned mesh, facing the same way. Only small sinking (under 5 cm) is corrected during a round —
     in a tight gap a larger "correction" is as likely to shove the character somewhere wrong.
   - The room around the spot must still match the scan, which rejects a relocalization that lands somewhere
     plausible but wrong — a random patch of floor has no wall or table where the scan says there should be one.
     (After a hand placement, this is whether the snap above found a match.)

**If ARKit's tracking jumps.** In a tight space, close to surfaces, tracking can degrade and ARKit re-establishes where
it is — every anchor's coordinates shift with it, which is what used to teleport the character onto the floor behind
you a second after placing it. A sudden jump (more than 15 cm, and much larger than the iPad actually moved) is now
only followed if the spot still sits on a surface *and* still matches the scan. Otherwise the character is hidden and
the app re-finds the spot properly, saying so. During a hunt the clock holds while that happens, so the seeker doesn't
lose time to it.

3. **Spot check** — walk around and judge it. **Show** turns it pink and shows it through obstacles so you can see
   exactly where it is; an arrow points to it when it's off screen. **Paint** goes back to the studio to touch up.
4. **Ready** only unlocks once the character is actually showing.

### 6. Hunt
The seeker's time is in settings: **0:30, 0:45, 1:00, 1:30, 2:00 or 3:00** (remembered between launches).

The **Seeker's turn** screen keeps the AR camera running underneath, so tracking isn't lost while the iPad changes
hands — hand it over gently without covering the camera. **Go** starts the 3-2-1. Tapping near the character counts
(a small tolerance ring); misses are counted. Real objects in front of the hiding spot hide the character.

**Pause** (top right) stops the clock and covers the screen, with **Resume**, **Restart hunt** (back to the handoff
with a full clock), back to painting, or **End game**.

### 7. The reveal

When time runs out, or it's found, the chameleon turns pink (the ones nobody found, in the lots-of-them game) and
the camera stays live, because the point of this moment is walking over and looking at the spot. **Play again** is
one big button: same game, same difficulty, straight back to hiding. There's no "are you sure?" and no warning —
starting again used to mean a small corner button and a confirmation dialog, which was the wrong answer to testers
who tapped a big button too early. The camera and the pink chameleon are still right there until you tap it.

## Occlusion: hiding just the covered part, instantly, without the glitch

Real things in front of a chameleon have to hide it, or hiding behind anything is pointless. There have been three
answers to this:

1. **Cut it per pixel** against the LiDAR depth map. Right in principle, but an edge drawn from a measurement good to
   a few centimetres crawls and flickers as the iPad moves, and that flicker is exactly what gives a hiding place away.
2. **Never cut; fade the whole chameleon** once about a fifth of it was covered (v4.0). Steady, but crude — in testing,
   something across its middle made the whole thing vanish.
3. **Now: chunks** (`Core/ChameleonChunks.swift`). The chameleon is split into ~100 chunks a few centimetres across.
   Forty times a second each chunk checks, from the depth map, how much of its camera-facing surface has something
   real at least 6 cm in front. A chunk disappears (in well under a tenth of a second) once a quarter of it is
   covered, or once a neighbour is mostly covered — so the cut sits a little *outside* the real edge, where depth
   noise can't reach it. The state lives on the chameleon, not the screen: a chunk is the same bit of chameleon
   whichever way the iPad moves, so nothing slides or crawls.

**A soft edge** (v6). Whole chunks switching off still looked like a staircase — "section by section". The cut
is still made exactly where it was, as fast as before, but the chunks touching it now fade to 45% and the ring beyond
them to 80%, so the edge blends out over a few centimetres instead of stepping.

**Hiding is instant; showing is patient** (v5). Testers swung the iPad quickly so a wall came between them and the
chameleon, and it lingered for about a second, sticking out against the wall. That was the old rule of ignoring every
reading while the iPad moved fast, plus a dwell and a slow check rate. Now the two directions are treated differently,
because the two mistakes cost differently: hiding something that's actually visible for a moment is invisible to the
player, but showing something that should be hidden gives the hiding place away. So a "covered" reading counts
straight away, even mid-swing, and fades out in 0.06–0.08 s; an "uncovered" reading only counts once the iPad has
settled, and a part has to stay clear for about 0.4 s before it fades back in.

On top of that, once a chameleon is **mostly** covered (60%), all of it goes rather than leaving a sliver
(`VisibilityPolicy`). In the tests, with a wall across the left half of the view, every chunk behind it fades and
most of the open half stays; the only part-faded chunks are the soft edge next to the cut, fainter nearer the cut;
a wall swept in front mid-swing hides it within a frame or two; and a burst of bad depth while the iPad moves
changes it at most once.

## Living camouflage

Hand-painted camouflage has a ceiling: the paint comes from the scan, at the scan's exposure and from the scan's
angles, and it's drawn without lighting. On anything shiny, or from a new angle, it turned into a flat patch of
slightly-wrong colour, and that patch was usually how it got found.

But the camera is looking straight through the chameleon — it isn't really there — so the pixel of the live camera
image under any part of it is exactly what's behind that part, from this viewpoint, at this exposure. A few times a
second every visible texel eases towards that colour (`LiveSkin`), skipping parts hidden behind other parts of itself
and parts with something real in front. Stand still and it melts into the background; move quickly and it can't
keep up, leaving a faint shimmer for a sharp-eyed seeker. The lots-of-them chameleons do this all the time: at full
strength while you're hiding them (keeping what they learn, so they've melted in before the hand-over) and at 75%
during the hunt.

The one hand-painted chameleon doesn't — if it matched the room by itself there'd be no point painting it — **except
on shiny spots.** Glass, mirrors, glossy tables and TV screens show a different picture from every angle (and a TV
changes by itself), which no paint job can follow. In testing, a chameleon on a TV stayed obvious: the old check
only asked the depth sensor how unsure it was, and a TV's flat screen gives a perfectly confident depth reading.

So v5 also measures what actually matters — **how much the view behind the chameleon differs from the scan**
(`LightingMatch.viewDependence`). A few times a second it takes ~28 points on the surface behind the chameleon, works
out what colour the scan recorded there (corrected for the room's current exposure), and compares it with what the
camera sees there now. On a matte surface the two agree from any angle; on a reflection or a screen they don't, and
the more they disagree the more of the live camera image the chameleon borrows — up to 60%, never all of it, so the
paint still matters. It takes whichever is higher, that or the depth sensor's uncertainty, smoothed so it never
flickers. On a matte spot, the paint is all there is.

## Second rounds

After one full round, hiding again used to produce a broken paint studio — the chameleon inside a wall, a missing
floor, or an empty grey room. Between rounds the AR view leaves the screen and ARKit pauses; when it resumed it tried
to relocalize to where it had been (or to the last hunt's saved map) and could succeed halfway through the next scan.
The world's coordinates jumped, so the camera frames recorded before the jump and the room mesh after it no longer
lined up. Every round now starts on a fresh AR session, so round two is exactly like round one.

## Lighting: keeping the paint matched to the room

The paint comes from the scan, which bakes in the exposure and white balance the camera had while scanning — usually
darker, since the hider is close and shading the surface. During the hunt the camera exposes for a different view, so
those same colors read as a dark patch.

**Match room lighting** (on by default, in the AR check) fixes that continuously: a few times a second it samples the
live camera around the character and the color the *scan* recorded for those very same surfaces, takes the median
ratio, and re-tints the paint by it in linear light. It corrects brightness and color temperature together, and follows
the room as the seeker moves.

It's deliberately cautious: a median ignores samples that hit the wrong surface, near-black and blown-out pixels are
skipped, channels may correct white balance but not recolor, the whole correction is clamped to 0.55×–2.2×, and it
eases in so the character never flashes. The Diagnostics panel shows the current multiplier and sample count.

## Studio demo (no LiDAR needed)

On the intro screen, **Studio Demo: Floor** / **Studio Demo: Wall** open the studio with a procedurally painted room
(wood floor, striped wallpaper, a cabinet, a checkered crate). Everything except the AR steps works there.

## Why the practice studio was sometimes black (fixed in v6.5)

RealityKit only draws one of its views in a window at a time. Going into the studio, the camera's AR view was still
fading out when the studio's own 3D view appeared, so for a moment there were two — and depending on the device,
orientation and timing, the studio's view could lose and stay black. Now the camera's view and the studio's view
never overlap: whichever is leaving goes first, and the other appears once it's gone (`RootView` in
`App/ChameleonHuntApp.swift`, `showsViewport` in `Studio/StudioView.swift`).

## On a phone held sideways (v6.5)

Every screen now fits an iPhone in landscape. The ones that needed their own layout:

- **Home**: the chameleon on the left, the name and the two keys on the right (it had shrunk to a coin).
- **How to play**: picture beside the words; the dots and the button stay put while the pages swipe.
- **Squad lobby**: both columns start at the top, with a smaller room sign.
- **Look away**, **Seeker's turn** and **Paused**: the chameleon or title beside the rest.
- **Squad results**: the board on the left (scrolling if needed), the result and the keys on the right.
- **Paint studio**: the brush bars sit side by side and the tools fold into two columns (the rails were taller than
  the screen and pushed the top bar off it); the colour card puts the shade square beside the controls.

Also for phones: stacked keys at the bottom of a screen now share one width, and at the largest text sizes the logo,
the game cards and the scoreboard names all still fit.

## The Simulator

The app builds, launches, and runs the whole studio (auto-camouflage, strokes, undo) in the iPad Simulator, but on
this Mac **the iOS 26.3 Simulator does not draw RealityKit meshes at all** — verified with Apple's own minimal
`RealityView` showing a plain box, which also renders nothing. The 3D viewport will be empty there; use a device.

## Verification done so far

- Core tests on macOS (`Tools/build/coretest`, all pass): watertight meshes for all four poses; the mascot renders;
  turning spins about the surface normal only; two-state visibility (edge noise never touches it, a person walking
  past fades it out and back in exactly once, it never pops, **a quick sweep behind something hides it at once, mid-swing**,
  **bad depth during a swing hides it at most once, with no flicker**, a third covered leaves the rest showing and mostly covered hides it all, a threshold doesn't strobe);
  fading in chunks (every quad in exactly one chunk; a wall across half the view fades every chunk behind it and
  leaves most of the open half; nothing is left half-faded; mid-swing, covered chunks go on the very first reading and none come back until it settles); the toy
  colours (green, with eyes you can see); coverage from a ray-traced depth map
  (100% under a table every frame, 0% on open floor, gone within 0.03 s); living camouflage (takes the colour of what
  the camera sees, never from something in front of it, and leaves the side it can't see alone); magic camouflage
  paints every texel on the lower sides (the scan alone never saw about a third of them); the spot search recovers
  the hiding place from three viewpoints.
- Magic camouflage: the bottom edge matches the floor beside it twice as closely (0.23 → 0.11); smoothing cuts the
  speckle of a noisy scan by ~40% while a hard edge stays sharp (0 of ~5,000 edge texels blurred); painting in
  patches matches texel-by-texel (0.02 apart) and takes 0.03–0.06 s at any size (it was up to 2 s on a Mac).
- Changing pose keeps the paint: sitting → napping keeps a painted head 100% on the head, a painted tail 99% on the
  tail, and the unpainted body 84% unpainted.
- Placing holds still: a shaky aim moves it under a millimetre a frame, no tilt or swivel; a pan keeps up; a new
  surface is a jump.
- Squads with and without LiDAR: the full game when everyone has it, the host (or else whoever can) maps the room,
  Lite when nobody can; a room map packs to ~240 KB for 20,000 triangles and comes back within a millimetre; with
  the shared map, a wall in front hides a chameleon and a wall behind doesn't.
- Squad rules (18 checks): colours are handed out on joining; hider vs all takes turns; the first claim wins and you
  can't claim your own; scoring; settings are kept in range; the whole game survives being sent between devices; a
  player who leaves takes their chameleons with them.
- Squad networking between an iPad and an iPhone Simulator (both without LiDAR, so the lobby correctly says Lite),
  and earlier between two iPad Simulators: hosting, the room appearing on the other device, joining,
  both lobbies showing the same players, **Start** reaching both, a guest leaving (the host's list updates) and the
  host leaving (the guest gets **Host left**).
- Every screen captured on the iPad Pro 13" (landscape), iPhone 17 Pro (portrait, landscape, and the largest
  standard text size) with no crash; the captures are in `.impeccable/review/v65/`.
- Builds clean for device and Simulator (Swift 6 language mode).

- v6.8: core tests for the new rules and geometry — a chameleon on a table whose estimated plane is 2 cm too high
  is 0% covered (it was hidden), while a wall in front and a shelf above still hide it; the distance fade (full
  within 0.8 m, never below 18%, smooth, never brighter further away); give up (not before the hunt, no claims
  after, everyone giving up ends it, reset next round); hints default on; a chameleon's spot survives being sent.
  Every new screen captured on the iPad Pro 13" and iPhone 17 Pro (iOS 27 Simulators): home, How to Play,
  Settings, lobby (host and guest), sync, the squad hunt (hint locked, unlocked, gave up with tags), the Swarm and
  Paint & Hide hunts (hint locked, ready, used), results. Two Simulators over the network, host → join → Start →
  Sync up. Debug, device and Release builds clean.

**Not verified (needs real devices):** anything with a camera — hiding instantly behind real objects and the soft
edge, the new scan reasons and keyframe-only ring, the TV/mirror camouflage, the Swarm blend-in animation, the stalled-scan button on a ceiling spot, the studio's one-finger turning —
the steadier placing on a real mesh — and in Squad, everything from **Sync up** on: ARKit merging two devices' maps,
chameleons appearing in the same real spot on every device, taps claiming them, and the shared room map lining up on
a phone without LiDAR. The Simulator has no camera or LiDAR, so a squad game there stops at
Sync up.

## Tools

`Tools/build.sh` builds six command-line programs, none of which needs an iPad (with Xcode's
licence unaccepted, run it with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`):

- `Tools/build/coretest` — the test suite. Each test is a bug that actually happened.
- `Tools/build/preview` — renders the poses from four angles to a PNG, or `--mascot` / `--icon`.
- `Tools/build/storeshots` — App Store screenshots in the game's look (`frame`), the crew
  pictures (`crew`), the dark and tinted icons (`icons`), and the game's share picture from
  any photo (`card`, for posts). See `AppStore/README.md`.
- `Tools/build/sounds` — writes the sound effects as WAV files, to listen to.
- `Tools/build/frames` — pulls frames out of a screen recording (`frames <video> <outdir> <start> <end> <fps>`), and
  `Tools/build/montage` tiles them, for reading bug videos frame by frame.

## Files

| Folder | Contents |
|---|---|
| `Core/` | Pure Swift + simd, unit-testable: `SquadRules` (the multiplayer game as data), `ChameleonChunks` (fading just the covered part, with a soft edge), `PoseTransfer` (keeping the paint across a pose change), `ToyPaint` (the chameleon in its own colours), `VisibilityPolicy` (all shown or all hidden), `OcclusionCoverage` (how much is behind something), `CharacterMask`, `LiveCamouflage` (`LiveSkin`), `SurfaceNets`, `CharacterSDF` (poses), `CharacterGeometry` (atlas, texel map), `TriangleBVH`, `EnvironmentGeometry`, `KeyframeBaker`, `PaintCanvas` (brushes, undo, magic camouflage), `VisibilityMap`, `HideScene` (+ demo room), `SurfaceFrame`, `SpotRegistration`, `DepthSurface` (grid geometry), `LightingEstimate`, `MascotRenderer` |
| `AR/` | `ARSessionController` (session, placement, scan, finding the spot again, taps, diagnostics), `ChameleonActor` (one chameleon in the room: fades, living camouflage, marking), `CharacterPresenter` (the painted one), `ScatterStage` (lots of them), `ScanRing`, `LightingMatch` + `CameraColorSampler`, `KeyframeCollector` |
| `Render/` | `LiveTexture`, `SceneAssets` (meshes, materials) |
| `Studio/` | `StudioController`, `StudioInputHandler` (Pencil vs finger), `StudioView` |
| `App/`, `UI/` | `GameStore` (the round's state machine), `RoundModel` (a round as plain data), `HintTiming`, `AppVersion`, `HuntKit` (the look), `Notice` (the game's own dialogs), `DesignSystem` (the studio's kit), `Mascot`, `PhaseViews` (one-device screens), `SquadViews` (squad screens) |
| `App/Squad/` | `PeerLink` (finding and connecting devices, MultipeerConnectivity), `SquadGame` (a squad game on one device: lobby, host's clock, AR in step with the game) |

## Known limitations

- Shiny, glass and mirror-like surfaces are still the hardest place to hide; the chameleon borrows part of the live
  image there, but not all of it, and the app suggests somewhere matte.
- Squad sync needs each device to see the same part of the room as the host, from a similar place; a bare wall or
  floor gives ARKit too little to match. Stand by the host and aim at somewhere with detail.
- A phone without LiDAR places on its estimate of a surface, which can be a couple of centimetres off. A LiDAR
  device corrects that for itself (it sets others' chameleons onto its own scan); two phones without LiDAR see
  each other's where they were put.
- Something thin a few centimetres in front of a chameleon won't hide it until it covers about a quarter of a chunk.
- Living camouflage lags when the seeker moves fast — deliberately, like a real chameleon, but a sharp eye can catch
  the shimmer.

## Debug launch arguments (Debug builds)

`-demoStudio floor|wall`, `-demoPose standing|curled|lying|clinging`, `-demoAutoCamo`, `-demoStroke`,
`-demoCamoStroke`, `-demoCamera <azimuth°> <elevation°> <distance>`, `-demoShading`, `-demoHideScan`,
`-debugPhase placing|replacing|scanning|scanStuck|arCheckLocating|arCheckLost|arCheckVisible|handoff|seeking|paused|result|timeup|scatter|scatterHandoff|scatterSeeking|scatterResult` and `-debugDiagnostics` (overlay layout only),
`-debugPhase hintReady|clue` (the hint key unlocked; used), `-debugPhase scatterPenalty` (a miss on Hard, with the
"−5 s"), `-debugPhase scatterHinted` (the hint on), `-debugCoins <n>` and `-debugSkin <name>` (a wallet for screenshots, not
saved), `-debugSkins` (the shop), `-debugDifficulty easy|medium|hard`, `-debugSideways` (the app laid out as a phone on its side, turned inside
the upright screen, for Simulators that can't be rotated), `-debugSettings`, `-debugHowTo`, `-debugLiDAR` / `-debugNoLiDAR` (as on a device with or without LiDAR),
`-debugNotice tooFast|tooDark|lostTracking|offCentre|tooClose|tooFar|spotMoved|blocked|surface` (a scan message),
`-demoPanel poses|colours|options|pose|clear` (with `-demoStudio`: a studio card or question open),
`-debugSquad home|rooms|lobby|lobbyHard|lobbyGuest|lobbyGuestHard|lobbyMixed|lobbyLite|syncing|hiding|hidingAuto|lookAway|waiting|hunting|huntingHint|huntingMissed|huntingGaveUp|huntIntro [seconds]|results|resultsHost` (filled with four made-up
players; as a guest, you're Ben; `huntingGaveUp` also shows sample name tags; add `-debugHuntMenu` to open the
hunt's menu), and for real networking between two Simulators `-debugSquad autoHost [-debugAutoStart]` on one and
`-debugSquad autoJoin` on the other, each with `-debugName <name>`. Add `-debugAutoPlay <hide> <finds>` to both to
play a whole round without a camera (sync, hide, find, give up; the scoreboard goes to the log), and
`-debugLoseClaim` to the guest to lose its first find on the way, as when the connection blinks.
