# ``SunburstKit``

A sunburst chart for macOS, drawn with Metal: any tree as rings around a middle, each piece's angle set by its size.

## Overview

Point at a piece to light its branch, click to zoom into it, and click the middle to go back out. The chart doesn't own
your data: hand it the items you already have as an ``ItemTree``, or answer ``SunburstTree`` from a tree of your own, and
you decide what the colours mean, what's marked and what a click opens.

```swift
let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
Sunburst(tree, sizeText: { "$\($0 / 100)" })
```

Every chart is made of the same parts, from the middle out: a centre, an optional split, thin bands, the rings and a dial
(``SunburstParts``). Each part always means the same thing, so whoever has read one chart can read another. The tree says
what each node is (``SunburstRole``), which sets its look anywhere.

```swift
// A whole disk: what it's made of in a thin band, then six rings of folders.
chart.parts = SunburstParts(bands: [.init()], rings: .init(RingSizes(depth: 6)))
```

To drive the chart from code, keep a ``SunburstChart`` and show that with ``Sunburst``. Everything a person does with the
pointer has a call, ``SunburstChart/summary(limit:)`` says what's on the ring in words, and
``SunburstChart/picture(width:height:scale:dithered:)`` draws it without a window. What an app does its own way, it says
through the chart's hooks: ``SunburstChart/alsoLight``, ``SunburstChart/onClick``, ``SunburstChart/namer`` and the centre
slot of ``Sunburst``.

## Topics

### Essentials

- ``Sunburst``
- ``SunburstChart``
- ``ItemTree``
- ``SunburstTree``
- ``SunburstRole``

### Parts

- ``SunburstParts``
- ``RingSizes``
- ``RingStyle``
- ``SunburstStretch``

### The centre and names

- ``SunburstReadout``
- ``SunburstReadoutView``
- ``SunburstNumber``
- ``SunburstNamer``

### Reading a chart

- ``SunburstSummary``

### Colour and text

- ``BranchColours``
- ``HueMemory``
- ``SunburstHues``
- ``Lab``
- ``SunburstFormat``

### Building your own view

- ``RingLayout``
- ``Piece``
- ``RingLight``
- ``SunburstNodeSet``
- ``SunburstNodes``
- ``SunburstEngine``
- ``RingTransition``
- ``ZoomMapping``
- ``SunburstView``
- ``RingPlace``
- ``Polar``

### Names on the ring

- ``LabelPlacer``
- ``LabelArea``
- ``LabelLight``
- ``SunburstLabel``
- ``SunburstLabels``
