import {
  $getRoot,
  $getNodeByKey,
  $isTextNode,
  $isElementNode,
  $setSelection,
  HISTORY_PUSH_TAG,
  SKIP_DOM_SELECTION_TAG,
} from 'lexical'
import { $isTableNode, $isCodeBlockNode } from '@mdxeditor/editor'
import { runtime, post, postHistory } from '../bridge/engineBridge.js'
import { literalMatches, replaceRanges, editsForRuns } from './searchText.js'
import { showSourceMatches, revealSourceMatch, cancelSourceReveal } from './searchPresentation.js'

const state = { query: '', requestID: 0, matches: [], current: -1, sequence: 0 }
let refreshTimer
let paintFrame
let paintTimer
let paintGeneration = 0

function clearPresentation() {
  document.documentElement.classList.remove('search-active')
  if (CSS.highlights) {
    for (const name of ['myeditor-find', 'myeditor-current']) {
      CSS.highlights.get(name)?.clear()
      CSS.highlights.delete(name)
    }
  }
  cancelSourceReveal()
  showSourceMatches(new Map(), null)
}

function appendPart(parts, text, fields) {
  if (!text) return
  const start = parts.at(-1)?.end || 0
  parts.push({ ...fields, text, start, end: start + text.length })
}

function mdastParts(nodes, parts = [], prefix = []) {
  nodes.forEach((node, index) => {
    const path = [...prefix, index]
    if (['text', 'inlineCode', 'html', 'rawMarkdown'].includes(node.type))
      appendPart(parts, node.value || '', { path })
    else if (node.type === 'break') appendPart(parts, '\n', { path, boundary: true })
    else if (node.children) mdastParts(node.children, parts, [...path, 'children'])
  })
  return parts
}

function collectSegments() {
  if (runtime.showsSource && !runtime.fallback)
    return [{ id: 'source-preview', kind: 'source', key: 'source-preview', text: runtime.source }]
  if (runtime.fallback)
    return [{ id: 'fallback', kind: 'source', key: 'fallback', text: runtime.source }]
  const segments = []
  runtime.editor.read(() => {
    function visit(node) {
      const key = node.getKey()
      if ($isCodeBlockNode(node)) {
        segments.push({ id: key, kind: 'source', key, text: node.getCode() })
        return
      }
      if (node.getType() === 'raw-markdown') {
        segments.push({ id: key, kind: 'source', key, text: node.getTextContent() })
        return
      }
      if ($isTableNode(node)) {
        node.getMdastNode().children.forEach((row, rowIndex) =>
          row.children.forEach((cell, column) => {
            const parts = mdastParts(cell.children)
            segments.push({
              id: `${key}:${rowIndex}:${column}`,
              kind: 'table',
              key,
              row: rowIndex,
              column,
              parts,
              text: parts.map((part) => part.text).join(''),
            })
          }),
        )
        return
      }
      if (!$isElementNode(node)) return
      let parts = []
      let run = 0
      function finish() {
        if (parts.length)
          segments.push({
            id: `${key}:${run++}`,
            kind: 'text',
            key,
            parts,
            text: parts.map((part) => part.text).join(''),
          })
        parts = []
      }
      function inline(child) {
        if ($isTextNode(child)) appendPart(parts, child.getTextContent(), { key: child.getKey() })
        else if (child.getType() === 'linebreak') appendPart(parts, '\n', { boundary: true })
        else if ($isElementNode(child) && child.isInline()) child.getChildren().forEach(inline)
        else {
          finish()
          visit(child)
        }
      }
      node.getChildren().forEach(inline)
      finish()
    }
    visit($getRoot())
  })
  return segments
}

function publish() {
  post('search', {
    query: state.query,
    requestID: state.requestID,
    sequence: runtime.sequence,
    count: state.matches.length,
    current: state.current + 1,
  })
}

function rebuild(preserve = true) {
  const old = preserve ? state.matches[state.current] : null
  const matches = []
  if (state.query)
    for (const segment of collectSegments()) {
      for (const range of literalMatches(segment.text, state.query))
        matches.push({ ...range, segment })
    }
  state.matches = matches
  state.sequence = runtime.sequence
  let index = old
    ? matches.findIndex((match) => match.segment.id === old.segment.id && match.from >= old.from)
    : -1
  state.current = matches.length
    ? index < 0
      ? Math.min(Math.max(0, state.current), matches.length - 1)
      : index
    : -1
  paint()
  publish()
}

function domRange(element, from, to) {
  if (!element) return null
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      return node.parentElement?.closest('button,select,.cm-gutters,[aria-hidden="true"]')
        ? NodeFilter.FILTER_REJECT
        : NodeFilter.FILTER_ACCEPT
    },
  })
  let node,
    offset = 0,
    start,
    end
  while ((node = walker.nextNode())) {
    const length = node.nodeValue.length
    if (!start && from < offset + length) start = [node, Math.max(0, from - offset)]
    if (to <= offset + length) {
      end = [node, Math.max(0, to - offset)]
      break
    }
    offset += length
  }
  if (!start || !end) return null
  const range = document.createRange()
  range.setStart(...start)
  range.setEnd(...end)
  return range
}

function cellElement(segment) {
  const table = runtime.editor.getElementByKey(segment.key)?.querySelector('table')
  const row = table?.tBodies[0]?.rows[segment.row]
  const cells = row
    ? [...row.cells].filter((cell) => !/toolCell|tableToolsColumn/.test(cell.className))
    : []
  return cells[segment.column]
}

function rangesForMatch(match) {
  const segment = match.segment
  if (segment.kind === 'source') return []
  if (segment.kind === 'table')
    return [domRange(cellElement(segment), match.from, match.to)].filter(Boolean)
  return editsForRuns(segment.parts, match.from, match.to, '')
    .map((part) => {
      if (part.boundary) return null
      return domRange(runtime.editor.getElementByKey(part.key), part.from, part.to)
    })
    .filter(Boolean)
}

function paint() {
  const generation = ++paintGeneration
  cancelAnimationFrame(paintFrame)
  clearTimeout(paintTimer)
  const requestID = state.requestID
  const revision = runtime.revision
  let completed = false
  const draw = () => {
    if (
      completed ||
      generation !== paintGeneration ||
      requestID !== state.requestID ||
      revision !== runtime.revision
    )
      return
    completed = true
    cancelAnimationFrame(paintFrame)
    clearTimeout(paintTimer)
    if (!state.query) {
      clearPresentation()
      return
    }
    document.documentElement.classList.add('search-active')
    const ranges = [],
      activeRanges = [],
      sources = new Map()
    const active = state.matches[state.current]
    state.matches.forEach((match) => {
      if (match.segment.kind === 'source') {
        const items = sources.get(match.segment.key) || []
        items.push(match)
        sources.set(match.segment.key, items)
      } else {
        const items = rangesForMatch(match)
        ranges.push(...items)
        if (match === active) activeRanges.push(...items)
      }
    })
    CSS.highlights.set('myeditor-find', new Highlight(...ranges))
    CSS.highlights.set('myeditor-current', new Highlight(...activeRanges))
    showSourceMatches(
      sources,
      active?.segment.kind === 'source'
        ? { key: active.segment.key, from: active.from, to: active.to }
        : null,
    )
  }
  paintFrame = requestAnimationFrame(draw)
  // WebKit can suspend animation frames in an inactive native tab/window.
  // Search state still needs a bounded commit before the user returns to it.
  paintTimer = setTimeout(draw, 32)
}

function revealCurrent() {
  const active = state.matches[state.current]
  if (!active) return
  if (active.segment.kind === 'source') {
    revealSourceMatch(active.segment.key, active)
    return
  }
  const requestID = state.requestID
  const revision = runtime.revision
  requestAnimationFrame(() => {
    if (
      requestID !== state.requestID ||
      revision !== runtime.revision ||
      active !== state.matches[state.current]
    )
      return
    const rect = rangesForMatch(active)[0]?.getBoundingClientRect()
    if (rect)
      window.scrollTo({
        top: Math.max(0, window.scrollY + rect.top - innerHeight * 0.38),
        behavior: 'auto',
      })
  })
}

function valid(options) {
  return (
    runtime.loaded &&
    options.sessionID === runtime.sessionID &&
    options.revision === runtime.revision
  )
}

export async function search(options) {
  if (!valid(options) || options.requestID < state.requestID) return
  const queryChanged = options.query !== state.query
  cancelSourceReveal()
  state.query = options.query
  state.requestID = options.requestID
  const requestID = state.requestID
  if (queryChanged) state.current = 0
  if (state.query && !(await window.MyEditor.flush(false)).ok) return
  if (!valid(options) || state.requestID !== requestID || state.query !== options.query) return
  rebuild(!queryChanged)
  if (options.direction && state.matches.length) {
    state.current =
      (state.current + options.direction + state.matches.length) % state.matches.length
    paint()
    publish()
  }
  revealCurrent()
}

function updateTableCell(table, segment, matches, replacement) {
  const cell = table.getMdastNode().children[segment.row].children[segment.column]
  const children = structuredClone(cell.children)
  for (const match of [...matches].reverse())
    for (const edit of editsForRuns(segment.parts, match.from, match.to, replacement)) {
      if (edit.boundary) continue
      let node = children
      for (const component of edit.path) node = node[component]
      node.value = node.value.slice(0, edit.from) + edit.replacement + node.value.slice(edit.to)
    }
  table.updateCellContents(segment.column, segment.row, children)
  // MDXEditor 4.2.3 caches each nested cell editor by this non-Markdown key.
  // Invalidate only the changed cell so its view and local history match the
  // document transaction (also when root undo restores the previous table).
  delete table.getWritable().getMdastNode().children[segment.row].children[segment.column]
    .__cacheKey
}

export async function replace(options) {
  if (runtime.showsSource) return { ok: false }
  if (!valid(options) || options.requestID !== state.requestID || options.query !== state.query)
    return { ok: false }
  const flushed = await window.MyEditor.flush(false)
  if (
    !flushed.ok ||
    !valid(options) ||
    options.requestID !== state.requestID ||
    options.query !== state.query
  )
    return { ok: false }
  rebuild()
  const active = state.matches[state.current]
  const selected = (options.all ? state.matches : active ? [active] : []).filter(
    (match) => match.text !== options.replacement,
  )
  if (!selected.length) return { ok: true, count: 0 }
  if (runtime.fallback) {
    runtime.applyFallback(replaceRanges(runtime.source, selected, options.replacement), true, true)
  } else {
    const grouped = new Map()
    for (const match of selected) {
      const matches = grouped.get(match.segment.id) || []
      matches.push(match)
      grouped.set(match.segment.id, matches)
    }
    runtime.historyTarget = runtime.editor
    runtime.editor.update(
      () => {
        $setSelection(null)
        for (const matches of grouped.values()) {
          const segment = matches[0].segment
          const node = $getNodeByKey(segment.key)
          if (segment.kind === 'source') {
            const value = replaceRanges(segment.text, matches, options.replacement)
            if ($isCodeBlockNode(node)) node.setCode(value)
            else node.setRaw(value)
          } else if (segment.kind === 'table')
            updateTableCell(node, segment, matches, options.replacement)
          else
            for (const match of [...matches].reverse()) {
              for (const edit of editsForRuns(
                segment.parts,
                match.from,
                match.to,
                options.replacement,
              )) {
                if (edit.boundary) continue
                const textNode = $getNodeByKey(edit.key)
                textNode.spliceText(edit.from, edit.to - edit.from, edit.replacement)
              }
            }
        }
      },
      { discrete: true, tag: [HISTORY_PUSH_TAG, SKIP_DOM_SELECTION_TAG] },
    )
    runtime.canUndo = runtime.history.undoStack.length > 0
    runtime.canRedo = runtime.history.redoStack.length > 0
    postHistory()
  }
  await Promise.resolve()
  await window.MyEditor.flush(false)
  rebuild()
  if (!options.all && active) {
    const next = state.matches.findIndex(
      (match) =>
        match.segment.id === active.segment.id &&
        match.from >= active.from + options.replacement.length,
    )
    if (next >= 0) state.current = next
  }
  paint()
  publish()
  revealCurrent()
  return { ok: true, count: selected.length }
}

export function refreshSearch() {
  clearTimeout(refreshTimer)
  const requestID = state.requestID
  const revision = runtime.revision
  if (state.query)
    refreshTimer = setTimeout(() => {
      if (
        runtime.loaded &&
        state.query &&
        state.requestID === requestID &&
        runtime.revision === revision
      )
        rebuild()
    }, 100)
}

export function clearSearch(options) {
  if (!valid(options) || options.requestID < state.requestID) return { ok: false }
  paintGeneration += 1
  clearTimeout(refreshTimer)
  cancelAnimationFrame(paintFrame)
  clearTimeout(paintTimer)
  state.query = ''
  state.requestID = options.requestID
  state.matches = []
  state.current = -1
  state.sequence = runtime.sequence
  clearPresentation()
  return {
    ok: true,
    cleared: true,
    query: '',
    count: 0,
    requestID: state.requestID,
    sessionID: runtime.sessionID,
    revision: runtime.revision,
  }
}

export function resetSearch() {
  paintGeneration += 1
  clearTimeout(refreshTimer)
  cancelAnimationFrame(paintFrame)
  clearTimeout(paintTimer)
  state.query = ''
  state.requestID = 0
  state.matches = []
  state.current = -1
  state.sequence = 0
  clearPresentation()
}

export function inspectSearch() {
  return {
    query: state.query,
    count: state.matches.length,
    current: state.current + 1,
    requestID: state.requestID,
  }
}
