# Headroom

Shows where your disk space went and how to get it back. A native Mac app in Swift and Metal.

The design thinking is in [DESIGN.md](DESIGN.md).

## Run it

Requires macOS 26 or later and Xcode's command line tools.

```bash
./build.sh
open build/Headroom.app
```

The first time, the ring shows a hatched "Hidden" piece, because macOS keeps Downloads, Desktop, Documents and a few
others private. Click **Allow Full Disk Access** and switch Headroom on in the pane that opens. The app is signed with
your development certificate if you have one, so the permission survives rebuilds.

After that, the last scan appears as soon as the window opens, and a refresh runs quietly at low priority. To see what
a first launch looks like, quit the app and start it without the saved scan:

```bash
open build/Headroom.app --args --no-cache
```

## How to use it

- **Map** shows what's on the disk. Colour shows what belongs together: each big thing has its own colour, and
  everything inside it stays close to that colour. Point at anything to see its name, its size and what you'd really
  get back. Click to zoom in, and click the middle (or press Esc) to go back.
- **Changes** shows what has grown. It lights up in heat colours and lists the folders responsible. It reads file dates
  on the first day, then compares scans as history builds up.
- **Free Up** shows what can go, sorted by what it costs you. Tick things and watch the free wedge grow as a preview.
  Everything goes to the Trash, and the space comes back when you empty it.

| Keys | |
|---|---|
| ⌘1, ⌘2, ⌘3 | Map, Changes, Free Up |
| Esc or ⌘[ | Back |
| Space | Quick Look what you're pointing at |
| ⌘F | Find a file or folder |
| ⌘R | Scan again, at full power |
| Right-click | Reveal in Finder, Quick Look, Copy Path, Move to Trash |
| Pinch | Zoom in and out |

## What the numbers mean

- Sizes are space on disk. Hard links and identical APFS clones count once, in the place you'd think of as home.
- **"You'd get back"** can be far less than a folder's size. If a folder's files are also linked from somewhere else,
  removing that folder alone frees nothing. The panel says where the other copies are.
- The ring always adds up to the whole disk. Whatever can't be read is the hatched Hidden piece.
- Partly changed clones are counted in full, so a folder of them can look slightly bigger than it is.
- During a first scan, a size with dots (`64 GB…`) may still grow, and the hatched piece says "Still reading". Zooming
  into a folder reads it first.

## How it's built

| Where | What |
|---|---|
| `Model/Scanner.swift` | The scan: `getattrlistbulk` on a thread pool, big things first, then the rest at low priority |
| `Model/Volume.swift` | The disk's own numbers, the top of the tree, the scan's two speeds, and hard-link and clone accounting |
| `Model/Rules.swift` | What Headroom knows about particular folders, and how safe each is to remove |
| `Model/Insights.swift` | Free Up rows, Changes rows, and the colours for each view |
| `Model/History.swift` | The saved last scan, snapshots for comparison, free-space history |
| `Render/Layout.swift` | Turns part of the tree into pieces of a ring |
| `Render/MapEngine.swift` | Transitions: where each piece starts and ends, and one spring that carries them |
| `Render/Shaders.metal` | Each piece's shape and light, the glow and the scale. macOS compiles this at launch |
| `UI/` | Labels, the centre readout, and the glass panels |

To check the whole interface without touching the mouse, run the app with a script. The steps are listed at the top of
`App/ScriptRunner.swift`.

```bash
build/Headroom.app/Contents/MacOS/Headroom --script steps.txt
```

To redraw the app icon, run `Resources/make-icon.sh`.
