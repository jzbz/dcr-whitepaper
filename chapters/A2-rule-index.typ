#import "../template.typ": *

= Index of Consensus Rules <ch:rule-index>

Every numbered rule box in this document is listed below in order of
appearance. Together they are the complete set of requirements a block must
meet to be accepted by the reference implementation. A block is valid if and
only if no rule rejects it. Where a rule matters in two contexts, for example
a requirement on a stake transaction that is checked while validating a
block, it is stated in both chapters and appears twice here; the two
statements are equivalent.

#context {
  // The illustrative rule in the conventions chapter is not a real rule.
  let rules = query(figure.where(kind: "rule")).filter(r => not (
    r.has("label") and str(r.label).starts-with("rule:conv-")
  ))
  let chapters = query(heading.where(level: 1)).filter(h => h.numbering != none)

  // The chapter a location belongs to is the last chapter heading before it.
  let chapter-of(loc) = {
    let before = chapters.filter(h => {
      let hl = h.location()
      hl.page() < loc.page() or (hl.page() == loc.page() and hl.position().y <= loc.position().y)
    })
    if before.len() == 0 { none } else { before.last() }
  }

  let groups = (:)
  let order = ()
  for r in rules {
    let loc = r.location()
    let ch = chapter-of(loc)
    if ch == none { continue }
    let ch-loc = ch.location()
    let fmt = if appendix-mode.at(ch-loc) { "A" } else { "1" }
    let ch-number = numbering(fmt, counter(heading).at(ch-loc).first())
    if ch-number not in groups {
      groups.insert(ch-number, (heading: ch, rows: ()))
      order.push(ch-number)
    }
    let n = counter(figure.where(kind: "rule")).at(loc).first()
    groups.at(ch-number).rows.push((
      link(loc, text(font: sans, weight: "medium", fill: palette.blue, ch-number + "." + str(n))),
      link(loc, r.caption.body),
      align(right, text(fill: palette.muted, str(counter(page).at(loc).first()))),
    ))
  }

  if order.len() == 0 {
    emph[No rules are present in this build.]
  }

  for key in order {
    let g = groups.at(key)
    block(above: 1.8em, below: 0.8em, sticky: true, {
      text(font: sans, size: 10.5pt, weight: "semibold", fill: palette.teal, key)
      h(0.7em)
      text(font: sans, size: 10.5pt, weight: "semibold", fill: palette.ink, g.heading.body)
      h(0.7em)
      text(font: sans, size: 8pt, fill: palette.muted)[#g.rows.len() #if g.rows.len() == 1 [rule] else [rules]]
    })
    set text(size: 8.8pt)
    set par(justify: false, leading: 0.5em)
    // Two balanced columns: `columns()` fills the first column to the foot of
    // the page before using the second, which leaves short lists one-sided.
    let half = calc.ceil(g.rows.len() / 2)
    let col(rows) = grid(
      columns: (auto, 1fr, auto),
      column-gutter: 0.7em,
      row-gutter: 0.62em,
      ..rows.flatten()
    )
    grid(
      columns: (1fr, 1fr),
      column-gutter: 7mm,
      col(g.rows.slice(0, half)), col(g.rows.slice(half)),
    )
  }
}
