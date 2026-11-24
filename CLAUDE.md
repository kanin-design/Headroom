# Headroom

## The design spec is decided: read it, keep it

`DESIGN.md`, section *Specs*, records every decided value for the parts of the window that have been redone before:
the middle of the ring, the path bar, the window's title, switching between Free Up and Backup, names (on the ring and
in lists), pointing at a piece, and colours. Each part has a decision log
of what the owner decided, when and why. The values live in code in one place each (the middle's in `CentreGrid`,
`Sources/Headroom/UI/MapLabels.swift`).

- Before changing anything in one of these parts, read its spec and its decision log. Where a part has no spec, read
  its file's commit history for decisions before changing it.
- Change a specced part only when the owner asks. A value the spec doesn't mention isn't free to change either: ask.
- When the owner asks for a change to the look, update `DESIGN.md` in the same change: the new value, and a dated line
  in the part's decision log with the reason in the owner's words.
- A change of your own that the owner didn't ask for goes in the log marked as a proposal until the owner rules on it.
- Before calling a change done, check the build against the spec, in a picture: the spec's numbers are the code's.
- `DESIGN.md` is public: examples use made-up names, never files from the owner's disk.

Why: the middle of the ring was reworked again and again, each time undoing what was decided before (a share line the
owner had removed came back; a line made as large as the name was shrunk), because the decisions were only in commit
messages.

## The code standard is Swift's own linter

Before calling a code change done, run `swift format lint -r --configuration .swift-format Sources/Headroom
Packages/SunburstKit/Sources Tests`: it must print nothing. `swift format format -i -r` with the same configuration and
paths fixes the layout. `.swift-format` is the toolchain's defaults with 4-space indents, 150-character lines and no force
unwraps or `try!`, and it keeps two of the project's habits: a short body on one line with semicolons, and related values
in one `let`. Where a rule is set aside for one line, the comment above it says why. `.swift-format-ignore` leaves out
`ShaderSource.swift`, which is generated.
