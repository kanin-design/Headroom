# SunburstKit

A sunburst chart for macOS, drawn with Metal: a tree as rings around a middle, each piece's angle set by its size. It
lays the tree out, draws it with a soft glow, moves smoothly from one picture to the next (zooming in and out, new
sizes, new colours), lights what's under the pointer, and places names on and beside the pieces.

It doesn't own the tree. The host keeps its own tree and answers questions about it through a small protocol, and
decides what the colours mean, what's marked, which node is in the middle, and what a click does.

## The input: `SunburstTree`

Nodes are `UInt32` numbers. Node 0 is the root; 0 as a child or sibling means none. Children are listed biggest first.

Required:

| Member | What it says |
| --- | --- |
| `firstChild(of:)`, `nextSibling(of:)`, `parent(of:)` | The shape of the tree |
| `size(of:)` | Everything in the node: sets its angle |
| `ownSize(of:)` | What the node holds outside its children, drawn with what's too small to draw alone |
| `isFolder(_:)` | Only folders chain: a folder that's nearly all one subfolder is drawn as one piece with it |
| `style(of:)` | `.folder`, `.file`, `.free`, `.hidden` (hatched), `.ghost` (faint) |
| `nameKey(of:)` | A number from the name, the same from one tree to the next, so pieces glide to their new places |

Optional, with defaults that draw a plain sunburst:

| Member | Default | What it does |
| --- | --- | --- |
| `hasHalves`, `isHalf(_:)` | off | The root is two halves of the ring whatever their sizes, such as one disk beside another |
| `hasBand` | off | A thin band around the middle of the root, with the rings outside it |
| `rootRank(of:)` | 0 | Around the root, lower ranks first, then biggest first |
| `isPlainShape(_:)` | false | A shape of its own in the first ring, such as free space, reaching out as far as the rest does on average |
| `hasGroups`, `group(of:)` | off | Things in a folder are drawn by group first, and a folder that holds more than one group is drawn as a stretch for each |
| `isStillGrowing(_:)` | false | Still being read: doesn't chain yet |

The rest of a picture is given when it's made:

```swift
let layout = RingLayout.build(tree: tree, focus: node,           // the node in the middle
                              colorer: { node in colour(node) },  // linear Display P3; `Lab` helps make good ones
                              planned: { node in marked(node) },  // striped
                              sizes: RingSizes(depth: 6, style: .tapered))
```

## The output

- `MapEngine`: holds the picture on screen and everything that moves. `apply(layout, .zoomIn(mapping))` and the other
  `RingTransition`s change the picture; `setEmphasis(primary:related:ancestors:tint:)` lights what's hovered;
  `setCalm`, `setGlow`, `setGhost`, `setPreview` set the rest.
- `SunburstView`: the `NSView` that draws it, on a thread of its own, only while something moves. Its callbacks:
  `onHover`, `onHoverCovered`, `onClick`, `onCommandClick`, `menuAt`, `onPinch`, `onKey`, `onModifiers`,
  `onVisibility`, and for VoiceOver `accessibilityName`, `accessibilityPicture`, `describePiece`, `onPress`. Points come
  as `Polar` (angle clockwise from 12 o'clock, distance as a share of the radius); `engine.layout.hit(angle:radius:)`
  says which piece is there.
- `RingPlace`: a SwiftUI view that tells the engine where the ring is on each frame of an animation.
- `LabelPlacer` and `SunburstLabels`: where names fit inside pieces and beside the ring, and the SwiftUI layer that
  shows them. What each piece is called is the host's.

## Minimal use

```swift
import SunburstKit
import SwiftUI

struct Chart: NSViewRepresentable {
    let engine: MapEngine
    let tree: MyTree

    func makeNSView(context: Context) -> SunburstView {
        let view = SunburstView(engine: engine)
        view.onHover = { polar in
            let piece = polar.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) }
            engine.setEmphasis(primary: piece, related: piece.map { [$0..<Int(engine.layout.pieces[$0].end)] } ?? [])
        }
        engine.apply(RingLayout.build(tree: tree, focus: 0, colorer: { _ in SIMD3(0.4, 0.5, 0.9) }), .appear)
        return view
    }

    func updateNSView(_ view: SunburstView, context: Context) {}
}

// In the window: the view, and where the ring sits in it.
GeometryReader { geometry in
    ZStack {
        Chart(engine: engine, tree: tree)
        RingPlace(center: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2),
                  radius: min(geometry.size.width, geometry.size.height) * 0.4, size: geometry.size,
                  engine: engine, view: { nil })
    }
}
```

## The shaders

`Shaders.metal` is compiled when the app starts, from its source, so it isn't part of the Swift target. Copy it into
the app's `Contents/Resources` when the app is put together, or pass its URL to `MapEngine(shaders:)`.
