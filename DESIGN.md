# Headroom: design brief

A Mac app that shows where your disk space went and how to get it back.

## The problem with disk maps

Most disk maps, Baobab included, answer "what is the folder tree?" You came with other questions.
They also get the numbers wrong in ways that matter:

- **They show sizes you can't get back.** Two hardlinks to one film look like two films. A folder of
  APFS clones can look like 24 GB and free almost nothing.
- **They don't add up to the disk.** Swap, a downloaded macOS update and root-only data never appear,
  so the total is short and you can't tell why. Those three moved tens of gigabytes on this Mac in a
  single day.
- **Their colours can't be learned.** Hue follows position, so a folder changes colour whenever anything
  around it changes.
- **They stop at "here is a big thing".** They don't tell you whether it's safe to remove.

## Who is using it, and when

| You're thinking | What you need | What Headroom does |
|---|---|---|
| "How full am I, and what's biggest?" | One glance | The ring is already there when the window opens, with free space in the middle and the biggest things named around it |
| "I had 41 GB yesterday. What happened?" | What changed | **Changes** lights up what grew and dims the rest, since the last scan or in the last day, week or month |
| "What's just been sitting there?" | What hasn't changed | **Changes**, the other way round, lights up what nothing has changed in for a month, three months or a year |
| "I have this film in three places" | Duplicates, and what only looks like one | **Copies** gives each set of duplicates its own colour on the ring. Keep one, then delete, hardlink or symlink the rest |
| "I need 20 GB now, without breaking anything" | Safe wins, ranked by risk | **Free Up** is a short stack of boxes, safest first. One click selects a whole box, and the ring shows it before anything happens |
| "Which of these do I still need?" | Evidence, not a guess | Each suggestion says what's known: last opened, watched in Plex, last commit, no sign of use for 7 months |
| "Wait, I want to keep that" | To change my mind | Nothing happens until you press Clean. One click deselects anything, and Keep stops suggesting it. After that it's in the Trash, and Undo puts it back |
| "What is this folder? Can I delete it?" | A plain answer | Hover: name, size, what it is, what deleting it really frees |
| "Why doesn't it add up?" | The whole disk | The ring always sums to the real disk: macOS, swap, updates, hidden data, free |
| "What's inside here?" | To go deeper | Click to zoom, click the middle to go back. Show in Finder, or Shift-Space for a card, a window of its own, that shows what's inside at once and plays a film where it is |

## Principles

1. **The map is the interface.** It fills the window, under a toolbar like any Mac app's, and what floats over it is
   glass. The inspector sits beside it, edge to edge, as in Apple's own apps, and the window should still look complete
   with the inspector closed. The title says where you are, as a Finder window does, and the window comes back as you
   left it: the view, and the inspector shown or hidden at its width.
2. **Colour means something.** In **Map**, it shows what belongs together. In **Changes**, it's how much of a
   piece is new or changed, red for a little and yellow for all of it, or how much of it is untouched, deep blue for a
   little and pale ice for all of it. In
   **Free Up**, each box in the list has a colour and its files wear it, so the list is the legend. In **Copies**, each set of
   copies has a colour and every copy wears it, so the same colour in two places is the same file. One geometry, four
   questions: changing the question recolours the same picture, so you never lose your place.
3. **Name things directly.** Big things are labelled on the map, so you don't need a legend or a hover
   to read it.
4. **Sizes are true.** Hardlinks and clones count once. Every size on screen is space on the disk.
5. **Free space is a real shape.** It's a visible part of the ring, and it's what grows when you clean
   up. That's the reward.
6. **Nothing happens until you say so.** Ticks only select. Clean moves what's selected to the Trash, which stays visible on the map until you empty it, because space
   isn't back until then. Emptying is always its own click. The one exception is Move to Trash, two steps into the Delete menu, for one thing you've
   decided about: it goes at once, and Undo brings it back.
7. **No waiting.** The window opens with a picture you can use. With a saved scan that's the whole map,
   refreshed quietly behind it. Without one, it's what the disk itself reports, and the big things arrive
   within about a second. Hover answers within the frame.
8. **Standard terms, short labels.** Trash, duplicate, cache, hardlink, symlink: the words a Mac user already knows.
   Labels, not sentences, and no captions under buttons. An explanation goes once, behind a **?** or in a tooltip. Rows
   state facts, not verdicts.

## The hero: an answer you can read at a glance

A radial map, because a disk is one whole and a ring reads as one object. Five changes from the
sunburst in the reference:

- **Starts where the answer is.** A chain like `/ → Users → you` wastes rings. The inner band splits the
  disk into Your files, Apps, System, Hidden and Free, and your folders start on the next ring.
- **Sorted clockwise from 12 o'clock,** biggest first, so position gives you the rank. Free space closes
  the circle.
- **Rings that don't lie about area.** In a normal sunburst the same angle covers more area further out.
  Rings get thinner as they go out to offset that. Free space and what's hidden have nothing inside them to
  draw, so they reach as far out as the rest of the disk does on average, and cover the same share of the
  ring as of the disk.
- **Tidy edges.** Slivers too small to see merge into one "smaller items" piece, so the outer edge reads
  as shape and not noise.
- **Light that carries meaning.** Colours are in the wider Display P3 range. In Map they hold back a step at
  rest, with only a faint glow. Pointing at something brings it to full colour with its glow, lifts it and dims
  the rest, and related items light up together.

## The four views

- **Map:** you can read the structure from colour alone. Each big thing in view has its own colour from the
  whole spectrum, kept far from the pieces beside it. Headroom remembers it, so a folder keeps its colour
  between scans even when sizes change. Everything inside stays close to that colour and gets lighter going
  out, so one group reads as one wedge from the middle to the edge. Big files are the brightest, and tiny
  things step back. System data stays slate on the whole disk.
- **Changes:** what grew. Uses scan history when there is any, and file dates on the first run, so it's
  useful on day one. Keeps a free-space history, including system volumes, which is how a downloaded
  update gets caught. Each piece is coloured by how much of it is new or changed, from red for a little to
  yellow for all of it, and what didn't change goes quiet. A file counts as wholly changed when its date is in the
  window, or by how much it grew since the scan compared with: which bytes inside it changed could only be found
  by reading it. The middle says how much free space changed; the time to compare with is at the top of the inspector.
  The other way round, it shows what's gone untouched: what nothing has changed in for a month, three months or a
  year, by file dates, which the scan sums per folder as it reads. The cold scale mirrors the warm one, as light at
  every step, so the two read the same way. What you're known to have used in that time counts as touched, however
  old its files: an app you opened, a film Plex says you watched, a game Steam started, a video Spotlight saw you open.
  macOS's own parts and what Headroom leaves alone never count. The scale in the inspector is drawn from the ring's own
  colours, starting from the quiet grey of a piece with none of it.
- **Free Up:** things you may want to delete, in boxes named for what they are: Caches, Junk, Developer, AI models, Games,
  Unused apps, Leftover app data, iPhone backups, Old installers, Screenshots, Project leftovers. Biggest first, and
  only the boxes this Mac has something for. A box earns its place by size, or by being something you'd clear anyway:
  junk shows from 1 MB. Films and series aren't listed: nobody clears a collection from a cleanup list.

  Each rule and each finder names its box (`BoxKind`), so a new kind of thing is one rule or one finder, with a test on a
  made-up disk. Finding costs nothing extra: it uses the paths, names, sizes and dates the scan already has, plus one
  listing of the folders screenshots are saved to. Old means 14 days for an installer and 7 for a
  download that stopped.

  **Select recommended** ticks caches not in use and junk, and nothing is ticked before it's pressed, the Trash included.
  Pointing at it shows what it would take. A tick on a box skips what's in use. **Largest files** is a shortlist under
  the boxes: the 20 biggest files over 1 GB in your own folders that no box covers. It has no tick of its own and no
  total, and it's never recommended.

  Boxes span folders, so `node_modules` in 14 projects lights up all 14 places at once. Name-based rules only apply inside
  your own folders. The same name inside an app, Homebrew or a tool's install is part of something that would stop
  working without it.
- **Copies:** duplicates by content, plus the hardlinks, clones and symlinks already on the disk. In Free Up the inspector
  lists the sets in place of the suggestions. Sets are rows like Free Up's boxes, each with its own colour, which every copy wears on the ring. A folder that's mostly one set wears it too.
  Pointing at a set lights its copies in that colour and tints the folders leading to each, more toward the copy; a lit
  piece is drawn at least 4 pt wide, on top, so a copy too small to draw still shows. Ring labels give each copy's last two
  folders, plus the folder where two paths differ when they'd read the same, and mark the copy to keep. The row says the
  same in one line. Duplicates of many files in the same folders are one set, and a set keeps its colour while others
  change.

  An open set lists every copy: folder, name, date, size, with **Keep** on the one to keep. Clicking another copy keeps it
  instead, and Headroom remembers. **Delete**, **Hardlink** and **Symlink** act on the rest. Ticking a set instead puts
  its duplicates in the plan, for the next Clean. A **?** at the top says what each action does, in a line each. Labels use
  the standard terms and say no more than they need to.

  Hardlinks, clones and symlinks are folded below the duplicates. A hardlink or clone family has no original, since the disk
  doesn't record which came first. Only files big enough to have their own piece are compared, and only when Copies is
  opened, never at launch.

## Easy, with full control

Someone opening a disk tool is asking "what can I get rid of that I won't miss?" So Headroom estimates regret, not
just size. It asks four things about anything on the disk: what is it, can it come back, are you done with it, and what
would you really get back? The line on screen comes from the answers, and it states facts: "6 episodes, 8.9 GB each,
nearly 5x your other series · Opened Nov 1 · Not watched in Plex"

**One set of data, shown two ways.** A section is a list of files and folders. The inspector shows its name, size and what
it's made of, and the ring shows where those files are. Pointing or ticking in one shows in the other, because there's
only one list. Point at a box and its files light up, the names around the ring change to them, and a dashed wedge shows
how much free space it would add. Point at the ring and the box lights up. What's too small to draw, or is drawn as part
of something bigger, lights the piece that holds it, so pointing at something always shows.

**One tick, or as much control as you want.**

1. **A box.** One click selects the whole section. What you set up by hand, such as a model you put in `~/LLM`, or what
   you'd be sorry to lose, stays out of that click unless it's all there is.
2. **A piece of its bar.** Each piece is one thing, to scale. Point at it to see what it is, and click to take just that.
3. **Inside a box.** Open it to see each thing, with its evidence, Keep and Move. Open a thing to tick single files.
4. **The ring.** A click on any piece selects it, and a double-click opens it, as in the Finder. What isn't part of any
   box appears at the top as Selected manually, so it can be seen and deselected.

**The ring shows what's selected.** Solid stays, striped goes, with a thin bright edge. The Free wedge grows in the
colours of what's making room, in the order of the list, and the middle number rolls to the "after" figure. Hold Option
and the ring animates to how the disk will actually look.

**The list follows the zoom.** There's no scope control: the boxes are always for the picture on screen. On the whole disk,
Project leftovers is one box. Inside a video folder, it opens up into old versions, scene renders and review stills. In a
folder that's all one kind of thing, such as `~/LLM`, each thing is its own box. Ticks carry across, so what you tick
inside a folder shows as partly ticked from the whole disk.

**One button, in one place.** It does what the ticks say: clean, then empty. A safe cleanup is the same spot pressed twice,
with the ring showing what each press did.

**Checks run as you tick.** Each selected thing is looked at as soon as the ticking stops, and again just before anything
moves. Is it still there? Is something running from it, or holding a file open in it? Has it changed since you selected it?
Is the other disk connected, with room? Whatever needs attention shows at the top of the inspector with a reason and a fix (Quit
Chrome, Clean anyway). Whatever isn't ready stays ticked, and everything else goes ahead. A check never has the last word on
something that can be put back: something using a folder is a reason to ask, and the answer is yours. Move to Trash asks the
same thing straight away.

**You can see it go.** Pieces leave as they're moved, and the Trash piece grows, labelled and striped. Free space
doesn't change yet, and the inspector says so. Emptying moves the Trash piece into the Free wedge, and the inspector then reports
what the disk really gave back. The Finder hides a name that starts with a dot, even in the Trash, so what goes there shows
without the dot, the message says so, and Undo brings it back under its own name.

**Undo is real.** Everything keeps its place in the Trash on record, even across a restart, so Undo puts it all back
and brings the list back too, ready to fix and run again. Quitting halfway through a clean, or through emptying the
Trash, stops it at the next thing and writes down where it got to, and putting a clean back always finishes before
Headroom quits. The record says which file each thing is, not only what it's called: going to the Trash is a rename, so a
file is the same file there. Headroom notes which file it is before the move, finds it by that if the move doesn't say
where it went, and never puts back or deletes something in the Trash that it can't tell is the one it moved.

### How it knows

The cheapest thing that can answer the question wins. Nothing leaves the Mac, and it's all read-only.

| Source | What it tells | |
|---|---|---|
| The scan | `S05E04` in a name, `.app`, `.git`, numbered frames, how big and how recently changed | Instant |
| An app's own files | Signs of use: settings, caches, saved state, data folders | Far better coverage than Spotlight alone |
| Spotlight | Last opened, with a real use count | A new file gets a date just from being indexed, and few files have one |
| Other apps' records | Plex's watched state and library folders, Transmission's torrents, Steam's last played, git's state | Only if they're there |
| Saved scans of other disks | "All 6 are also on your backup drive", even with it unplugged | By name and size |

A file's last-read date is no help: macOS only updates it on the first read after the file changes, so it can't say whether
a model is still in use. A model says when it arrived, and nothing claims it's old.

Everything that decides what's in the boxes reads names, sizes and kinds that are already in memory. A whole disk takes
milliseconds, so it can run on every change. Apple's on-device model was tried for this and left out: it took up to 25
seconds a folder, and it rated a folder of finished films as the likeliest thing to delete.

"Big" means big for you: compared with the rest of your own library, because a remux is big on purpose.

### Rules it keeps

- Never macOS, or anything running. An entry in Applications that's a link into the system is part of macOS.
- Never the only copy of your own work: a project goes on the list only with no uncommitted work, every branch pushed,
  and nothing in a stash.
- Recent use keeps something out of the automatic picks, and it can still be suggested with that fact shown. Hiding it
  would be a guess.
- If any sign says an app was used lately, it isn't suggested. The mistake this can make is staying quiet.
- A file with another path gives nothing back until that path goes too, and the row says so. A torrent's copy goes with it,
  unless it finished in the last 7 days and may still be seeding. Then it has its own tick, and the box offers to include
  them all. Any other copy is only ever yours to tick.
- Leftovers go by name and contents. "test", "work" or "old" only count inside a project, in a folder that's mostly
  pictures, video or sound, so a folder of code called `test` stays. Anything named saved, keep, master, gold or best stays,
  and so do other copies of a project in `.claude/worktrees`, because only git can say what's in those.
- What only its own app can manage safely, such as a Photos library or Mail, gets an explanation and a button to that
  app, never a tick.
- Copies never touches the copy to keep. By default that's the one not in Downloads, on the Desktop or in the Trash, nor in
  a cache or build folder; then not named like a copy (`film copy.mov`, `Installer (1).dmg`, a folder `Photos copy`), even
  in the same folder; then the older one, by a day or more; then the one in the folder with more files. Duplicates in the
  same folders all keep their copies in the same one of them. On the startup disk only your own folders are compared, the
  ones Free Up's names apply in; on any other disk, everything but the inside of apps and packages. A file that's only in
  iCloud is never read, since reading it would download it.
- Delete, Hardlink and Symlink read every byte of both files first, so a file that changed since it was compared is left
  alone. Each copy is checked as anything cleaned is, then goes to the Trash on record before a link takes its place; if
  the link can't be made, the copy comes straight back. A hardlink needs the same disk; a symlink holds the kept file's
  full path. Undo removes the link only while it's still a hardlink or symlink to the kept file, then puts the copy back.
- Moving to another disk copies, reads the copy back and compares every byte, and only then sends the original to the
  Trash. It never replaces a file that's already there. If it stops halfway, the original hasn't been touched.
- Caches and build output only holds what really comes back by itself: build output with its recipe next to it, caches of apps
  that are closed, and tools it knows. macOS's own caches are never offered, and a model cache only model by model,
  because it also holds your login.
- An app goes to the Trash through the Finder, because macOS keeps apps to itself and only the Finder can move all of them.
  macOS asks once whether Headroom may ask the Finder, and the Finder asks for your password when an app isn't yours to
  move. The inspector says so first. Whatever doesn't go stays on the list with the reason and a Try again button.

## Backup

Free Up and Backup are modes: what you're doing. Map, Changes and Copies are views: how the ring is drawn. The toolbar has a
picker for each, and each always has one chosen. The mode owns the inspector, what a click selects and the button at the
bottom, whatever the view. Changes adds its time picker at the top of the inspector; Copies with Free Up shows the sets of
duplicates instead of the suggestions.

- **Two lists, one at a time.** Each mode has its own list, kept between launches. A file is on one of them at a time:
  selecting it for one takes it off the other, and says so. Each button does one thing and says it: **Clean** (green, to
  the Trash) and **Move … to <drive>** (blue).
- **Big files only.** Backup offers and takes files of 10 MB and up. On an exFAT drive every file takes at least a
  cluster, 128 KB on a large one, so a smaller file costs too much next to what it frees.
- **Where it goes.** In `Backup from <Mac>` on the drive, named as Sharing names the Mac, at the file's full path on the
  Mac: `/Users/you/Downloads/F.mkv` goes to `Backup from Studio/Users/you/Downloads/F.mkv`. Nothing mixes with what the
  drive holds already, and each path says which Mac and folder it came from. Choose Folder… puts that folder elsewhere
  on the drive. Compare with *drive* looks in the same place.
- **A move proves itself first.** The file is hashed as it's read, written under a hidden name, read back from the drive
  past every cache and hashed again; only a copy that matches gets its name, and it never replaces anything. Then
  `name.hrmoved` goes where the file was, and only then does the original go to the Trash, on
  record like a clean, so Undo puts it back and emptying the Trash frees the space. A file an app has open stays.
- **The note is the record.** It's plain text: name, size, hash, the drive by name and ID, the path on the drive, when.
  It moves with its folder, and Time Machine keeps it. Headroom remembers the notes it wrote and finds others through
  Spotlight.
- **Ghosts.** In Backup each note is drawn as its file, at its size, as a faint outline: diagonal lines are for what's
  selected. View › Show Moved Files hides them. It's a
  picture: nothing is selected, counted or cleaned from it, and anything that changes the disk puts the real map back
  first.
- **Both disks.** Backup's own picture is both disks: a ring around the middle in two halves, the drive's on the right,
  under its capsule, the Mac's on the left, under the disk's, and below each half what's on that side. The Mac's half is
  the folder you're in, the map as it is but for free space; the drive's is the same folder in the backup folder, and at
  the top of the disk, the whole backup folder. Clicking a half shows that side alone: the Mac's map, or the drive's backup
  folder; the middle goes back to both. At the top of both disks, opening a folder opens it as both disks again; a
  folder only on the drive opens on its half. It's on in Map and Backed Up whenever a drive is chosen. The halves are equal whatever they hold, so an empty or missing folder on the drive is still half the
  ring, and each half is named with its size. Pointing at anything lights its copy on the other half.
- **Map and Backed Up.** In Map both halves wear the map's colours: the Mac's as the map has them, and each thing on the
  drive the colour of its copy on the Mac, or of its folder when the Mac doesn't have it. In Backup the third view, Copies,
  is Backed Up: no duplicates are read, and colour says where each file is. What Backup doesn't move, files under 10 MB
  and what's part of macOS or an app, is grey, "Not for Backup", so amber only means "could go, isn't there". Files are matched by their path from
  the folder and their size: green on both, amber only on the Mac, blue only on the drive, violet moved, red different or
  missing. Inside a folder what's on both comes first, then what's on one side only, then what was moved, then what
  doesn't match, and a folder with more than one of them is cut into one stretch for each, over what it's made of. The
  middle says what the folder holds on the Mac, and on the drive under it. Changes stays the one disk: there's no history
  of the drive.
- **The drive unplugged.** Whenever the drive is plugged in, this Mac's whole backup folder is read once in the
  background, and every folder read since is kept too, by the drive's ID. Unplugged, its
  half is drawn from that, dimmed, with when it was last read; selecting works, and what needs the drive says so.
- **One selection, the actions that fit.** Files can be picked on either half, and both are kept between launches, as
  Free Up's list is; with anything picked, the middle of both disks says how much. The panel lists what can be done with
  them, with how many and how much: for files on this Mac Move, Copy and Keep on Mac; for files on the drive Copy to Mac
  (checked against the hash kept on the Mac), Verify and Delete. Select beside "Only on this Mac" picks
  everything the drive lacks, as far as Backup takes it (10 MB and up). Delete reads both disks again first: a file the
  Mac also has goes only when the Mac's copy matches, by the hash kept on the Mac or by reading both; anything else is
  asked about.
- **Nothing on the drive but the files.** Each file, however small, takes a cluster on exFAT, 128 KB on a large drive, so
  Backup puts nothing beside its copies. The hash of a moved file is in its note on the Mac, and of a copied one in
  Backup's own record. macOS gives what an app makes an attribute the app can't take off, and on exFAT keeps it in a `._`
  file beside it; for the copies and the folders Backup makes, that file goes. A `name.sha256` from before is still read.
- **The drive row.** At the bottom, the disk you're looking at on the left, and in Backup, where files go on the right,
  each a glass capsule with a list of drives and their file systems. The right one can't be the left one, or read-only;
  FAT32 says it can't hold files over 4 GB.
- **Moved files** can be moved back (copied back and proved against the note's hash; the drive keeps its copy),
  verified, or deleted from the drive: the last copy, so only after you confirm it.

## Agents

Headroom is where you and an AI agent look at the same thing. The agent works the way agents do, with commands on the
file system, and Headroom is where it marks what it found, so you see it on the map and decide. It isn't the agent's way
of looking at the disk: there are no tools for browsing.

It speaks the Model Context Protocol, which most agents do. The agent starts `Headroom --mcp`, a helper that carries
lines between the agent and the running app over a socket file in Headroom's own folder. Only you can open that file,
and nothing listens on the network.

- **Quiet until wanted.** Agents start every server they know with every session, so the helper answers the hello and
  lists the tools by itself. Only a tool call reaches for the app, opening it if it's closed, and only then are you
  asked about the agent. When the app quits or a new build takes its place, the next call reaches for it again.
- **You allow each agent.** Headroom asks, naming the agent, the program that started it and who signed that program.
  The name is the agent's own word; the program and its signature are read from the system. You answer Allow, Look
  Only or Don't Allow. What you allowed is remembered by all three, and Agents in the app menu lists it with its access
  and a Remove button. Until you answer, the agent gets no answers.
- **It shows.** While an agent is connected, the map says so, and Agents lists what each one asked for.
- **Selecting.** The agent selects by path with a short reason. That is the same as a click on the ring: one path, to
  the Trash when you clean, by the same rules for what may go. What it found is what's on the disk, so a file newer
  than the map is taken at its word when it's there, and the disk is read again so it shows. Its picks are striped on
  the ring and listed in Free Up in a box under the agent's name, each with its reason. It can tick Headroom's own
  suggestions by id, which is the tick you'd make. It can take back its own picks, never yours.
- **What it's told.** Before or as it selects, what Headroom knows about a path: whether it's protected, what it is,
  and what removing it really frees. A hardlinked or cloned file frees nothing while its other copies stay, so the
  answer names them, and the copy selected last is the one that frees the file.
- **Backup too.** An agent can read Backup's list and the moved files, select big files for it, choose its drive, verify
  moved files, and wait for your Move. Moving, copying, moving back and deleting from a drive are your clicks.
- **The window.** It can bring Headroom forward on what it selected, and have it show another disk.
- **Cleaning is yours, always.** Deleting is destructive, so the click that does it is never an agent's. This isn't a
  rule the agent is asked to keep: the server has no command that deletes, empties the Trash, undoes a clean or presses
  Clean, and the agents' code calls nothing in the app that does. A test reads that code and fails if it ever does, or
  if a tool is added without being named there. You look over what the agent selected and clean in Headroom, with the
  checks and the undo that every clean has. At most, and only in special cases, an agent might one day ask Headroom to
  put its own confirmation in front of you: the answer would still be your click. The agent can wait for your clean:
  its call returns when it's over, with what went to the Trash and what couldn't.

## Truthful accounting

- **One volume, read once.** Scan the Data volume directly, so firmlinks can't double count. Never cross
  a mount point. Sealed system volumes come from APFS itself.
- **The sum must reconcile.** Whatever the scan can't see becomes a labelled Hidden piece, so the ring
  always equals the disk.
- **Hardlinks count once,** in the place you'd think of as home. "Downloads 7 GB, plus 88 GB of hardlinks
  to Media" is the true answer.
- **"Frees" is its own number.** Deleting either copy of a hardlinked file frees nothing.
  Deleting both frees it all. The cleanup preview does this sum for whatever you've ticked.

## Speed

What matters is how soon the picture is right, not when the last small file is counted. On this Mac, 17,000
of the 2.1 million files hold 91% of the bytes, and a folder holding big files usually has few entries. A
folder's listing already says how many entries each subfolder has, so the scan knows what's cheap before
opening it.

1. **First frame.** Free space, macOS and swap come straight from the disk, so they're exact. Everything else
   is one hatched "Not scanned yet" piece.
2. **First look, under two seconds at full power.** Folders are read fewest entries first, with build
   folders and caches last. `~/Media` has 43 files holding 98 GB, so it's done within milliseconds.
3. **The rest, in the background.** Three threads at low priority read the tiny files, and the hatched piece
   shrinks as they go. A size that may still grow reads `64 GB…`, and "so far" where you point at it.
4. **What you're looking at comes first.** Zooming into an unfinished folder sends it to the front of the queue
   at full power, until it's done.
5. **Free Up and Changes want the whole disk.** Opening either one during that first scan puts it back to full
   power. Moving things to the Trash waits for the scan, because the numbers aren't final yet.
6. **With a saved scan,** the map is there at once, and the refresh stays in the background and only reads what has
   changed since. ⌘R means you asked, so that reads everything at full power.

Two details keep it honest while it runs:

- The interface only ever reads a copy of the tables, taken every so often. So hovering, zooming and the inspector
  all work during the scan, and nothing can read a number that's being written.
- A hardlink in Downloads or a cache doesn't claim its file's bytes during the scan, because that's rarely the
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
- The ring draws on a thread of its own, in step with the display, so it never waits for the rest of the window: the
  inspector being laid out or names being placed can take the main thread for 20 to 50 ms, and the ring doesn't miss a
  frame. Only the ring's place in the window comes from SwiftUI. As the inspector slides in or out, the map is a little
  narrower or wider on each frame, and that frame of the ring is drawn in the same transaction as the rest of the window,
  so the numbers in the middle stay in the middle. The window can miss a refresh while it slides, so the ring's own thread
  waits a moment longer before drawing on its own, rather than show the ring where the window isn't yet.
- While the ring is still, its drawing memory is marked as free to take: the glow textures, and every surface but the
  one on screen. Nothing is released or made again, so the next frame costs the same as any other, and if the Mac does
  take it, the ring simply draws again. With the window covered, minimized or hidden, nothing is drawn at all and a running
  scan makes no pictures. Minimized or hidden, the picture on screen can go too. Covered, it stays, because the window can
  come to the front at any moment and mustn't show a gap.
- A finished tree keeps each different set of numbers once. Of 337,000 folders and files here, 180,000 have none at all
  and the rest share 14,000 sets, so 21.6 MB becomes about 2 MB. Names work the same way: 4.2 MB becomes 1.2 MB. A row is
  only copied if something changes it, such as a clean.
- A file with several paths costs one record per path, 512,000 of them here. Files in the same folders say the same
  thing, so those are merged into 67,000, with their bytes added up. Every question asked of them gets the same answer,
  with a seventh as many records to read.
- A refresh only reads what has changed. macOS keeps a journal of the folders that change on each disk, and a map notes
  where the journal was when its reading began. While the app is open it collects the journal as it goes, which costs next
  to nothing. At launch it reads back what happened while it was closed, unless that's over 3 million changes: this Mac
  logs about 7,000 a minute, and going back through a day of them would take longer than reading the disk. The refresh
  reads again the folders the journal names, the ones holding linked files (which of a file's places counts it can change),
  the ones with something changed in the last day, so that day stays exact to the minute, and any that couldn't be read.
  Everything else is copied from the map. A folder found inside one that's read again only counts as the same one if it
  hasn't been touched, moved or renamed since and holds as many things, so a folder put in another's place is read as new.
  Everything is read once a day, and whenever you press ⌘R. A new hardlink to a file in a copied folder could count that
  file twice, so then the refresh is thrown away and everything is read.
- What only the scan needs lives in mapped tables too, so it goes back the moment the scan ends, where a heap allocation
  would stay with the app. While a scan runs, a picture is a copy of the whole tree, so there's never a second one waiting
  behind one nobody has looked at yet.
- The map on screen is never changed where it is. Hovering, the suggestions, the checks and Copies all read it on other
  threads, so when something goes to the Trash or comes back, the change is made to a copy with the same folder numbers,
  and the copy takes the map's place in one step, at most ten times a second during a clean. A copy of a map of 300,000
  folders and files takes about a millisecond. A map read from the disk before such a change is out of date when it
  arrives: it's dropped, and the disk is read again.
- Git is only asked about a project that could be suggested. One worked on in the last month isn't, whatever git would
  say, and the first answer that rules a project out saves asking the rest, with the slowest question last. Here that's 4
  projects out of 20, and 0.3 s instead of 12 s. At launch, other apps' records are read once: the second pass, after the
  scan, only reads what a saved map couldn't have known.
- Updates come from GitHub's list of releases: the newest one with a disk image, if it's newer than this version and you
  haven't said no to it. Putting it in place opens the disk image, checks it holds this app at that version, signed with
  the same certificate, copies it next to the old one, and moves the old one to the Trash and the new one into its place.
  While you're using Headroom, the new version opens before this one quits and is handed the front; otherwise it opens
  once this one has quit. Quitting during the swap waits for it, so there's never a moment with no app.
- Full Disk Access is the one permission Headroom asks for. Without it, Headroom reads nothing at all: no scan, no saved
  map, nothing about apps or files. Reading around the private folders wasn't enough, because a map read with access
  names what's inside them, and looking up any of it brings up a prompt. The ring shows what the disk itself reports, and
  a guide explains what's private and where to switch access on, once per version unless you say not now. Every version is signed with one certificate made for Headroom, rather than ad hoc, so macOS
  sees each one as the same app: access granted once survives updates, and the updater can tell a real update from
  anything else. It isn't a developer certificate, so no name is in it, and macOS still asks you to open the first one.
- The inspector only makes the rows you can see.
- Looking closely at one folder has its own walk: `getattrlistbulk` on up to six threads, with one pass collecting the
  folder's size, its newest change, its largest file and its files with more than one path. While you're ticking things, a
  look from the last minute is used again. Check Again, coming back to the app and the clean itself always look afresh.
- Moving something to another disk reads every file back from that disk to compare it. Each file is sent to the disk for
  that, but making the disk empty its own cache happens once, at the end. That step takes about 10 ms and covers every file
  written so far, and once per file it was nine tenths of the work. The original stays where it is until it has happened.
- Finding a file's other copies goes up from the deepest folder and looks at each folder once, so 1,500 clones cost little
  more than a few. Going deepest first also means one answer, whatever order the copies were found in, with nothing named
  twice. The biggest copy comes first, because that's the one the inspector names.
- A folder's thumbnails are asked for together, and each shows as soon as it's ready.
- Finding duplicates starts from sizes already in the map, so a file with no other of its size is never opened. Files of one
  size are read side by side, a piece at a time, on four threads, biggest sets first: the first 16 KB, then the last 16 KB,
  where many files that start alike differ, then the middle in pieces growing to 4 MB. A file drops out the moment it's like
  no other, so most cost one small read, and nothing is read twice. What's left at the end is the same byte for byte, with no
  hash to take on trust, and a file that changed while it was read drops out. Reads skip the file cache, so what you have open
  stays fast. Each file is remembered with its size, date and set, so a later look reads only sets with something new.
- Aliases are counted in each folder as the scan reads it, in the numbers that add up the tree, which a refresh already copies.
  So finding them opens only the folders that hold one, and reads where each points then.

Measured on this Mac, an M5 MacBook Air with 2.1 million files and a 494 GB disk, without Full Disk Access:

| | |
|---|---|
| Launch to a first frame with the disk's numbers | About 200 ms |
| First launch: half the bytes placed | 0.4 s |
| First launch: placed after one second | 72–81% |
| First launch: everything read | 5.6 s at full power from start to end, with the disk's records already in memory. Reading the rest quietly after the first look took 7.7 s |
| With a saved scan: the map on screen | The saved scan loads in 10–25 ms |
| With a saved scan: the refresh | 3.3 s at low priority, reading 12% of the folders again and copying the rest, where reading them all quietly took 8.6 s. Asking the journal what changed while the app was closed took 0.02 s. With Full Disk Access, 1.4 million files |
| A refresh at full power | 1.4 s, against 4.0 s to read everything just after, on the same 1.4 million files with Full Disk Access, and with the same disk total. The only folders that differed were ones changing between the two |
| ⌘R, at full power | 6.9 s, against 40 s for `du` on the same data, and the scan also collects kinds, dates, links and clones |
| At rest, window on screen or covered | 0.0% CPU, 130–150 MB of memory |
| At rest, window hidden | 0.0% CPU, about 110 MB of memory |
| While the ring moves | About 220–260 MB more for drawing, which goes back about a quarter of a second after it stops |
| A refresh, while it reads | Under 150 MB of memory, about 360 MB at the very end if the ring moves |
| First launch, at the peak | 450–480 MB of memory, with a copy of the tree for each new picture |
| The saved scan on disk | 3.2 MB for the whole map, saved in 0.08 s and read back in about 10 ms, and at most about 2 MB of snapshots |
| The app | 6.7 MB, of which the icon is 4.4 MB |
| Building the ring | Under 1 ms |
| Pointing across the ring, zooming, switching tabs | No frame of the ring late at 60 Hz, where 1 to 3 in a hundred were |
| The inspector coming and going | The ring within half a point of the middle of the map on every frame, and the numbers in its middle within about a point of it. The slide shows 10 to 12 frames in about 0.22 s |

And with Full Disk Access, for what happens after the scan:

| | |
|---|---|
| Size of `~/Library`, 376,000 files | 1.7 s |
| Size of `~/dev` | 0.55 s |
| Checking 47 things, the first time | 0.35 s |
| Checking them again | 0.2 s |
| Checking them while you tick | 9 ms |
| Copying 1,000 small files, compared and on the disk for good | 0.9 s |
| Finding the other copies of 1,500 clones | About 30 ms |
| Six thumbnails | About 160 ms |
| Finding duplicates among 465 files of the same sizes, 5.6 GB, none of it in the file cache | 1.3 s, reading at 4.2 GB/s on four threads, for 152 sets. Ten files alike but for their last byte cost two 16 KB reads each |
| Copies again, nothing changed | The sets come back from memory, with nothing read, in under a millisecond |

The scan's limit is APFS itself: about 15 µs per file in the kernel, whichever attributes are requested. Folders
store no total size, and Spotlight only knows part of the disk. So the design makes the wait not matter, rather than
chasing a faster scan.

## What it looks like

Near-black, with the ring as the only source of light. Real Liquid Glass (`glassEffect`), not an
imitation, floats over the ring and refracts it. The toolbar and the inspector are macOS's own, so they look and move
as they do in any Mac app. Numbers roll instead of snapping. The ring moves on springs. With Reduce Motion, the
ring dissolves from one picture to the next instead of zooming, numbers change in place, and nothing springs past where
it's going. VoiceOver reads the ring as a list of what's in the folder you're in.

## Specs

The parts below have been redone more than once, each time undoing something decided before. What's written here is
decided: every value, and why. **Change these only when the owner asks, and in the same change update the spec: the
value, and a line in its decision log with the date and the reason.** A value this section doesn't mention isn't free
to change either; ask. Before touching one of these parts, read its spec and its log.

### The middle of the ring

The middle answers one thing at a glance: how much, of what. It's a number, a name above it, a line under it, and an
icon. Nothing in it moves when what it says changes, or as the pointer does.

Everything is measured in `u`, the side of the square the middle is drawn in: 0.86 of the hole across, where the hole
is 0.34 of the ring's radius (`CentreGrid` in `MapLabels.swift`). In a 1400 × 900 window `u` is about 176 points.
Positions are of each part's middle, from the ring's middle, downward positive.

**Places**

| Part | Where | Notes |
|---|---|---|
| Icon | centred at −0.31 u | Fixed: the same place in every state, whatever the name below it |
| Name | a room from −0.249 u to −0.100 u (0.149 u high), text at its foot | One line sits right on the number; a second line grows upward toward the icon |
| Number | its digits centred at 0, frame 0.28 u high | The digits' capitals reach ±0.082 u |
| Under the number | from +0.103 u down, 0.2 u of room, text at its top | Lines 0.015 u apart |

The name's foot and the first line's capitals are each 0.035 u (about 7 points) from the digits: the name, the number
and the line under it read as one group. Everything is inside the hole; where the icon is, the hole is still 0.95 u
wide.

**Sizes.** Three text sizes a step of ×1.2 apart, all far below the number, so there are two levels: the number, and
what's said about it.

| Text | Size | Weight | Colour |
|---|---|---|---|
| Number, digits | 0.235 u, rounded, digits of equal width | semibold | white, or the state's colour (below) |
| Number, unit | 0.105 u, rounded | semibold | white at 0.55 |
| Name | 0.072 u | semibold | white at 0.95 pointing, 0.92 at rest |
| The line under the number while pointing | 0.072 u, as large as the name | medium (semibold for links and changes) | below |
| Detail | 0.060 u | medium | white at 0.5–0.55 |
| Third line | 0.050 u | medium or semibold | white at 0.36, or its own colour |
| Icon | a symbol at 0.060 u, regular | | white at 0.5 |

**What each state says**

| State | Icon | Name | Number | Under it |
|---|---|---|---|---|
| Pointing at something | its kind (below) | its name | its size | One line, as large as the name: its other paths (amber, semibold, up to two lines), else when it was last used, else in Changes what changed (semibold, in the view's colours). While a scan is under way: "so far" or "not scanned yet" |
| The whole disk, at rest | the drive | the disk's name | free space (green when Free Up has something to clean: the free space after) | "free of 494 GB" or "free after cleaning"; then one of: what's pointed at in the panel, in its colour; "+X" in green; the change since yesterday with an arrow (green up, salmon down); "N% full" |
| Inside a folder | its kind | "‹" (0.050 u bold, white at 0.42) and its name | its size | its share of the disk, or "so far", or which side of both disks; then "+ X moved" if files were moved out |
| Both disks (Backup) | none | the folder's or disk's name | on this Mac, or what's selected in blue | "on this Mac" or "N selected"; then what's on the drive |
| Changes | none | none | how much changed, with its sign and colour | "free space since …" or "modified in …"; "by date modified" |
| Copies (Free Up) | none | none | what duplicates take, or a set's in its colour | "in duplicates", or the set's name; then "reclaimable" or how many are elsewhere |

**The name, when it doesn't fit.** The name is always the real name. In order, the first that fits is used: the whole
name on one line; the whole name on two lines at 0.062 u within 0.78 u, if it's 48 characters or fewer; then the name
cut with "…" where its neighbours say the same (see *Names on the ring*), each on one line and then on two; last, the
shortest cut form, cut once more in the middle. Nothing is ever written that isn't in the name, in its order.

**Icons.** The drive for the disk; a house for your home folder; symbols for Desktop, Documents, Downloads, Movies,
Music, Pictures, Library, Public (in your home folder) and Applications; a folder; the Trash; a gear for macOS's own
parts; a dashed circle for free space; an eye with a stroke for what can't be read; "…" for smaller items; for files
their kind (film, waveform, photo, disk image, archive, code, PDF, text, document). An app shows its own icon, 1.6
times the symbol's size, read off the main thread with a plain app symbol until it's read.

**Never**
- A share line ("14% of Season 01 · 2.4% of the disk") or anything else the ring already shows.
- A part that moves when the text changes: every part is placed on its own, never stacked after another.
- More than one line under the number while pointing.
- Any text size other than the three above and the number's.
- Laying it out in the window's own view tree: it changes with every pointer move, and a change in the window's tree
  costs a pass over the whole window. It's `CenterIsland`, a view tree of its own.

**Decision log**

| Date | Decision | Why |
|---|---|---|
| 2026-11-06 | Every part has a fixed place; long text shrinks, then is cut | The middle moved as you pointed at things |
| 2026-11-06 | The line under the size says when you last used it, and is as large as the name | It repeated the share of the disk the ring already shows |
| 2026-11-22 | The middle in a view tree of its own; digits roll only when the same thing changes size | Hovering cost too much; numbers rolling between different things read as change |
| 2026-11-23 | An icon above the name, fixed in place | Asked for after the blind build; "the icon should be fixed in place" |
| 2026-11-23 | A share line was added, then removed again | "Way too much info": it broke the 2026-11-06 decision |
| 2026-11-23 | The line under the number briefly made smaller than the name, then put back | It broke the 2026-11-06 decision |
| 2026-11-23 | The grid above: the name sits on the number, three text sizes, the disk's name at rest | The parts had no fixed grid: seven sizes, a floating name, an icon pushed up by two-line names. The disk's name at rest was proposed by Claude so every state has the same parts; the owner hasn't ruled on it |

### The path bar

The row along the bottom of the map: the disk at the left, where you are in the middle, and in Backup where its files
go at the right. It's 34 points high (`DriveRow.height`), and everything in it is that height.

- **Where you are**: in a glass capsule, centred in the map with 180 points kept clear at each side. A button for each
  folder from the disk down, 12 points; the folder you're in semibold, white at 0.95; the others medium, white at 0.6;
  chevrons 9 points bold, white at 0.35. Too long, it folds: the disk, "…", the last two; then the disk, "…", the last.
  Shown once you're inside a folder; on the whole disk, only while something is pointed at. It stays in place and
  fades in and out over 0.15 s.
- **The way to what's pointed at**: just after the capsule, outside the glass, so the glass never changes size as the
  pointer moves. Each step a chevron (white at 0.2), a 7-point dot in the piece's colour as drawn, and its name (12
  points, medium, white at 0.45). What's pointed at is written with its cut forms (see *Names on the ring*), as short as
  it needs to be before a folder is left out; folders nearest it stay, those nearest the top fold into "…". It may
  run 150 points past the bar's right edge, except in Backup, where the drive's capsule is.
- **Never** in the window's own view tree (it's `PathIsland`): a path bar there cost 15% more of the main thread while
  pointing, and a resizing glass capsule caused dropped frames.

| Date | Decision | Why |
|---|---|---|
| 2026-11-23 | The live path, with colour dots | From the blind build: "live path is also good idea, with the color" |
| 2026-11-23 | Height 34, as the drive's capsule | 28 beside 34 in one row read as unaligned |

### Names on the ring

- **On pieces**: only on the first four rings; the outer rings are for the shape. The first ring is set straight,
  12.5 points semibold with the size under it at 11 points, digits of equal width; free space 14 and 13. From the second
  ring out a name runs along its piece, clockwise, turned in the bottom third so it's never upside down, at 11 and 9.5.
- **At the sides**: the name at 12 points medium (white at 0.88) and its size at 11 regular (white at 0.5), rows 35
  points apart, the column 34 points out from the ring. Sizes only: no percentages. What can't be read ("Hidden") is
  named here, so the sizes add up.
- **A name that doesn't fit** is the real name cut with "…" (`ShortNames`): it keeps its start, the part that tells it
  apart from its neighbours, and its extension, and leaves out what its neighbours share or the folders around it
  already say. For `Northwater Mysteries (2021) - S01E03 - 1080p WEB-DL.mkv` among its season: `Northwater…S01E03 - 1080p
  WEB-DL.mkv`, then `Northwater…S01E03…mkv`, then `North…S01E03…mkv`. It's cut only between words, never inside a pair of brackets, and never around a number alone
  (`IMG_4821.HEIC`, and `Harbour Lights (2020)` beside `Harbour Lights Reunion (2022)`, stay whole). Neighbours are written alike: as far cut as the one with
  least room needs. A name at the side uses the longest form that fits its column; if none does, the whole name is cut
  once, in the middle. **Never** cut twice, never rewritten, never reordered.

| Date | Decision | Why |
|---|---|---|
| 2026-11-22 | First ring straight; further out along the arc, clockwise; bottom third turned; a smaller font | "Curved are okay for level 2 and deeper … always clockwise" |
| 2026-11-23 | Names cut with "…" around what tells them apart, not rewritten | "You cant just replace the filename … show sho…s01e01…mkv" |
| 2026-11-23 | Names back to the first four rings; no percentages at the sides | "Way too much info and garbage" |

### Pointing at a piece

- The piece pointed at lifts out and glows, and has a border just inside its edge: 1 point, its own colour 40% of the
  way to white. A piece too thin to see also gets a tick, 2 points wide, just outside its outer edge.
- A selected piece is striped with a 1-point edge of the same kind.

| Date | Decision | Why |
|---|---|---|
| 2026-11-23 | A border on the piece pointed at, in every way of pointing | "Make the hover perfect … with the border around it" |
| 2026-11-23 | 1 point, softer, not 1.5 points | "Isn't it very thick?" |

### Colours

- **Palettes** (View › Palette, for trying them): Spectrum, the default, gives each branch a hue a golden angle from
  the last; Cool and Warm draw from a range of hues; Colour-Blind Safe (Okabe and Ito's), Pastel and Mono are set lists.
  Each palette keeps its own memory of which folder has which colour.
- **Glow** can be turned off (View › Glow), which also skips the work of drawing it.
- A branch under 1.5% of what's in the middle is drawn quiet, in a muted tone of what holds it, instead of a colour of
  its own.

| Date | Decision | Why |
|---|---|---|
| 2026-11-23 | Palettes, dynamic and fixed; glow as a switch in the menu | Asked for, "for testing" |
| 2026-11-23 | Quiet slivers | From the blind build's review, chosen by the owner |
