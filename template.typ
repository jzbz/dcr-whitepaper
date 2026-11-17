// Decred technical whitepaper: document template and authoring helpers.
//
// Every chapter starts with `#import "../template.typ": *` and uses the
// helpers below so that rules, algorithms, tables and source references look
// the same throughout the document.

// ---------------------------------------------------------------------------
// Palette and fonts
// ---------------------------------------------------------------------------

#let palette = (
  ink: rgb("#091440"), // Decred dark blue
  blue: rgb("#2970ff"), // Decred key blue
  turquoise: rgb("#2ed6a1"), // Decred turquoise
  teal: rgb("#0c9c78"), // darker turquoise, legible as text
  orange: rgb("#ed6d47"),
  text: rgb("#1c2233"),
  muted: rgb("#596d81"),
  hairline: rgb("#d5dbe5"),
  wash: rgb("#f3f6f9"),
  wash-blue: rgb("#eef4ff"),
  wash-teal: rgb("#eafaf5"),
  wash-orange: rgb("#fdf1ec"),
)

#let serif = ("Libertinus Serif",)
#let sans = ("IBM Plex Sans",)
#let mono = ("IBM Plex Mono", "DejaVu Sans Mono")

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#let appendix-mode = state("appendix-mode", false)

// Numbers a per-chapter item ("7.3", "B.2") from the current chapter number.
#let chapter-scoped(n) = {
  let ch = counter(heading).get().first()
  let fmt = if appendix-mode.get() { "A.1" } else { "1.1" }
  numbering(fmt, ch, n)
}

// ---------------------------------------------------------------------------
// Inline helpers
// ---------------------------------------------------------------------------

// A reference to a place in the dcrd source tree, e.g.
// `#src("internal/blockchain/validate.go", "checkBlockHeaderSanity")`.
#let src(path, ..symbols) = {
  let syms = symbols.pos()
  // Not boxed: an unbreakable reference at the end of a justified paragraph
  // forces the lines before it to be stretched. It may break at its spaces.
  // No break next to the separator, so no line starts or ends on it. The path
  // may still break after a slash and the symbols after a comma.
  text(font: mono, size: 0.78em, fill: palette.muted, hyphenate: false, {
    path
    if syms.len() > 0 {
      [\u{00a0}·\u{00a0}]
      syms.join(", ")
    }
  })
}

// A Decred Change Proposal, e.g. `#dcp(11)` renders "DCP-0011".
#let dcp(n) = {
  let s = str(n)
  let id = "DCP-" + "0" * (4 - s.len()) + s
  link(
    "https://github.com/decred/dcps/blob/master/dcp-"
      + "0" * (4 - s.len())
      + s
      + "/dcp-"
      + "0" * (4 - s.len())
      + s
      + ".mediawiki",
    text(font: sans, size: 0.9em, weight: "medium", fill: palette.blue, id),
  )
}

// The name of a network parameter (a field of chaincfg.Params), e.g.
// `#param("TicketMaturity")`.
#let param(name) = text(font: mono, size: 0.88em, fill: palette.teal, hyphenate: false, name)

// A named constant that is not a per-network parameter.
#let const(name) = text(font: mono, size: 0.88em, fill: palette.ink, hyphenate: false, name)

// Hex data that is allowed to break across lines at any position.
#let hex(s) = text(
  font: mono,
  size: 0.85em,
  // A short value is never broken. A long one may break anywhere except in
  // its first and last eight digits, so no stub of a digit or two is left.
  if s.len() <= 16 { box(s) } else {
    let c = s.clusters()
    box(c.slice(0, 8).join()) + sym.zws + c.slice(8, c.len() - 8).join(sym.zws) + sym.zws + box(c.slice(c.len() - 8).join())
  },
)

// Normative keywords.
#let MUST = text(font: sans, size: 0.86em, weight: "semibold", tracking: 0.03em, "MUST")
#let MUSTNOT = text(font: sans, size: 0.86em, weight: "semibold", tracking: 0.03em, "MUST NOT")
#let SHOULD = text(font: sans, size: 0.86em, weight: "semibold", tracking: 0.03em, "SHOULD")
#let SHOULDNOT = text(font: sans, size: 0.86em, weight: "semibold", tracking: 0.03em, "SHOULD NOT")
#let MAY = text(font: sans, size: 0.86em, weight: "semibold", tracking: 0.03em, "MAY")

// A cross-reference that degrades gracefully when the target is in a chapter
// that is not part of the current (partial) build. `key` is a label name.
#let xref(key) = context {
  let target = label(key)
  if query(target).len() > 0 {
    ref(target)
  } else {
    text(fill: palette.orange, font: mono, size: 0.85em, "⟨" + key + "⟩")
  }
}

// A cross-reference to a whole chapter by its key, e.g. `#chref("script")`
// refers to the chapter labelled `<ch:script>`.
#let chref(key) = xref("ch:" + key)

// ---------------------------------------------------------------------------
// Block helpers
// ---------------------------------------------------------------------------

#let source-line(srcs) = {
  if srcs == none { return }
  let items = if type(srcs) == array { srcs } else { (srcs,) }
  // One reference: "path · symbol, symbol". The path stays with its first
  // symbol and a break is allowed only after a comma, so a wrapped line never
  // starts or ends on a separator and a path is never split at a slash.
  let one(item) = {
    if type(item) != str { return item }
    let parts = item.split(" · ")
    if parts.len() < 2 { return box(item) }
    let syms = parts.slice(1).join(" · ").split(", ")
    let n = syms.len()
    // Each comma sits inside the box before it, so it cannot hang past the
    // right edge of a right-aligned line.
    box(parts.first() + " · " + syms.first() + if n > 1 { "," })
    for (i, s) in syms.slice(1).enumerate() { [ ] + box(s + if i + 2 < n { "," }) }
  }
  // Roughly the number of characters that fit on one line of a rule box.
  let fits = items.map(i => if type(i) == str { i.len() } else { 40 }).sum() + 3 * (items.len() - 1) + 6 <= 100
  v(0.65em, weak: true)
  set par(justify: false, leading: 0.4em)
  align(right, text(font: mono, size: 6.6pt, fill: palette.muted, hyphenate: false, {
    [dcrd: ]
    if fits {
      items.map(one).join([ #h(0.2em)|#h(0.2em) ])
    } else {
      // Too long for one line: one reference per line.
      items.map(one).join(linebreak())
    }
  }))
}

// A numbered, normative consensus rule.
//
//   #rule("Ticket maturity", src: "blockchain/stake/tickets.go · connectNode")[
//     A ticket #MUST ...
//   ] <rule:stk-maturity>
#let rule(title, src: none, body) = figure(
  kind: "rule",
  supplement: [Rule],
  caption: title,
  {
    body
    source-line(src)
  },
)

// A numbered algorithm. The body is normally a fenced code block.
//
//   #algorithm("Ticket lottery", src: "blockchain/stake/lottery.go · findTicketIdxs")[
//     ```python
//     ...
//     ```
//   ] <alg:stk-lottery>
#let algorithm(title, src: none, body) = figure(
  kind: "algorithm",
  supplement: [Algorithm],
  caption: title,
  {
    body
    source-line(src)
  },
)

#let callout(label-text, colour, wash, body) = block(
  width: 100%,
  breakable: true,
  fill: wash,
  stroke: (left: 2pt + colour),
  inset: (left: 10pt, right: 10pt, top: 7pt, bottom: 8pt),
  radius: (right: 2pt),
  spacing: 1.1em,
  {
    // Sticky, so the label is never left alone at the foot of a page.
    block(sticky: true, above: 0pt, below: 0.45em, text(font: sans, size: 7.6pt, weight: "semibold", tracking: 0.08em, fill: colour, upper(label-text)))
    set text(size: 0.95em)
    body
  },
)

// Informative remark.
#let note(body) = callout("Note", palette.muted, palette.wash, body)

// Why a rule is the way it is.
#let rationale(body) = callout("Rationale", palette.teal, palette.wash-teal, body)

// A rule that changed through a consensus vote or a historical quirk.
#let history(body) = callout("History", palette.blue, palette.wash-blue, body)

// A trap for implementers: behaviour that is easy to get wrong.
#let pitfall(body) = callout("Implementation pitfall", palette.orange, palette.wash-orange, body)

// A test vector block. The body is normally a fenced code block or a table.
#let vector(title, body) = block(
  width: 100%,
  breakable: true,
  stroke: 0.5pt + palette.hairline,
  radius: 2pt,
  inset: 8pt,
  spacing: 1.1em,
  {
    block(sticky: true, above: 0pt, below: 0.5em, {
      text(font: sans, size: 7.6pt, weight: "semibold", tracking: 0.08em, fill: palette.muted, upper[Test vector])
      h(0.6em)
      text(font: sans, size: 8.6pt, weight: "medium", fill: palette.ink, title)
    })
    set text(size: 0.92em)
    body
  },
)

// A table describing a serialized structure. Each row is
// (field, type, size in bytes, description).
//
//   #fieldtable(
//     caption: [Block header],
//     ("Version", "int32", "4", [Block version.]),
//     ...
//   ) <tab:enc-header>
// ---------------------------------------------------------------------------
// Diagram primitives. Coordinates are in centimetres from the top left of the
// enclosing `block(width: .., height: ..)`.
// ---------------------------------------------------------------------------

#let dg-box(x, y, w, h, body, fill: palette.wash-blue, stroke: palette.ink) = place(dx: x * 1cm, dy: y * 1cm, rect(
  width: w * 1cm,
  height: h * 1cm,
  radius: 3pt,
  stroke: 0.8pt + stroke,
  fill: fill,
  inset: 3pt,
  align(center + horizon, {
    set par(justify: false, leading: 0.42em)
    set text(font: sans, size: 7.8pt, fill: palette.ink)
    body
  }),
))
#let dg-seg(x1, y1, x2, y2, stroke: 0.8pt + palette.ink) = place(line(
  start: (x1 * 1cm, y1 * 1cm),
  end: (x2 * 1cm, y2 * 1cm),
  stroke: stroke,
))
#let dg-arrow(x1, y1, x2, y2, colour: palette.ink) = {
  let ang = calc.atan2(x2 - x1, y2 - y1)
  let ux = calc.cos(ang)
  let uy = calc.sin(ang)
  let l = 0.22
  let w = 0.085
  dg-seg(x1, y1, x2 - l * ux, y2 - l * uy, stroke: 0.8pt + colour)
  place(polygon(
    fill: colour,
    stroke: none,
    (x2 * 1cm, y2 * 1cm),
    ((x2 - l * ux + w * uy) * 1cm, (y2 - l * uy - w * ux) * 1cm),
    ((x2 - l * ux - w * uy) * 1cm, (y2 - l * uy + w * ux) * 1cm),
  ))
}
// Text in a box of width `w` whose top left corner is at (x, y).
#let dg-text(x, y, w, body, align-to: center, colour: palette.text, size: 7.6pt) = place(dx: x * 1cm, dy: y * 1cm, box(
  width: w * 1cm,
  align(align-to, {
    set par(justify: false, leading: 0.42em)
    set text(font: sans, size: size, fill: colour)
    body
  }),
))

#let fieldtable(caption: none, ..rows) = figure(
  caption: caption,
  table(
    columns: (auto, auto, auto, 1fr),
    align: (left, left, right, left),
    table.header([Field], [Type], [Bytes], [Description]),
    ..rows
      .pos()
      .map(r => (
        text(font: mono, size: 0.92em, r.at(0)),
        text(font: mono, size: 0.92em, r.at(1)),
        r.at(2),
        r.at(3),
      ))
      .flatten()
  ),
)

// A part divider page.
#let part(title, summary: none) = {
  pagebreak(weak: true)
  counter("part").step()
  // Marks the page so that it gets no running header.
  [#metadata("part-page") <part-page>]
  v(1fr)
  context text(
    font: sans,
    size: 11pt,
    weight: "semibold",
    tracking: 0.18em,
    fill: palette.teal,
    upper[Part #counter("part").display("I")],
  )
  v(0.6em)
  block(width: 80%, text(font: sans, size: 30pt, weight: "semibold", fill: palette.ink, title))
  v(0.65em, weak: true)
  line(length: 22%, stroke: 2.2pt + palette.turquoise)
  if summary != none {
    v(1.2em)
    block(width: 72%, text(size: 11pt, fill: palette.muted, summary))
  }
  v(2fr)
  pagebreak(weak: true)
}

// Switches chapter numbering to appendix letters.
#let appendices(body) = {
  appendix-mode.update(true)
  counter(heading).update(0)
  set heading(supplement: [Appendix])
  body
}

// ---------------------------------------------------------------------------
// Document template
// ---------------------------------------------------------------------------

#let whitepaper(
  title: [Decred],
  subtitle: none,
  version: none,
  date: none,
  commit: none,
  abstract: none,
  front-matter: true,
  body,
) = {
  set document(title: "Decred: Technical Whitepaper and Protocol Specification", keywords: (
    "Decred",
    "consensus",
    "proof-of-work",
    "proof-of-stake",
    "specification",
  ))

  set page(
    paper: "a4",
    margin: (inside: 27mm, outside: 23mm, top: 27mm, bottom: 27mm),
    header: context {
      let page-no = here().page()
      // No running header on pages that open a chapter or on front matter.
      let openers = query(heading.where(level: 1)).filter(h => h.location().page() == page-no)
      let dividers = query(<part-page>).filter(m => m.location().page() == page-no)
      if openers.len() > 0 or dividers.len() > 0 { return }
      let before = query(heading.where(level: 1).before(here()))
      if before.len() == 0 { return }
      let current = before.last()
      // Front matter (contents and the like) carries no running head.
      if current.numbering == none and before.filter(h => h.numbering != none).len() == 0 { return }
      set text(font: sans, size: 7.6pt, fill: palette.muted, tracking: 0.04em)
      // Unnumbered back matter (the references) shows its title alone.
      let number = if current.numbering == none { none } else {
        numbering(
          if appendix-mode.at(current.location()) { "A" } else { "1" },
          counter(heading).at(current.location()).first(),
        )
      }
      grid(
        columns: (1fr, auto),
        [#if number != none [#text(fill: palette.teal, weight: "semibold", number)#h(0.7em)]#current.body], [Decred Technical Whitepaper],
      )
      v(-0.55em)
      line(length: 100%, stroke: 0.4pt + palette.hairline)
    },
    footer: context {
      set text(font: sans, size: 8pt, fill: palette.muted)
      align(center, counter(page).display())
    },
  )

  set text(font: serif, size: 10.2pt, fill: palette.text, lang: "en", region: "US", number-type: "lining")
  set par(justify: true, leading: 0.64em, spacing: 1.05em, linebreaks: "optimized", justification-limits: (tracking: (min: -0.006em, max: 0.03em)))
  show math.equation: set text(font: "New Computer Modern Math")
  set math.equation(numbering: n => "(" + chapter-scoped(n) + ")", supplement: [Eq.])

  // ---- Headings ----------------------------------------------------------
  set heading(
    supplement: [Chapter],
    numbering: (..nums) => if nums.pos().len() <= 3 {
      numbering(if appendix-mode.get() { "A.1" } else { "1.1" }, ..nums)
    },
  )
  show heading: set text(font: sans, fill: palette.ink, hyphenate: false)
  show heading: set par(justify: false, leading: 0.5em)

  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    // Per-chapter numbering of figures, rules, algorithms and equations.
    counter(figure.where(kind: image)).update(0)
    counter(figure.where(kind: table)).update(0)
    counter(figure.where(kind: raw)).update(0)
    counter(figure.where(kind: "rule")).update(0)
    counter(figure.where(kind: "algorithm")).update(0)
    counter(math.equation).update(0)
    v(18mm)
    if it.numbering != none {
      let label-word = if appendix-mode.get() { "Appendix" } else { "Chapter" }
      text(
        font: sans,
        size: 10pt,
        weight: "semibold",
        tracking: 0.16em,
        fill: palette.teal,
        upper[#label-word #counter(heading).display(it.numbering)],
      )
      v(0.5em)
    }
    block(text(size: 25pt, weight: "semibold", it.body))
    v(0.1em)
    line(length: 18%, stroke: 2pt + palette.turquoise)
    v(9mm)
  }

  show heading.where(level: 2): it => {
    set text(size: 13.5pt, weight: "semibold")
    block(above: 1.9em, below: 0.95em, sticky: true, {
      if it.numbering != none {
        text(fill: palette.teal, counter(heading).display(it.numbering))
        h(0.7em)
      }
      it.body
    })
  }

  show heading.where(level: 3): it => {
    set text(size: 11pt, weight: "semibold")
    block(above: 1.6em, below: 0.85em, sticky: true, {
      if it.numbering != none {
        text(fill: palette.teal, counter(heading).display(it.numbering))
        h(0.7em)
      }
      it.body
    })
  }

  show heading.where(level: 4): it => {
    set text(size: 10pt, weight: "semibold")
    block(above: 1.4em, below: 0.75em, sticky: true, it.body)
  }

  // ---- Raw text ----------------------------------------------------------
  show raw: set text(font: mono, size: 0.88em, ligatures: false)
  show raw.where(block: false): it => box(
    fill: palette.wash,
    inset: (x: 2.2pt, y: 0pt),
    outset: (y: 2.4pt),
    radius: 1.5pt,
    it,
  )
  show raw.where(block: true): it => block(
    width: 100%,
    breakable: true,
    fill: palette.wash,
    stroke: (left: 1.5pt + palette.hairline),
    inset: (x: 9pt, y: 8pt),
    radius: (right: 2pt),
    {
      set text(size: 8.2pt)
      set par(justify: false, leading: 0.56em)
      it
    },
  )

  // ---- Lists, links, quotes ---------------------------------------------
  set list(indent: 0.9em, body-indent: 0.55em, marker: (
    text(fill: palette.teal, sym.bullet),
    text(fill: palette.teal, sym.dash.en),
  ))
  set enum(indent: 0.9em, body-indent: 0.55em)
  // List items are short and often end in a code name: ragged right.
  show list: set par(justify: false)
  show enum: set par(justify: false)
  show link: it => if type(it.dest) == str { text(fill: palette.blue, it) } else { it }
  show ref: set text(fill: palette.blue)
  // A reference to a numbered heading below chapter level reads "Section 7.2".
  show ref: it => {
    let el = it.element
    if el != none and el.func() == heading and el.level > 1 and it.supplement == auto {
      // Number the target as its own chapter or appendix does. The heading's
      // numbering function reads the appendix state where it is called, which
      // here is the place of the reference, so a reference from an appendix
      // back into a chapter would otherwise print a letter.
      let fmt = if appendix-mode.at(el.location()) { "A.1" } else { "1.1" }
      link(el.location(), [Section~#numbering(fmt, ..counter(heading).at(el.location()))])
    } else {
      it
    }
  }
  set footnote.entry(separator: line(length: 22%, stroke: 0.4pt + palette.hairline))
  show footnote.entry: set text(size: 8.2pt)

  // ---- Tables ------------------------------------------------------------
  set table(
    stroke: (x, y) => (
      top: if y == 0 { 0.9pt + palette.ink } else { 0pt },
      bottom: if y == 0 { 0.6pt + palette.ink } else { 0.3pt + palette.hairline },
    ),
    inset: (x: 6pt, y: 4.6pt),
    align: left + top,
  )
  show table: set text(size: 8.6pt)
  show table: set par(justify: false, leading: 0.52em)
  show table.cell.where(y: 0): set text(font: sans, size: 8pt, weight: "semibold", fill: palette.ink)

  // ---- Figures -----------------------------------------------------------
  set figure(numbering: n => chapter-scoped(n), gap: 0.9em)
  show figure: set block(spacing: 1.5em)
  show figure.caption: it => {
    set text(font: sans, size: 8.2pt, fill: palette.muted)
    set par(justify: false)
    let c = context [#text(weight: "semibold", fill: palette.ink)[#it.supplement #it.counter.display(it.numbering)]#h(0.6em)#it.body]
    // A table's caption sits above it: keep it on the same page as the table.
    if it.kind == table { block(sticky: true, c) } else { c }
  }
  // A table row is never split across a page break.
  set table.cell(breakable: false)
  show figure.where(kind: table): set figure.caption(position: top)
  show figure.where(kind: table): set block(breakable: true)
  show figure.where(kind: "rule"): set block(breakable: true)
  show figure.where(kind: "algorithm"): set block(breakable: true)

  show figure.where(kind: "rule"): it => block(
    width: 100%,
    breakable: true,
    fill: palette.wash-blue,
    stroke: (left: 2.2pt + palette.blue),
    inset: (left: 10pt, right: 10pt, top: 7pt, bottom: 8pt),
    radius: (right: 2pt),
    spacing: 1.15em,
    {
      set align(left)
      block(sticky: true, below: 0.6em, {
        text(
          font: sans,
          size: 8pt,
          weight: "semibold",
          tracking: 0.06em,
          fill: palette.blue,
          upper[Rule #context it.counter.display(it.numbering)],
        )
        h(0.7em)
        text(font: sans, size: 9pt, weight: "semibold", fill: palette.ink, it.caption.body)
      })
      // Ragged right: rules are full of long unbreakable code names, and a
      // justified line before one is stretched badly.
      set par(justify: false)
      it.body
    },
  )

  show figure.where(kind: "algorithm"): it => block(
    width: 100%,
    breakable: true,
    stroke: (top: 0.9pt + palette.ink, bottom: 0.6pt + palette.ink),
    inset: (x: 0pt, top: 6pt, bottom: 6pt),
    spacing: 1.4em,
    {
      set align(left)
      block(sticky: true, below: 0.7em, {
        text(
          font: sans,
          size: 8pt,
          weight: "semibold",
          tracking: 0.06em,
          fill: palette.teal,
          upper[Algorithm #context it.counter.display(it.numbering)],
        )
        h(0.7em)
        text(font: sans, size: 9pt, weight: "semibold", fill: palette.ink, it.caption.body)
      })
      it.body
    },
  )

  // ---- Outline -----------------------------------------------------------
  show outline.entry.where(level: 1): it => {
    set block(above: 1.15em)
    set text(font: sans, weight: "semibold", fill: palette.ink, size: 9.6pt)
    link(it.element.location(), it.indented(
      text(fill: palette.teal, it.prefix()),
      [#it.body()#h(1fr)#it.page()],
    ))
  }
  show outline.entry.where(level: 2): set text(size: 9.6pt)

  // ---- Front matter ------------------------------------------------------
  if front-matter {
    set page(header: none, footer: none, margin: (x: 25mm, top: 30mm, bottom: 25mm))
    counter(page).update(0)

    place(top + left, dx: -25mm, dy: -30mm, rect(width: 210mm, height: 9mm, fill: palette.ink))
    place(top + left, dx: -25mm, dy: -21mm, rect(width: 210mm, height: 1.6mm, fill: palette.turquoise))

    v(38mm)
    text(
      font: sans,
      size: 10pt,
      weight: "semibold",
      tracking: 0.2em,
      fill: palette.teal,
      upper[Technical Whitepaper],
    )
    v(5mm)
    text(font: sans, size: 54pt, weight: "bold", fill: palette.ink, tracking: -0.01em, title)
    v(3mm)
    if subtitle != none {
      block(width: 84%, {
        set par(justify: false, leading: 0.5em)
        text(font: sans, size: 17pt, weight: "light", fill: palette.ink, subtitle)
      })
    }
    v(7mm)
    line(length: 26%, stroke: 2.4pt + palette.turquoise)
    v(10mm)
    if abstract != none {
      block(width: 88%, {
        text(font: sans, size: 8pt, weight: "semibold", tracking: 0.14em, fill: palette.muted, upper[Abstract])
        v(0.6em, weak: true)
        set text(size: 10.4pt)
        set par(leading: 0.68em)
        abstract
      })
    }
    v(1fr)
    {
      set text(font: sans, size: 8.6pt, fill: palette.muted)
      set par(justify: false, leading: 0.7em)
      grid(
        columns: (auto, 1fr),
        column-gutter: 1.4em,
        row-gutter: 0.75em,
        ..(
          if version != none { ([Document version], text(fill: palette.ink, version)) },
          if date != none { ([Date], text(fill: palette.ink, date)) },
          if commit != none { ([Reference implementation], text(fill: palette.ink, commit)) },
        )
          .filter(x => x != none)
          .flatten()
      )
    }
    pagebreak()

    // Table of contents.
    set page(
      margin: (inside: 27mm, outside: 23mm, top: 27mm, bottom: 27mm),
      footer: context {
        set text(font: sans, size: 8pt, fill: palette.muted)
        align(center, counter(page).display("i"))
      },
    )
    counter(page).update(1)
    {
      show heading: none
      heading(level: 1, numbering: none, outlined: false, bookmarked: true)[Contents]
    }
    v(18mm)
    text(font: sans, size: 25pt, weight: "semibold", fill: palette.ink)[Contents]
    v(0.1em)
    line(length: 18%, stroke: 2pt + palette.turquoise)
    v(7mm)
    outline(title: none, depth: 2, indent: auto)
    pagebreak(weak: true)
    counter(page).update(1)
  }

  body
}
