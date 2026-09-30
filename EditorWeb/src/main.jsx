import React, { useEffect, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  MDXEditor,
  headingsPlugin,
  listsPlugin,
  quotePlugin,
  thematicBreakPlugin,
  markdownShortcutPlugin,
  linkPlugin,
  linkDialogPlugin,
  imagePlugin,
  tablePlugin,
  codeBlockPlugin,
  NESTED_EDITOR_UPDATED_COMMAND,
} from '@mdxeditor/editor'
import {
  UNDO_COMMAND,
  REDO_COMMAND,
  CLEAR_HISTORY_COMMAND,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $isTextNode,
} from 'lexical'
import '@mdxeditor/editor/style.css'
import { extractOutline, imagePreviewURL } from './markdown/markdown.js'
import { rawMarkdownPlugin } from './markdown/rawMarkdown.jsx'
import { engineBridgePlugin, runtime, post, postHistory } from './bridge/engineBridge.js'
import {
  addWheelDelta,
  cancelWheel,
  navigate,
  refreshHeadingElements,
  captureReadingPosition,
} from './editor/scrolling.js'
import { codeBlockDescriptor } from './diagram/DiagramBlock.jsx'
import { SourceEditor } from './editor/SourceEditor.jsx'
import {
  search,
  replace,
  clearSearch,
  resetSearch,
  refreshSearch,
  inspectSearch,
} from './search/search.js'
import { applyEditorFonts } from './styles/fontStyles.js'
import { markLatinParagraphs } from './styles/scriptDirection.js'
import {
  abandonImport,
  importDocument,
  beginTracking,
  exportDocument,
  scheduleExport,
  stopTracking,
  inspectSync,
} from './editor/documentSync.js'
import './styles/styles.css'

const plugins = [
  headingsPlugin({ allowedHeadingLevels: [1, 2, 3, 4, 5, 6] }),
  listsPlugin(),
  quotePlugin(),
  thematicBreakPlugin(),
  linkPlugin(),
  linkDialogPlugin(),
  tablePlugin(),
  codeBlockPlugin({
    defaultCodeBlockLanguage: '',
    codeBlockEditorDescriptors: [codeBlockDescriptor],
  }),
  markdownShortcutPlugin(),
  rawMarkdownPlugin(),
  engineBridgePlugin(),
]
const markdownOutput = {
  bullet: '-',
  emphasis: '*',
  strong: '*',
  fences: true,
  listItemIndent: 'one',
}
const nextFrame = () =>
  new Promise((resolve) => {
    const fallback = setTimeout(resolve, 32)
    requestAnimationFrame(() => {
      clearTimeout(fallback)
      resolve()
    })
  })
let mountCount = 0
let appliedLayoutKey
let layoutGeneration = 0
const compositionWaiters = new Set()
function finishCompositionWaits() {
  for (const resolve of compositionWaiters) resolve()
  compositionWaiters.clear()
}

// Network images stay unloaded until the document or the user allows them.
const blockedImagePlaceholder = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="72"><rect width="320" height="72" rx="10" fill="#8883"/><text x="160" y="41" font-family="-apple-system,system-ui" font-size="14" fill="#888" text-anchor="middle">网络图片未加载</text></svg>',
)}`
const blockedImages = new Set()
let blockedImagesTimer
function noteBlockedImage(url) {
  if (blockedImages.has(url)) return
  blockedImages.add(url)
  clearTimeout(blockedImagesTimer)
  blockedImagesTimer = setTimeout(() => post('remoteImages', { blocked: blockedImages.size }), 50)
}
function resetBlockedImages() {
  clearTimeout(blockedImagesTimer)
  blockedImages.clear()
}

function applyOutline(headings, force = false) {
  if (force || JSON.stringify(headings) !== JSON.stringify(runtime.outline)) {
    runtime.outline = headings
    post('outline', { headings })
  }
  requestAnimationFrame(refreshHeadingElements)
}

// Whole-document outline, used only by the fallback source view.
let outlineTimer, outlineDeadline
function cancelOutline() {
  clearTimeout(outlineTimer)
  clearTimeout(outlineDeadline)
  outlineDeadline = undefined
}
function updateFallbackOutline() {
  cancelOutline()
  try {
    applyOutline(extractOutline(runtime.source, runtime.outline))
  } catch {
    // Keep navigation until the incomplete construct becomes parseable.
  }
}
function scheduleFallbackOutline() {
  clearTimeout(outlineTimer)
  outlineTimer = setTimeout(updateFallbackOutline, 160)
  outlineDeadline ??= setTimeout(updateFallbackOutline, 1000)
}

// Native learns about input immediately, but receives the Markdown only when
// the editor is idle, on flush, or at most once per second while typing.
let pendingPosted = false
function markPending() {
  if (pendingPosted || !runtime.loaded) return
  pendingPosted = true
  post('pending')
}
function publish(changed) {
  pendingPosted = false
  if (changed)
    post('change', { source: runtime.source, sequence: runtime.sequence, composing: false })
  else post('settled', { sequence: runtime.sequence })
}
let syncTiming = null
// Validation builds keep every export's timing for the performance checks.
const syncLog = []
function syncDocument({ notify = true } = {}) {
  if (!runtime.loaded || runtime.fallback || runtime.composing) return
  const started = performance.now()
  const { text, outline } = exportDocument(runtime.outline)
  const exported = performance.now()
  applyOutline(outline)
  const changed = text !== runtime.source
  if (changed) {
    runtime.source = text
    runtime.sequence++
    if (runtime.showsSource) runtime.updateSourcePreview?.(text)
    refreshSearch()
  }
  const applied = performance.now()
  if (notify) publish(changed)
  else pendingPosted = false
  syncTiming = {
    at: +started.toFixed(1),
    changed,
    export: +(exported - started).toFixed(1),
    apply: +(applied - exported).toFixed(1),
    post: +(performance.now() - applied).toFixed(1),
  }
  if (runtime.validation) {
    syncLog.push(syncTiming)
    // How long until the page can paint again after this export.
    const entry = syncTiming
    requestAnimationFrame(() => (entry.nextFrame = +(performance.now() - started).toFixed(1)))
    setTimeout(() => (entry.nextTask = +(performance.now() - started).toFixed(1)), 0)
  }
}
runtime.onDocumentDirty = () => {
  if (!runtime.loaded || runtime.programmatic || runtime.fallback) return
  markPending()
  refreshSearch()
  scheduleExport(() => syncDocument())
}
// Fallback source view edits replace the whole text.
function changed(source) {
  if (!runtime.loaded || runtime.programmatic || source === runtime.source) return
  runtime.source = source
  runtime.sequence++
  publish(true)
  scheduleFallbackOutline()
  refreshSearch()
}

function App() {
  const editorRef = useRef(null)
  const [readOnly, setReadOnly] = useState(true)
  const [imageResourceBase, setImageResourceBase] = useState('')
  const [remoteImages, setRemoteImages] = useState(false)
  // A new handler makes MDXEditor request every image again, without reloading.
  const pluginsWithImages = useMemo(
    () => [
      ...plugins,
      imagePlugin({
        imagePreviewHandler: async (source) => {
          const preview = imagePreviewURL(source)
          if (/^https?:/i.test(preview) && !remoteImages) {
            noteBlockedImage(preview)
            return blockedImagePlaceholder
          }
          if (!preview.startsWith('myeditor-resource:')) return preview
          const url = new URL(preview)
          url.searchParams.set('base', imageResourceBase)
          return url.href
        },
      }),
    ],
    [imageResourceBase, remoteImages],
  )
  const [showsSource, setShowsSource] = useState(false)
  const [sourcePreview, setSourcePreview] = useState('')
  const [fallback, setFallback] = useState(null)
  const [fallbackText, setFallbackText] = useState('')
  const fallbackHistory = useRef({ undo: [], redo: [], lastChange: 0 })

  function fallbackEdit(value, history = true, force = false) {
    if (value === runtime.source) return
    if (history) {
      const current = fallbackHistory.current
      if (force || Date.now() - current.lastChange > 1000) current.undo.push(runtime.source)
      current.redo = []
      current.lastChange = force ? 0 : Date.now()
    }
    setFallbackText(value)
    changed(value)
    runtime.canUndo = fallbackHistory.current.undo.length > 0
    runtime.canRedo = fallbackHistory.current.redo.length > 0
    postHistory()
  }

  useEffect(() => {
    refreshSearch()
    refreshHeadingElements()
  }, [showsSource])

  useEffect(() => {
    mountCount++
    runtime.applyFallback = fallbackEdit
    runtime.updateSourcePreview = setSourcePreview
    async function applyHistory(command) {
      if (runtime.fallback) {
        const history = fallbackHistory.current
        const [from, to] =
          command === 'undo' ? [history.undo, history.redo] : [history.redo, history.undo]
        if (from.length) {
          to.push(runtime.source)
          fallbackEdit(from.pop(), false)
        }
      } else
        (runtime.historyTarget || runtime.activeEditor || runtime.editor)?.dispatchCommand(
          command === 'undo' ? UNDO_COMMAND : REDO_COMMAND,
          undefined,
        )
      await nextFrame()
      if (runtime.fallback) publish(false)
      else syncDocument()
      refreshSearch()
      if (runtime.historyTarget === runtime.editor) {
        runtime.canUndo = runtime.history.undoStack.length > 0
        runtime.canRedo = runtime.history.redoStack.length > 0
        postHistory()
      }
    }
    window.MyEditor = {
      async load(options) {
        const token = ++runtime.loadToken
        finishCompositionWaits()
        cancelWheel()
        resetSearch()
        resetBlockedImages()
        cancelOutline()
        stopTracking()
        pendingPosted = false
        runtime.outline = []
        const previousY = window.scrollY
        runtime.programmatic = true
        runtime.loaded = false
        runtime.sessionID = options.sessionID
        runtime.revision = options.revision
        runtime.validation = !!options.validation
        runtime.sequence = 0
        runtime.source = options.source
        runtime.composing = false
        runtime.fallback = false
        runtime.canUndo = false
        runtime.canRedo = false
        runtime.historyTarget = null
        runtime.cellDirty = false
        fallbackHistory.current = { undo: [], redo: [], lastChange: 0 }
        setFallback(null)
        setFallbackText(options.source)
        await importDocument(options.source, (source) => editorRef.current?.setMarkdown(source))
        if (token !== runtime.loadToken) return
        await nextFrame()
        if (token !== runtime.loadToken) return
        runtime.editor?.dispatchCommand(CLEAR_HISTORY_COMMAND, undefined)
        if (runtime.editor && runtime.history) {
          runtime.history.current = {
            editor: runtime.editor,
            editorState: runtime.editor.getEditorState(),
          }
        }
        runtime.programmatic = false
        runtime.loaded = true
        if (runtime.fallback) {
          try {
            applyOutline(extractOutline(options.source), true)
          } catch {
            applyOutline([], true)
          }
        } else applyOutline(beginTracking(options.source, []), true)
        this.configure(options)
        postHistory()
        post('loaded')
        if (options.preserveScroll) requestAnimationFrame(() => window.scrollTo(0, previousY))
      },
      setAppearance(appearance, resolvedDarkAppearance) {
        document.documentElement.dataset.appearance = appearance
        // AppKit owns appearance for both the window and this embedded document.
        // WebKit media events can arrive later with a different/stale appearance.
        document.documentElement.classList.toggle(
          'dark-theme',
          appearance === 'dark' || (appearance === 'system' && resolvedDarkAppearance === true),
        )
        return true
      },
      configure(options) {
        const layoutKey = JSON.stringify([
          options.readOnly,
          options.fontPercent,
          options.contentFontFace,
          options.showsSource,
          options.railOffset,
          options.bodyOpticalOffset,
        ])
        const layoutChanged = appliedLayoutKey !== layoutKey
        const restorePosition = layoutChanged ? captureReadingPosition() : () => {}
        appliedLayoutKey = layoutKey
        const wasReadOnly = runtime.readOnly
        // The source preview shows exported Markdown; export pending edits first.
        if (options.showsSource && !runtime.showsSource) syncDocument()
        runtime.showsSource = !!options.showsSource
        setShowsSource(runtime.showsSource)
        setSourcePreview(runtime.source)
        runtime.readOnly = options.readOnly
        setReadOnly(options.readOnly)
        document.documentElement.style.setProperty(
          '--font-scale',
          String(options.fontPercent / 100),
        )
        applyEditorFonts(document.documentElement, options)
        document.documentElement.style.setProperty(
          '--rail-offset',
          String(Math.max(0, Number(options.railOffset) || 0)) + 'px',
        )
        document.documentElement.style.setProperty(
          '--body-optical-offset',
          String(Math.max(0, Number(options.bodyOpticalOffset) || 0)) + 'px',
        )
        const accent = /^#[\da-f]{6}$/i.test(options.accent || '') ? options.accent : '#007aff'
        document.documentElement.style.setProperty('--accent-color', accent)
        const rgb = [1, 3, 5].map((index) => parseInt(accent.slice(index, index + 2), 16) / 255)
        const light = rgb.map((value) =>
          value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4,
        )
        document.documentElement.style.setProperty(
          '--accent-ink',
          light[0] * 0.2126 + light[1] * 0.7152 + light[2] * 0.0722 > 0.179 ? '#111111' : '#ffffff',
        )
        document.documentElement.classList.toggle('read-only', options.readOnly)
        if (options.readOnly)
          requestAnimationFrame(() =>
            markLatinParagraphs(document.querySelector('.document-content')),
          )
        this.setAppearance(options.appearance, options.resolvedDarkAppearance)
        if (!options.readOnly && wasReadOnly && !options.preserveFocus) {
          requestAnimationFrame(() =>
            document
              .querySelector('.document-content, .source-fallback .cm-content')
              ?.focus({ preventScroll: true }),
          )
        }
        cancelWheel()
        refreshSearch()
        if (layoutChanged) {
          const generation = ++layoutGeneration
          requestAnimationFrame(() =>
            requestAnimationFrame(() => {
              if (generation !== layoutGeneration) return
              restorePosition()
              refreshHeadingElements()
              refreshSearch()
            }),
          )
        }
        setImageResourceBase(options.resourceBase || '')
        if (options.remoteImages) resetBlockedImages()
        setRemoteImages(!!options.remoteImages)
      },
      // Native reads the source from the reply; calls made inside the page
      // (search and replace) also notify native of the exported change.
      async flush(commitComposition = false, notify = false) {
        const revision = runtime.revision
        if (commitComposition && runtime.composing) {
          document.activeElement?.blur()
          await Promise.resolve()
        }
        if (runtime.composing) await new Promise((resolve) => compositionWaiters.add(resolve))
        // A hidden system tab may not receive animation frames. Lexical's public
        // force-commit read drains updates without waiting for the view to paint.
        if (!runtime.fallback) {
          if (runtime.cellDirty && runtime.activeEditor !== runtime.editor) {
            runtime.activeEditor?.dispatchCommand(NESTED_EDITOR_UPDATED_COMMAND, undefined)
            runtime.cellDirty = false
          }
          runtime.activeEditor?.read(() => {})
          if (runtime.editor !== runtime.activeEditor) runtime.editor?.read(() => {})
        }
        await Promise.resolve()
        if (!runtime.loaded || runtime.composing || revision !== runtime.revision)
          return { ok: false }
        syncDocument({ notify })
        return {
          ok: true,
          source: runtime.source,
          sequence: runtime.sequence,
          revision: runtime.revision,
          sessionID: runtime.sessionID,
        }
      },
      undo() {
        return applyHistory('undo')
      },
      redo() {
        return applyHistory('redo')
      },
      navigate,
      addWheelDelta,
      cancelWheel,
      search,
      clearSearch,
      replace,
      inspect() {
        return {
          loaded: runtime.loaded,
          readOnly: runtime.readOnly,
          showsSource: runtime.showsSource,
          composing: runtime.composing,
          fallback: runtime.fallback,
          sequence: runtime.sequence,
          source: runtime.source,
          headings: runtime.outline,
          canUndo: runtime.canUndo,
          canRedo: runtime.canRedo,
          mountCount,
          search: inspectSearch(),
          sync: {
            ...inspectSync(),
            lastSync: syncTiming,
            log: syncLog.slice(-20),
          },
          headingCount: document.querySelectorAll(
            '.document-content h1,.document-content h2,.document-content h3,.document-content h4,.document-content h5,.document-content h6',
          ).length,
        }
      },
      async validationEdit(text) {
        if (!runtime.validation) throw new Error('Validation is not enabled')
        runtime.editor.update(
          () => {
            $getRoot().append($createParagraphNode().append($createTextNode(text)))
          },
          { discrete: true },
        )
        syncDocument()
        await nextFrame()
        return this.inspect()
      },
      // Appends text to the last text of top-level block `index` as one edit.
      async validationEditBlock(index, text) {
        if (!runtime.validation) throw new Error('Validation is not enabled')
        runtime.historyTarget = runtime.editor
        runtime.editor.update(
          () => {
            const block = $getRoot().getChildAtIndex(index)
            const last = block?.getLastDescendant?.()
            if ($isTextNode(last)) last.setTextContent(last.getTextContent() + text)
            else block?.append?.($createTextNode(text))
          },
          { discrete: true },
        )
        syncDocument()
        await nextFrame()
        return this.inspect()
      },
    }
    post('ready')
    return () => {
      cancelWheel()
      cancelOutline()
      runtime.updateSourcePreview = null
      delete window.MyEditor
    }
  }, [])

  return (
    <main
      className={`editor-stage${showsSource || fallback ? ' source-stage' : ''}`}
      onBeforeInputCapture={(event) => {
        if (runtime.loaded && !runtime.programmatic && !runtime.readOnly) {
          const inSource = !!event.target.closest?.('[data-source-key]')
          runtime.historyTarget = inSource ? runtime.editor : runtime.activeEditor
          runtime.cellDirty = !inSource && !!event.target.closest?.('td,th')
          markPending()
          // Settles the native pending marker even when the input changes nothing.
          if (runtime.fallback)
            requestAnimationFrame(() => {
              if (pendingPosted) publish(false)
            })
          else scheduleExport(() => syncDocument())
        }
      }}
      onCompositionStartCapture={() => {
        runtime.composing = true
        post('composition', { composing: true })
      }}
      onCompositionEndCapture={() => {
        runtime.composing = false
        queueMicrotask(() => {
          if (runtime.fallback) {
            if (pendingPosted) publish(false)
          } else syncDocument()
          post('composition', { composing: false })
          finishCompositionWaits()
        })
      }}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) {
          requestAnimationFrame(() => {
            if (runtime.loaded) post('blur')
          })
        }
      }}
    >
      {fallback && (
        <div className="fallback-notice" role="status">
          此文档包含暂未支持的语法，已保留完整原文。
        </div>
      )}
      <div style={fallback || showsSource ? { display: 'none' } : undefined}>
        <MDXEditor
          ref={editorRef}
          markdown=""
          readOnly={readOnly}
          trim={false}
          contentEditableClassName="document-content"
          plugins={pluginsWithImages}
          suppressHtmlProcessing={true}
          toMarkdownOptions={markdownOutput}
          placeholder={readOnly ? '' : '开始写作…'}
          onError={({ source, error }) => {
            abandonImport()
            runtime.fallback = true
            setFallback(error)
            setFallbackText(source || runtime.source)
            post('notice', { message: '原文模式 · 内容完整保留' })
          }}
        />
      </div>
      {showsSource && !fallback && (
        <div className="source-fallback">
          <SourceEditor
            value={sourcePreview}
            readOnly={true}
            nodeKey="source-preview"
            fullDocument
            label="Markdown 源码预览（只读）"
          />
        </div>
      )}
      {fallback && (
        <div className="source-fallback">
          <SourceEditor
            value={fallbackText}
            readOnly={readOnly}
            onChange={fallbackEdit}
            nodeKey="fallback"
            fullDocument
            label="全文 Markdown 原文"
          />
        </div>
      )}
    </main>
  )
}

createRoot(document.getElementById('root')).render(<App />)
