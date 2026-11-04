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
7. **No waiting.** The window opens with a picture you can use. With a saved scan that's the whole map,
   refreshed quietly behind it. Without one, it's what the disk itself reports, and the big things arrive
   within about a second. Hover answers within the frame.

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

What matters is how soon the picture is right, not when the last small file is counted. On this Mac, 17,000
of the 2.1 million files hold 91% of the bytes, and a folder holding big files usually has few entries. A
folder's listing already says how many entries each subfolder has, so the scan knows what's cheap before
opening it.

1. **First frame.** Free space, macOS and swap come straight from the disk, so they're exact. Everything else
   is one hatched "Still reading" piece.
2. **First look, under two seconds at full power.** Folders are read fewest entries first, with build
   folders and caches last. `~/Media` has 43 files holding 98 GB, so it's done within milliseconds.
3. **The rest, in the background.** Three threads at low priority read the tiny files, and the hatched piece
   shrinks as they go. A size that may still grow reads `64 GB…`, and "so far" where you point at it.
4. **What you're looking at comes first.** Zooming into an unfinished folder sends it to the front of the queue
   at full power, until it's done.
5. **Free Up and Changes want the whole disk.** Opening either one during that first scan puts it back to full
   power. Moving things to the Trash waits for the scan, because the numbers aren't final yet.
6. **With a saved scan,** the map is there at once, and the whole refresh stays in the background. ⌘R means you
   asked, so that runs at full power.

Two details keep it honest while it runs:

- The interface only ever reads a copy of the tables, taken every so often. So hovering, zooming and the panels
  all work during the scan, and nothing can read a number that's being written.
- A hard link in Downloads or a cache doesn't claim its file's bytes during the scan, because that's rarely the
  file's home. Without this, 90 GB of films would sit under Downloads until the last moment, then jump to Media.

Underneath:

- `getattrlistbulk` returns a whole directory's metadata in one system call. No `String` per file, no per-file
  `stat`.
- After the first look, a worker reads a folder's subfolders straight after it, because they open relative to it.
  That wins back what strict order costs.
- Fixed-size records in memory-mapped tables. Small files are summed into their folder, so memory scales with
  folders and big files, not every file.
- Metal draws each piece from a single analytic shape, so the frame cost doesn't depend on how complex the map is.
  Nothing is drawn when nothing moves, so it uses no power at rest.

Measured on this Mac, an M5 MacBook Air with 2.1 million files and a 494 GB disk, without Full Disk Access:

| | |
|---|---|
| Launch to a first frame with the disk's numbers | About 200 ms |
| First launch: half the bytes placed | 0.4 s |
| First launch: placed after one second | 72–81% |
| First launch: everything read | 13–14 s, on about 1.2 cores after the first look |
| With a saved scan: the map on screen | The saved scan loads in under 10 ms |
| With a saved scan: the refresh | 14.5 s at low priority, on about 1.2 cores |
| ⌘R, at full power | 6.9 s, against 40 s for `du` on the same data, and the scan also collects kinds, dates, links and clones |
| At rest | 0.0% CPU, 170–220 MB of memory |
| During a scan | About 260 MB of memory at peak |
| Building the ring | Under 1 ms |

The scan's limit is APFS itself: about 15 µs per file in the kernel, whichever attributes are requested. Folders
store no total size, and Spotlight only knows part of the disk. So the design makes the wait not matter, rather than
chasing a faster scan.

## What it looks like

Near-black, with the ring as the only source of light. Real Liquid Glass (`glassEffect`), not an
imitation, floats over the ring and refracts it. Numbers roll instead of snapping. Motion is one spring,
used everywhere.
