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

To drive the chart from code, keep a ``SunburstChart`` and show that with ``Sunburst``. Everything a person does with the
pointer has a call, ``SunburstChart/summary(limit:)`` says what's on the ring in words, and
``SunburstChart/picture(width:height:scale:dithered:)`` draws it without a window.

## Topics

### Essentials

- ``Sunburst``
- ``SunburstChart``
- ``ItemTree``
- ``SunburstTree``
- ``SunburstStretch``

### Reading a chart

- ``SunburstSummary``

### Colour and text

- ``BranchColours``
- ``Lab``
- ``SunburstFormat``

### Building your own view

- ``RingLayout``
- ``Piece``
- ``PieceStyle``
- ``RingSizes``
- ``RingStyle``
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
