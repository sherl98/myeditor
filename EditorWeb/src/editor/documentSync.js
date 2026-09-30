import { $getRoot, $getNodeByKey, HISTORIC_TAG } from 'lexical'
import {
  exportMarkdownFromLexical,
  exportVisitors$,
  toMarkdownOptions$,
  toMarkdownExtensions$,
  jsxComponentDescriptors$,
  jsxIsAvailable$,
  markdown$,
} from '@mdxeditor/editor'
import {
  blockHeadings,
  inferMarkdownStyle,
  outlineFromBlocks,
  referenceDefinitions,
  referenceUsages,
  restoreReferenceLinks,
  visibleCharacterCount,
} from '../markdown/markdown.js'

// The editor serializes only the top-level blocks that changed. A block whose
// Markdown is unchanged keeps its original bytes, including its separators, so
// an edit never rewrites the style of the rest of the file.
// See vite.config.js: MDXEditor's own whole-document export is skipped.
globalThis.__myEditorSkipMarkdownExport = true

const IDLE_MS = 150
const MAX_WAIT_MS = 1000

const sync = {
  realm: null,
  editor: null,
  importing: false,
  captured: null,
  // Original text layout: blocks[i] = { start, end, keys }, plus separators.
  source: '',
  blocks: [],
  firstKeys: new Map(),
  baseline: null,
  fingerprints: new Map(),
  // Syntax choices of the whole file and of each original block.
  documentStyle: {},
  definitions: new Map(),
  references: new Map(),
  blockStyles: new Map(),
  preserving: false,
  reason: 'not loaded',
  cache: new Map(),
  dirty: new Set(),
  active: false,
  idleTimer: 0,
  deadlineTimer: 0,
  structureChanged: false,
  last: null,
  exports: 0,
  // Durations (ms) of the latest export: collecting blocks, joining text, outline.
  timing: null,
  finishImport: null,
}

export const blockCaptureExtension = {
  transforms: [
    (root) => {
      if (!sync.importing) return
      sync.captured = root.children.map((child, index) => {
        child.data = { ...child.data, myEditorBlock: index }
        return { start: child.position?.start.offset, end: child.position?.end.offset, keys: [] }
      })
      // Import visitors run synchronously after the transform.
      const finish = sync.finishImport
      queueMicrotask(() => finish?.())
    },
  ],
}

// Runs before every other visitor for top-level blocks and records the Lexical
// nodes each Markdown block produced.
export const blockImportVisitor = {
  priority: 1000,
  testNode: (node) =>
    sync.importing && sync.captured !== null && Number.isInteger(node.data?.myEditorBlock),
  visitNode({ mdastNode, lexicalParent, actions }) {
    const last = lexicalParent.getLastChild()
    actions.nextVisitor()
    const block = sync.captured[mdastNode.data.myEditorBlock]
    // Walk only the appended siblings; copying all children is quadratic.
    let node = last ? last.getNextSibling() : lexicalParent.getFirstChild()
    for (; node && block; node = node.getNextSibling()) block.keys.push(node.getKey())
  },
}

export function attachEditor(editor, realm, onDirty) {
  sync.editor = editor
  sync.realm = realm
  return editor.registerUpdateListener(
    ({ editorState, prevEditorState, dirtyElements, dirtyLeaves, tags }) => {
      if (!sync.active || (dirtyElements.size === 0 && dirtyLeaves.size === 0)) return
      let changed = false
      editorState.read(
        () => {
          const mark = (key) => {
            if (key === 'root') {
              sync.structureChanged = true
              changed = true
              return
            }
            const node = $getNodeByKey(key)
            if (node && node.__parent === 'root') {
              sync.dirty.add(key)
              changed = true
            }
          }
          for (const key of dirtyElements.keys()) mark(key)
          for (const key of dirtyLeaves) mark(key)
          // Undo/redo replaces the whole state and only marks the root dirty.
          // Unchanged nodes are shared between states, so compare identities.
          if (tags.has(HISTORIC_TAG)) {
            const before = prevEditorState._nodeMap
            for (const [key, node] of editorState._nodeMap) {
              if (before.get(key) === node) continue
              let top = node
              while (top && top.__parent && top.__parent !== 'root')
                top = $getNodeByKey(top.__parent)
              if (top?.__parent === 'root') sync.dirty.add(top.__key)
            }
          }
        },
        { editor },
      )
      if (changed) onDirty()
    },
  )
}

// Import `source` through MDXEditor and remember where each block came from.
// The first import in a page can run after the current frame, so this
// resolves once the blocks were captured, the import failed, or a timeout.
export function importDocument(source, setMarkdown) {
  sync.active = false
  cancelScheduledExport()
  sync.finishImport?.()
  sync.captured = null
  sync.importing = true
  return new Promise((resolve) => {
    const timeout = setTimeout(() => finish(), 3000)
    function finish() {
      if (sync.finishImport !== finish) return
      clearTimeout(timeout)
      sync.importing = false
      sync.finishImport = null
      resolve()
    }
    sync.finishImport = finish
    // MDXEditor skips an import equal to its last known Markdown; that value
    // is stale while its own export is deferred.
    sync.realm?.pub(markdown$, '\u0000')
    setMarkdown(source)
  })
}

// The rich editor rejected the document; the fallback view takes over.
export function abandonImport() {
  sync.captured = null
  sync.finishImport?.()
}

// Call once the imported state is committed. Returns the outline.
export function beginTracking(source, previousOutline) {
  sync.source = source
  sync.blocks = sync.captured || []
  sync.captured = null
  sync.cache.clear()
  sync.dirty.clear()
  sync.structureChanged = false
  sync.last = null
  sync.fingerprints.clear()
  sync.firstKeys.clear()
  sync.blockStyles.clear()
  const { fences, ...documentStyle } = inferMarkdownStyle(source)
  sync.documentStyle = documentStyle
  sync.definitions = referenceDefinitions(source)
  sync.references = sync.definitions.size ? referenceUsages(source) : new Map()
  sync.baseline = sync.editor.getEditorState()
  sync.preserving = false
  sync.reason = ''
  sync.baseline.read(
    () => {
      const children = $getRoot()
        .getChildren()
        .map((node) => node.getKey())
      const mapped = sync.blocks.flatMap((block) => block.keys)
      if (sync.blocks.some((block) => block.keys.length === 0 || block.start === undefined))
        sync.reason = 'block without editor nodes'
      else if (mapped.some((key, index) => children[index] !== key))
        sync.reason = 'block order differs'
      else if (
        children.slice(mapped.length).some((key) => $getNodeByKey(key).getTextContentSize() > 0)
      )
        sync.reason = 'unmapped trailing content'
      else sync.preserving = true
    },
    { editor: sync.editor },
  )
  if (sync.preserving)
    sync.blocks.forEach((block, index) => sync.firstKeys.set(block.keys[0], index))
  sync.active = true
  return assemble(previousOutline).outline
}

export function scheduleExport(run) {
  clearTimeout(sync.idleTimer)
  sync.idleTimer = setTimeout(run, IDLE_MS)
  if (!sync.deadlineTimer) sync.deadlineTimer = setTimeout(run, MAX_WAIT_MS)
}

export function cancelScheduledExport() {
  clearTimeout(sync.idleTimer)
  clearTimeout(sync.deadlineTimer)
  sync.idleTimer = 0
  sync.deadlineTimer = 0
}

export function stopTracking() {
  sync.active = false
  cancelScheduledExport()
}

// Serialize changed blocks and rebuild the document text and outline.
export function exportDocument(previousOutline) {
  cancelScheduledExport()
  if (sync.last && !sync.dirty.size && !sync.structureChanged) return sync.last
  sync.exports++
  return assemble(previousOutline)
}

function exportNodes(nodes, style = {}) {
  const root = $getRoot()
  // MDXEditor exports a root's children; present only the requested ones.
  const subset = new Proxy(root, {
    get(target, property) {
      if (property === 'getChildren') return () => nodes
      const value = target[property]
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
  const realm = sync.realm
  return exportMarkdownFromLexical({
    root: subset,
    visitors: realm.getValue(exportVisitors$),
    toMarkdownOptions: { ...realm.getValue(toMarkdownOptions$), ...sync.documentStyle, ...style },
    toMarkdownExtensions: realm.getValue(toMarkdownExtensions$),
    jsxComponentDescriptors: realm.getValue(jsxComponentDescriptors$),
    jsxIsAvailable: realm.getValue(jsxIsAvailable$),
  }).replace(/\s+$/, '')
}

function blockStyle(index) {
  if (!sync.blockStyles.has(index)) sync.blockStyles.set(index, inferMarkdownStyle(original(index)))
  return sync.blockStyles.get(index)
}

function fingerprint(index) {
  if (!sync.fingerprints.has(index)) {
    const keys = sync.blocks[index].keys
    const style = blockStyle(index)
    sync.fingerprints.set(
      index,
      sync.baseline.read(
        () =>
          exportNodes(
            keys.map((key) => $getNodeByKey(key)),
            style,
          ),
        {
          editor: sync.editor,
        },
      ),
    )
  }
  return sync.fingerprints.get(index)
}

function describe(text, block) {
  return { text, block, count: visibleCharacterCount(text), headings: blockHeadings(text) }
}

function original(index) {
  const block = sync.blocks[index]
  return sync.source.slice(block.start, block.end)
}

function assemble(previousOutline) {
  const started = performance.now()
  const units = []
  sync.editor.getEditorState().read(
    () => {
      const children = $getRoot().getChildren()
      for (let index = 0; index < children.length;) {
        const key = children[index].getKey()
        const blockIndex = sync.preserving ? sync.firstKeys.get(key) : undefined
        const keys = blockIndex === undefined ? [key] : sync.blocks[blockIndex].keys
        const whole =
          blockIndex !== undefined &&
          keys.every((expected, offset) => children[index + offset]?.getKey() === expected)
        const nodes = whole ? children.slice(index, index + keys.length) : [children[index]]
        const block = whole ? blockIndex : undefined
        index += nodes.length
        const cached = sync.cache.get(key)
        const dirty = nodes.some((node) => sync.dirty.has(node.getKey()))
        if (cached && !dirty && cached.block === block && cached.size === nodes.length) {
          units.push(cached)
          continue
        }
        let unit
        if (block !== undefined && !sync.dirty.has(key) && !cached && nodes.length === 1)
          unit = describe(original(block), block)
        else {
          const fresh = exportNodes(nodes, block === undefined ? {} : blockStyle(block))
          if (block !== undefined && fresh === fingerprint(block))
            unit = describe(original(block), block)
          else
            unit = describe(restoreReferenceLinks(fresh, sync.references, sync.definitions), block)
        }
        unit.size = nodes.length
        sync.cache.set(key, unit)
        units.push(unit)
      }
    },
    { editor: sync.editor },
  )
  sync.dirty.clear()
  sync.structureChanged = false
  const collected = performance.now()
  let text = ''
  let previous
  let emitted = false
  const outlineBlocks = []
  for (const unit of units) {
    if (!unit.text) continue
    if (!emitted) text += unit.block === 0 ? sync.source.slice(0, sync.blocks[0].start) : ''
    else if (previous !== undefined && unit.block === previous + 1)
      text += sync.source.slice(sync.blocks[previous].end, sync.blocks[unit.block].start)
    else text += '\n\n'
    outlineBlocks.push({ start: text.length, count: unit.count, headings: unit.headings })
    text += unit.text
    previous = unit.block
    emitted = true
  }
  if (!emitted) text = sync.preserving && !sync.blocks.length ? sync.source : ''
  else if (previous !== undefined && previous === sync.blocks.length - 1)
    text += sync.source.slice(sync.blocks[previous].end)
  const joined = performance.now()
  sync.last = { text, outline: outlineFromBlocks(outlineBlocks, previousOutline) }
  sync.timing = {
    blocks: +(collected - started).toFixed(1),
    join: +(joined - collected).toFixed(1),
    outline: +(performance.now() - joined).toFixed(1),
  }
  return sync.last
}

export function inspectSync() {
  return {
    preserving: sync.preserving,
    reason: sync.reason,
    blocks: sync.blocks.length,
    exports: sync.exports,
    timing: sync.timing,
    pending: sync.dirty.size,
  }
}
