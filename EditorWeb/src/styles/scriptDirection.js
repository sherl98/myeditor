// Marks paragraphs written mostly in Latin script, which read better
// start-aligned than justified. Runs in slices so long documents stay responsive.
const CJK = /[⺀-鿿가-힯豈-﫿＀-￯]/g
const LATIN = /[A-Za-zÀ-ɏ]/g

export function isMostlyLatin(text) {
  const sample = text.slice(0, 160)
  const latin = sample.match(LATIN)?.length ?? 0
  const cjk = sample.match(CJK)?.length ?? 0
  return latin >= 12 && cjk * 8 < latin
}

let generation = 0
export function markLatinParagraphs(root) {
  const current = ++generation
  const paragraphs = root?.querySelectorAll(':scope > p, :scope > blockquote > p') ?? []
  let index = 0
  function slice() {
    if (current !== generation) return
    const end = Math.min(paragraphs.length, index + 400)
    for (; index < end; index++) {
      const paragraph = paragraphs[index]
      const latin = isMostlyLatin(paragraph.textContent)
      if (latin !== (paragraph.dataset.script === 'latin')) {
        if (latin) paragraph.dataset.script = 'latin'
        else delete paragraph.dataset.script
      }
    }
    if (index < paragraphs.length) setTimeout(slice, 0)
  }
  slice()
}
