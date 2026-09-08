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

export function needsRawParagraph(node) {
  const raw = node.data?.originalMarkdown || ''
  return (
    node.type === 'paragraph' &&
    (/\[\[[^\n]+?\]\]|\[\^[^\]]+\]|\$\$|\$[^\s$\d][^$\n]*\$/.test(raw) ||
      /(^|\n)\s*(?::{2,}|\{%|import\s.+\sfrom\s|export\s+(?:const|default)|\{[^\n]+\})/.test(raw))
  )
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
  transforms: [resolveReferences],
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
