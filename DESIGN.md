# Headroom: design brief

A Mac app that shows where your disk space went and how to get it back.

## The problem with disk maps

Most disk maps, Baobab included, answer "what is the folder tree?" You came with other questions.
They also get the numbers wrong in ways that matter:

- **They show sizes you can't get back.** Two hard links to one film look like two films. A folder of
  APFS clones can look like 24 GB and free almost nothing.
- **They don't add up to the disk.** Swap, a downloaded macOS update and root-only data never appear,
  so the total is short and you can't tell why. Those three moved tens of gigabytes on this Mac in a
  single day.
- **Their colours mean nothing.** Hue follows position, so a whole colour channel carries no
  information.
- **They stop at "here is a big thing".** They don't tell you whether it's safe to remove.

## Who is using it, and when

| You're thinking | What you need | What Headroom does |
|---|---|---|
| "How full am I, and what's biggest?" | One glance | The ring is already there when the window opens, with free space in the middle and the biggest things named around it |
| "I had 41 GB yesterday. What happened?" | What changed | **Changes** lights up what grew and dims the rest, with a ranked list and a free-space history |
| "I need 20 GB now, without breaking anything" | Safe wins, ranked by risk | **Free Up** lights up what can go. Tick things and the free arc grows as a preview before anything happens |
| "What is this folder? Can I delete it?" | A plain answer | Hover: name, size, what it is, what you'd really get back |
| "Why doesn't it add up?" | The whole disk | The ring always sums to the real disk: macOS, swap, updates, hidden data, free |
| "What's inside here?" | To go deeper | Click to zoom, click the middle to go back. Reveal in Finder, Quick Look |

## Principles

1. **The map is the interface.** It fills the window. Everything else floats on top in glass, and the
   window should still look complete with the panel closed.
2. **Colour means something.** In **Map**, colour is the kind of data. In **Changes**, it's heat. In
   **Free Up**, it's what can go. One geometry, three questions: changing the question recolours the
   same picture, so you never lose your place.
3. **Name things directly.** Big things are labelled on the map, so you don't need a legend or a hover
   to read it.
4. **Sizes are true.** Hard links and clones count once. Every size on screen is space on the disk.
5. **Free space is a real shape.** It's a visible part of the ring, and it's what grows when you clean
   up. That's the reward.
6. **Never delete.** Everything goes to the Trash. The Trash stays visible on the map until you empty
   it, because space isn't back until then.
7. **No waiting.** The last scan appears as soon as the window opens and refreshes quietly behind it. A
   scan never blocks you, because the ring grows while it runs. Hover answers within the frame.

## The hero: an answer you can read at a glance

A radial map, because a disk is one whole and a ring reads as one object. Five changes from the
sunburst in the reference:

- **Starts where the answer is.** A chain like `/ → Users → you` wastes rings. The inner band splits the
  disk into Your files, Apps, System, Hidden and Free, and your folders start on the next ring.
- **Sorted clockwise from 12 o'clock,** biggest first, so position gives you the rank. Free space closes
  the circle.
- **Rings that don't lie about area.** In a normal sunburst the same angle covers more area further out.
  Rings get thinner as they go out to offset that.
- **Tidy edges.** Slivers too small to see merge into one "smaller items" piece, so the outer edge reads
  as shape and not noise.
- **Light that carries meaning.** Colours are in the wider Display P3 range with a soft glow. Hover lifts
  the piece you're on and dims the rest, and related items light up together.

## The three views

- **Map:** colour by kind, such as video, audio, code, AI models, apps, caches and system. A parent's
  colour blends its children's, so colour flows inward and you can tell what a folder is mostly made of
  before opening it.
- **Changes:** what grew. Uses scan history when there is any, and file dates on the first run, so it's
  useful on day one. Keeps a free-space history, including system volumes, which is how a downloaded
  update gets caught.
- **Free Up:** grouped by what it costs you:
  - **No loss:** restart for swap and temp files, install a waiting update, empty the Trash.
  - **Rebuilds itself:** caches, `node_modules`, build folders.
  - **Download again:** AI models, games, simulators.
  - **Your call:** big, old files nobody has touched.

  Groups span folders, so "`node_modules` in 14 projects" lights up all 14 places at once. Those name-based rules
  only apply inside your own project folders. The same name inside an app, Homebrew or a tool's install is part of
  something that would stop working without it.

## Truthful accounting

- **One volume, read once.** Scan the Data volume directly, so firmlinks can't double count. Never cross
  a mount point. Sealed system volumes come from APFS itself.
- **The sum must reconcile.** Whatever the scan can't see becomes a labelled Hidden piece, so the ring
  always equals the disk.
- **Hard links count once,** in the place you'd think of as home. "Downloads 7 GB, plus 88 GB of links
  to Media" is the true answer.
- **"You'd get back" is its own number.** Deleting either copy of a hard-linked file frees nothing.
  Deleting both frees it all. The cleanup preview does this sum for whatever you've ticked.

## Speed

- `getattrlistbulk` on a work-sharing thread pool, which returns a whole directory's metadata in one
  system call. No `String` per file, no per-file `stat`.
- Fixed-size records in memory-mapped tables. Small files are summed into their folder, so memory scales
  with folders and big files, not every file.
- Metal draws each piece from a single analytic shape, so the frame cost doesn't depend on how complex
  the map is. Nothing is drawn when nothing moves, so it uses no power at rest.
- The last scan is saved, so opening the app shows the map at once.

Measured on this Mac, an M5 MacBook Air with 2.1 million files and a 494 GB disk:

| | |
|---|---|
| Full scan | 6.6 s, against 40 s for `du` on the same data, and the scan also collects kinds, dates, links and clones |
| Opening with the last scan | The saved scan loads in 6 ms |
| At rest | 0.0% CPU, 145 MB of memory |
| During a scan | 290 MB of memory at peak |
| Building the ring | Under 1 ms |

The scan's limit is APFS itself: about 15 µs per file in the kernel, whichever attributes are requested. So the design
makes the wait not matter, rather than chasing a faster scan.

## What it looks like

Near-black, with the ring as the only source of light. Real Liquid Glass (`glassEffect`), not an
imitation, floats over the ring and refracts it. Numbers roll instead of snapping. Motion is one spring,
used everywhere.
