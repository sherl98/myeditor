import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfm } from 'micromark-extension-gfm'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { frontmatter } from 'micromark-extension-frontmatter'
import { frontmatterFromMarkdown } from 'mdast-util-frontmatter'

const gfmMdastExtensions = gfmFromMarkdown()
const closeGFMParagraph = gfmMdastExtensions.find((extension) => extension.exit?.paragraph).exit
  .paragraph

function closeWithSource(token) {
  const node = this.stack[this.stack.length - 1]
  node.data = { ...node.data, originalMarkdown: this.sliceSerialize(token) }
  this.exit(token)
}

function closeParagraphWithSource(token) {
  const node = this.stack[this.stack.length - 1]
  node.data = { ...node.data, originalMarkdown: this.sliceSerialize(token) }
  // GFM removes the space after a task checkbox while closing the paragraph.
  // Capture source without replacing that semantic cleanup.
  closeGFMParagraph.call(this, token)
}

function resolveReferences(root) {
  const definitions = new Map()
  function collect(node) {
    if (node.type === 'definition' && !definitions.has(node.identifier.toLowerCase())) {
      definitions.set(node.identifier.toLowerCase(), node)
    }
    node.children?.forEach(collect)
  }
  collect(root)
  function resolve(node) {
    const definition = definitions.get(node.identifier?.toLowerCase())
    if (definition && (node.type === 'linkReference' || node.type === 'imageReference')) {
      node.type = node.type === 'linkReference' ? 'link' : 'image'
      node.url = definition.url
      node.title = definition.title
    }
    node.children?.forEach(resolve)
  }
  resolve(root)
}

// Display math and MDX-style syntax keep the whole paragraph as Markdown.
export function needsRawParagraph(node) {
  const raw = node.data?.originalMarkdown || ''
  return (
    node.type === 'paragraph' &&
    (/\$\$/.test(raw) ||
      /(^|\n)\s*(?::{2,}|\{%|import\s.+\sfrom\s|export\s+(?:const|default)|\{[^\n]+\})/.test(raw))
  )
}

// Inline math, wiki links and footnote references without a definition stay
// literal inside otherwise rendered text: they become `rawInline` nodes.
const INLINE_RAW = /\$[^\s$\d][^$\n]*\$|\[\[[^\n]+?\]\]|\[\^[^\]\n]+\]/g
function splitInlineRaw(root) {
  function visit(node) {
    if (!node.children) return
    if (node.type === 'code' || node.type === 'html') return
    const children = []
    for (const child of node.children) {
      if (child.type !== 'text' || !INLINE_RAW.test(child.value)) {
        visit(child)
        children.push(child)
        continue
      }
      INLINE_RAW.lastIndex = 0
      let last = 0
      for (const match of child.value.matchAll(INLINE_RAW)) {
        if (match.index > last)
          children.push({ type: 'text', value: child.value.slice(last, match.index) })
        children.push({ type: 'rawInline', value: match[0] })
        last = match.index + match[0].length
      }
      if (last < child.value.length) children.push({ type: 'text', value: child.value.slice(last) })
    }
    node.children = children
  }
  visit(root)
}

export function hasMixedTaskItems(node) {
  if (node.type !== 'list') return false
  const taskItems = node.children.filter((item) => typeof item.checked === 'boolean').length
  return taskItems > 0 && taskItems < node.children.length
}

// Retain the original token text for syntax that the rich editor cannot interpret.
const preservingMarkdown = {
  exit: {
    paragraph: closeParagraphWithSource,
    definition: closeWithSource,
    listOrdered: closeWithSource,
    listUnordered: closeWithSource,
  },
  transforms: [resolveReferences, splitInlineRaw],
}

export const markdownOptions = {
  extensions: [gfm(), frontmatter(['yaml', 'toml'])],
  mdastExtensions: [
    gfmMdastExtensions,
    frontmatterFromMarkdown(['yaml', 'toml']),
    preservingMarkdown,
  ],
}

export function parseMarkdown(source) {
  return fromMarkdown(source, markdownOptions)
}

function plainText(node) {
  if (node.type === 'image') return node.alt || ''
  if (typeof node.value === 'string') return node.value
  return (node.children || []).map(plainText).join('')
}

let nextHeadingID = 0
export function extractOutline(source, previous = []) {
  const root = parseMarkdown(source)
  const found = []
  function visit(node) {
    if (node.type === 'heading') found.push(node)
    else if (node.type !== 'code' && node.type !== 'html') node.children?.forEach(visit)
  }
  root.children.forEach(visit)
  const used = new Set()
  return found.map((node, index) => {
    const title = plainText(node).trim() || '无标题'
    // Reuse identities across edits, including separate identities for repeated titles.
    const old = previous.find(
      (item) => !used.has(item.id) && item.level === node.depth && item.title === title,
    )
    const id = old?.id || `heading-${++nextHeadingID}`
    used.add(id)
    let end = source.length
    for (let i = index + 1; i < found.length; i++) {
      if (found[i].depth <= node.depth) {
        end = found[i].position.start.offset
        break
      }
    }
    const section = source.slice(node.position.end.offset, end).replace(/\s/g, '')
    return {
      id,
      title,
      level: node.depth,
      offset: node.position.start.offset,
      characterCount: Array.from(section).length,
    }
  })
}

// Serialization options that reproduce the author's syntax choices, inferred
// from Markdown text. Used when an edited block must be written again.
export function inferMarkdownStyle(text) {
  const style = {}
  const bullet = /^[ \t>]*([-*+])[ \t]+\S/m.exec(text)
  if (bullet) style.bullet = bullet[1]
  const ordered = /^[ \t>]*\d{1,9}([.)])[ \t]+\S/m.exec(text)
  if (ordered) style.bulletOrdered = ordered[1]
  if (/(^|[^\w_\\])__[^_\s]/.test(text)) style.strong = '_'
  else if (/(^|[^*\\])\*\*[^*\s]/.test(text)) style.strong = '*'
  if (/(^|[^\w_\\])_[^_\s][^_\n]*_(?![\w_])/.test(text)) style.emphasis = '_'
  else if (/(^|[^*\\])\*[^*\s][^*\n]*\*(?!\*)/.test(text)) style.emphasis = '*'
  const rule = /^ {0,3}([-*_])([ \t]*)\1(?:[ \t]*\1)+[ \t]*$/m.exec(text)
  if (rule) {
    style.rule = rule[1]
    style.ruleSpaces = rule[2].length > 0
    style.ruleRepetition = rule[0].split(rule[1]).length - 1
  }
  const fence = /^ {0,3}(`{3,}|~{3,})/m.exec(text)
  if (fence) style.fence = fence[1][0]
  // A single indented code block stays indented.
  else if (/^( {4}|\t)\S/.test(text)) style.fences = false
  // `---` also closes front matter, so only a whole-text heading counts for it.
  if (/^[^\n]+\n {0,3}=+[ \t]*$/m.test(text) || /^[^\n]+\n {0,3}-+[ \t]*$/.test(text.trim()))
    style.setext = true
  return style
}

// Link reference definitions of a document: label (lower case) -> { url, title }.
export function referenceDefinitions(text) {
  const definitions = new Map()
  const pattern =
    /^ {0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+(?:"([^"\n]*)"|'([^'\n]*)'|\(([^)\n]*)\)))?[ \t]*$/gm
  for (const match of text.matchAll(pattern)) {
    const label = match[1].toLowerCase()
    if (!definitions.has(label))
      definitions.set(label, { url: match[2], title: match[3] ?? match[4] ?? match[5] })
  }
  return definitions
}

// Reference links written in a document, e.g. `[text][label]` or `![alt][]`.
export function referenceUsages(text) {
  const usages = new Map()
  for (const [whole, bang, content, label] of text.matchAll(/(!?)\[([^\]\n]+)\]\[([^\]\n]*)\]/g))
    if (!usages.has(`${bang}[${content}]`))
      usages.set(`${bang}[${content}]`, { whole, label: label || content })
  return usages
}

// The rich editor stores reference links as inline links. Write an exported
// inline link the way the document wrote that link, if it has a definition.
export function restoreReferenceLinks(fresh, usages, definitions) {
  if (!usages.size || !fresh.includes('](')) return fresh
  return fresh.replace(/(!?\[[^\]\n]+\])\(([^()\n]*)\)/g, (link, target, destination) => {
    const usage = usages.get(target)
    const definition = usage && definitions.get(usage.label.toLowerCase())
    if (!definition) return link
    const expected = definition.title ? `${definition.url} "${definition.title}"` : definition.url
    return destination === expected ? usage.whole : link
  })
}

// Cheap pre-check: only blocks that can contain an ATX or setext heading are parsed.
const HEADING_HINT = /(^|\n)[ \t>*+\-\d.)]*#{1,6}([ \t]|$)|\n[ \t>]*(=+|-+)[ \t]*(\n|$)/m

// Headings inside one top-level block, with offsets relative to the block text.
export function blockHeadings(text) {
  if (!HEADING_HINT.test(text)) return []
  const found = []
  function visit(node) {
    if (node.type === 'heading') found.push(node)
    else if (node.type !== 'code' && node.type !== 'html') node.children?.forEach(visit)
  }
  parseMarkdown(text).children.forEach(visit)
  return found.map((node) => ({
    title: plainText(node).trim() || '无标题',
    level: node.depth,
    offset: node.position.start.offset,
    // Visible characters of the block before the heading and through its end.
    before: visibleCharacterCount(text.slice(0, node.position.start.offset)),
    through: visibleCharacterCount(text.slice(0, node.position.end.offset)),
  }))
}

// Non-whitespace code points, matching the outline's character counts.
export function visibleCharacterCount(text) {
  let count = 0
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index)
    if (code >= 0xdc00 && code <= 0xdfff) continue
    if (code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x3000) continue
    if (code > 0x7f && /\s/.test(text[index])) continue
    count++
  }
  return count
}

// Outline from exported blocks: [{ start, count, headings }]. A section runs
// from the end of its heading to the next heading of the same or a higher
// level, as extractOutline counts it for a whole document.
export function outlineFromBlocks(blocks, previous = []) {
  const found = []
  blocks.forEach((block, index) => {
    for (const heading of block.headings)
      found.push({ ...heading, block: index, offset: block.start + heading.offset })
  })
  const totals = [0]
  for (const block of blocks) totals.push(totals.at(-1) + block.count)
  const position = (block, within) => totals[block] + within
  const used = new Set()
  return found.map((heading, index) => {
    const old = previous.find(
      (item) => !used.has(item.id) && item.level === heading.level && item.title === heading.title,
    )
    const id = old?.id || `heading-${++nextHeadingID}`
    used.add(id)
    const next = found.slice(index + 1).find((item) => item.level <= heading.level)
    const end = next ? position(next.block, next.before) : totals.at(-1)
    return {
      id,
      title: heading.title,
      level: heading.level,
      offset: heading.offset,
      characterCount: end - position(heading.block, heading.through),
    }
  })
}

export function primaryHeadings(headings) {
  if (!headings.length) return []
  const candidates =
    headings.length > 1 &&
    headings[0].level === 1 &&
    headings.filter((h) => h.level === 1).length === 1
      ? headings.slice(1)
      : headings
  const level = Math.min(...candidates.map((h) => h.level))
  return candidates.filter((h) => h.level === level)
}

export function imagePreviewURL(source) {
  if (/^(https?:|data:|blob:|myeditor-resource:)/i.test(source)) return source
  if (/^[a-z][a-z\d+.-]*:/i.test(source) && !source.startsWith('file:')) return ''
  return `myeditor-resource://document/image?path=${encodeURIComponent(source)}`
}
