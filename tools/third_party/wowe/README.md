# WOWe Generator

Paint still water, rivers and where the water falls on three masks, and they become one seamlessly looping pixel-art scene: rivers run toward the edge under a net of light that slides along every bend and speeds up, pour over a bright mouth into the fall, crash into round foam and mist, and the foam drifts away down the stream. Ponds lie still under a wobbling net of light, or drift.

Water, rivers and falls share one engine, one palette and one clock, so they always fit together: four still water looks, waves rolling in, dark patches, the tide with its wet trail and opacity for every part.

Turn on **Clean** for rivers and lakes drawn the way clean pixel art draws them: flat tones in a few smooth zones, unbroken one pixel shores, never a lone pixel, at any picture size.

## Install

In Aseprite open **Edit > Preferences > Extensions > Add Extension** and pick the `.aseprite-extension` file, or copy the `wowe-generator` folder into Aseprite's extensions folder. Needs Aseprite 1.3 or newer.

## How to use

1. Add a layer called `water` and paint the still or gathered water in any colour: the pool at a fall's foot, ponds, lakes. Seen from above at an angle, as you would draw them.
2. Add a layer called `river` and paint the flowing water: the river coming to the edge, the stream leaving the pool.
3. Add a layer called `fall` and paint where the water falls. Every column of it falls from its top to its bottom; steps of a cascade are just more pieces under each other.
4. Let the river overlap the top of the fall: the overlap is the river's mouth, the curved edge it goes over. Its shape is the mouth's shape (a curve bulging toward you looks like an edge seen from above), and the deeper the overlap, the longer the white curl over the edge. With no overlap the mouth sits right on the edge; a gap of 1 or 2 px between them is closed by itself.
5. Any of the three may be left out: water alone, a river alone, a fall alone all work, and a single `water` layer can still hold river and pool together (it flows wherever a fall feeds or drains it).
6. Open **Edit > Insert > WOWe Generator**.
7. The preview on the left plays the scene over your drawing. Paint or erase on the masks and it redraws by itself. The mask layers are guessed from their names; the Water, River and Fall buttons on the preview's left edge pick others.
8. **Apply** writes the loop to a layer called **WOWe Water**, right above the water layer. Applying again updates the same layer, wherever you have moved it.
   - Missing frames are added. The other layers carry on into them as linked cels, so a still scene stays one drawing.
   - The mask layers are hidden.
   - Each Apply is a single undo step.
   - RGB, Indexed and Grayscale sprites all work.

## How the water knows where to go

- A river whose water reaches the top of a fall runs toward that edge, all the way along its bends, and speeds up as it gets close.
- Flowing water carries a net of light lines and darker cells  that slides down the flow: two copies of it take turns, each fading in and out while the other is in full view, so it follows every bend, stretches where the water speeds up and still loops without a seam.
- Where it meets the fall it goes over its mouth: one band across the edge, column by column. Blue teeth reach up into the river, white water lies over the edge, and streaks hang from it into the curtain, fading from cyan to light blue to the water's blue, now and then a dark slit in one. Every column has its own lengths, and the columns bob up and down like a wave running along the edge. The band is as big as the fall is wide. The edge follows the shape you painted, or a lip rod you draw (see Rods). Arcs sag down the fall under it and break up as they go.
- The falling water has a style: Classic (fine strands and dark slits), Streaks (long streaks, lighter at the top down to ragged ends), Fringe (light curtains hanging in pointed fringes over darker ones) or Scales (rows of scallops). All slide down and speed up as they fall.
- A river may fork: each branch runs to the fall it reaches, and the falls may share one lake.
- A river no fall pulls runs the way the River tab's Way dial points.
- Water a fall lands in flows away from the landing: rings spread, the fall shows upside down in it, and its foam is carried off down any stream that leaves the pool.
- A pool between two falls takes the water from one and gives it to the next.
- Still water with no fall lies still. **Drift** gives it a flow of its own.
- Guide rods, when on, steer it all by hand (see below).

## Clean

Clean draws the surfaces (rivers, lakes, pools) as flat tones and edges of whole pixels instead of the grainy classic texture. Seven looks turn it on, one for each kind of river picture: **Brook** (blue, light shallows, deep blotches), **Rocky** (stones in pale shallows, a darker channel), **Shallow** (pale water over sand, checkered patches), **Clear** and **Glassy** (a net of light over the bed), **Lagoon** (turquoise, stones near the shore), **Stream** (a blue channel between wide pale beds). Any other look can have it too: switch on **Clean pixel art** on the **Look** tab.

- **Zones** stay put: light shallows along the shore, the water, deep and deepest blotches further out. Depth sets what share of the open water is deep, so a big lake is no darker than a small one. No zone has a part one pixel thin and no patch is only a few pixels.
- The shore is one unbroken line, with a second one lapping out and back; rings, wave lines and the net's walls are unbroken one pixel lines too; glints are short dashes.
- Last of all, any pixel no neighbour shares its colour with takes a neighbour's: no lone pixels, even where a bubble or a drop fell.
- **Size** makes the zones, stones and net bigger while every line stays one pixel thin. **Auto** goes by the picture: 1x up to about 170 px, 3x from about 510 px.

## Rods

Bendable rods you draw right on the preview, of two kinds (pick which on the **Rods** tab, or from the row beside the Rods button, before drawing):

- **Flow** rods steer the water: near one it runs along it, the way it points. The river bends where you bend the rod, still water gets a current, and a line of foam flecks rides along it.
- **Lip** rods draw the edge a fall goes over. Draw one across a fall: the water above it becomes the mouth (river running to the edge) and the fall starts right at it, column by column, so the mouth's band follows your curve. A plain rectangle of fall with a curved lip rod gives a rounded ledge. Below a lip rod the river's mask no longer counts: the rod is where the water goes over, and where the river reaches it with no fall painted under it, the water falls there too, as far down as the fall beside it goes (or till it meets still water).

Turn rods on and off with the **Rods** button or on the **Rods** tab; turned off they are kept, just not used. The eye beside the Rods button (or **Show on the preview** on the Rods tab) hides them from the preview while they keep working; hidden, they cannot be edited, and a click on the preview just pauses.

| On the preview | What it does |
|---|---|
| Drag on the water | A new rod, the water runs the way you drag |
| Drag a dot | Bends the rod (an end dot makes it longer or shorter) |
| Drag the line | A new dot there, bending it |
| Shift + drag an end dot | A new dot past it: the rod grows longer |
| Alt + drag the line | A branch growing from there (or press **Branch** first) |
| Right click a dot | Takes the dot away |
| Right click the line | Takes the rod away, with its branches |
| Click (no drag) | Pause or play, as without rods |

A branch's first dot stays on its rod: drag it to slide it along, and it follows when the rod moves.

| Control | What it does |
|---|---|
| Rods | On or off (the switch on the section's line) |
| Show on the preview | Hidden rods still steer the water but cannot be edited |
| New rod | Flow (steers the water) or Lip (the edge a fall goes over) |
| Strength | How much the water turns to follow a rod (10: wholly, on the rod) |
| Reach | How far from a rod it still turns (px) |
| Foam | The foam flecks carried along the rods |
| Branch | The next drag from a rod grows a branch |
| Reverse | The selected rod the other way round |
| Undo | Back one rod edit |
| Clear | Every rod gone |

Every sprite keeps its own rods. A sprite saved in a file gets them back the next time it is opened.

## The window

One window: the preview on the left, the settings on the right. Drag the window's edges to make it bigger or smaller; drag the bar between the two to give either more room. The gear button puts the settings away so the preview gets the whole window, and brings them back.

**Preview**
- Click or Space: pause or play.
- Wheel: zoom in or out at the mouse. Drag (or middle drag): move the picture. Double click, F or the fit button: fit it again. + and - zoom too.
- The line at the top names the mask layers; the zoom is on its right.
- After any change the animation keeps playing. The frame on show is baked first and the others follow; the line at the bottom reads "Baked n / N".
- **Apply** sits at the bottom right.

**Toolbar** (down the preview's left edge). Rest the mouse on a button to see what it does; buttons with a small corner triangle open a menu or a row of buttons.

| Button | What it does |
|---|---|
| Water, River, Fall | The mask layers: pick another layer from the list, or "none" |
| Look | All the ready looks, with their colours |
| Die | A new variation: the same settings, other shapes |
| Play | Pause or play |
| Rods | Rods on or off; its row: new rods Flow or Lip, Branch, Reverse, Undo, Clear, show or hide |
| Fit | Fit the picture to the preview |
| Gear | Show or hide the settings |
| ? | Keys and mouse (F1) |

**Settings**: six tabs, one setting a row with its value on it. Every setting tells what it does when the mouse rests on it. Double click a slider to type a value; Shift while dragging moves it finely; the arrow keys nudge the slider under the mouse.

**Look** tab

| Control | What it does |
|---|---|
| Waterfalls: Forest / Cave / Emerald / Ruins / Lava | Ready looks (colours and settings) |
| Lakes and pools: Pool / River / Pond / Beach | Four still water looks |
| Clean pixel art: Brook / Rocky / Shallow / Clear / Glassy / Lagoon / Stream | The clean looks (see Clean) |
| Colors | Dark to light: shadow, deep, base, light, highlight, foam. Click: the color picker. Right click: take the foreground color |
| From one color | The six colours from a single base color (the water's own tone), with Hue shift, Saturation and Tone range |
| Clean pixel art | The switch on its line turns Clean on or off |
| Size | Auto (by the picture's size) or 1x to 3x: how big the zones, lines, stones and net are drawn |
| Shallows | How wide the light shallows along the shore are |
| Stones | Stones in the shallows |
| Dither | A checkerboard where two zones meet (0 to 3 px) |

With Clean on the other settings still apply: Depth (both), Shore foam and Banks (the shore's line, lapping from 2), Sparkle (glints), Net and Cell (the net's walls), Patches, Rings, Waves, Reflection, the mouth.

**Water** tab (still water)

| Control | What it does |
|---|---|
| Shore foam | 0 off, 1 a shimmering shore line, higher: lapping foam |
| Waves | Wave lines rolling in to the shore (0 to 3) |
| Shade | The dark band under top banks (rivers too) |
| Sparkle | Little glints on the water and the falls |
| Net, Cell | The net of light on still and pooled water (wobbling in place, or sliding where a fall feeds the pool), and its cell size |
| Patches | Darker patches: whole cells of the net, or with no net round spots that swell and shrink |
| Depth | Darker deep water away from the shore |
| Drift, Drift way | Speed and direction of still water's flow (0: still) |
| Tide | The switch on its line: still water climbs past its mask and falls back. Height (px, it never goes below the mask), Cycles (times a loop), Uneven (0: the whole shore at once; higher: in waves along it), Wet trail (how long the ground stays wet) |

**River** tab (the river layer's own settings)

| Control | What it does |
|---|---|
| Speed | How fast the river runs |
| Rush | How much the river speeds up toward an edge |
| Rapids | White water all down the river, more where it runs fast or hits a bank or a stone; with rods on, more along each rod and laid the way it runs (still water a rod drives gets some too) |
| Streaks | Light streaks where the river runs fast, toward an edge |
| Way | Which way a river runs where no fall pulls it |
| Net, Cell | The river's net of light sliding down the flow, and its cell size |
| Banks | The river's shore line and foam along its banks |
| Depth | Darker deep water in the middle of the river |
| Patches | Darker patches drifting down the river |
| Mouth: Foam | How tall the white water over the edge is (0: no mouth band) |
| Mouth: Fringe | How long the streaks hanging from it into the curtain are |
| Mouth: Teeth | How far the blue teeth reach up into the river |
| Mouth: Wave | How far the columns bob up and down (0: still) |
| Mouth: Ragged | 0: the lengths change smoothly along the edge; 10: every column its own |

The mouth's sizes are px on a fall 30 px wide; a wider fall gets a bigger mouth, up to three times.

**Fall** tab

| Control | What it does |
|---|---|
| Style | Classic, Streaks, Fringe or Scales (see above) |
| Speed | How fast the water falls (it speeds up on the way down) |
| Lines | Thin light strands running down the curtain |
| Weave | Strands woven into long cells, like a ladder of light |
| Slits | Dark gaps under the edge where the curtain splits |
| Top | The mouth's white band on a fall with no water over it (Fringe, Wave and Ragged as on the River tab) |
| Arcs | Bands sagging across the fall from its lip, darkening and breaking up on the way down |
| Edges | Outlines on the sides; higher: ragged sides and drops breaking off |
| Shading | Rounds the curtain: lighter toward the light |
| Light | Which side the light comes from |
| Splash | Foam, Spread, Bubbles and Spray at the landings |
| Rings, Reach | Ripples spreading from where a fall lands, and how far they go |
| Reflection | The fall upside down in the water under it |
| Trail | Foam carried away from a landing, down the stream |
| Mist | Mist, and how high it Rises |

**Rods** tab: see Rods above.

**Output** tab

| Control | What it does |
|---|---|
| Frames | Frames in the loop (8 to 32) |
| Frame time | How long each frame shows |
| New variation | Another pattern with the same settings |
| Opacity | Water, deep water, falls, slits, lines, net, patches, waves, foam, shade, sparkle, mist and the wet trail (0 to 100%). Clear water shows what is drawn under it; the rest mixes into the water beneath |

Changing colours or opacity never bakes again.

## Seamless loops

Everything that moves follows the loop's phase and comes back to where it started: the frame after the last one is exactly the first.

## Speed

- The work is cut into small slices on a timer, so Aseprite never freezes.
- A change redoes only what it needs: sliders reuse the masks, the flow and the textures; speeds and frames remake their textures; a rod edit redoes only the flow's lanes; painting the masks starts from the new pixels.

## Requirements

Aseprite 1.3 or newer. Tested with Aseprite 1.3.18 on Windows.

## License

MIT, free to use in any project. See `LICENSE`.

## Files

- `main.lua` registers the command and loads the modules from `wowe/`:

| File | What it holds |
|---|---|
| `scape.lua` | The scene: falls, surfaces, foam, mist, spray |
| `clean.lua` | The clean surfaces: zones, the net's walls |
| `mouth.lua` | The mouth's band over every edge |
| `flow.lua` | How the surfaces flow |
| `guide.lua`, `rods.lua` | Guide rods, and editing them on the preview |
| `mask.lua` | The masks and distances |
| `codes.lua` | What a pixel is |
| `noise.lua` | Noise |
| `engine.lua` | Baking in slices |
| `ui.lua` | The window: the preview, the toolbar, what the settings do |
| `ui_pages.lua` | The settings' tabs |
| `ui_window.lua`, `ui_panel.lua`, `ui_menu.lua`, `ui_style.lua`, `ui_icons.lua` | The window's parts: the canvas, the panel's controls, menus, colours, icons |
| `output.lua` | Writing to the sprite |
| `styles.lua` | Looks and settings |
| `palette.lua` | Six colours from one |
| `paint.lua` | Pixels and opacities |
| `i18n.lua` | The window's words |
