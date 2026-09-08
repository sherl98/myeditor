import React, { useEffect, useRef, useState } from 'react'
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
} from 'lexical'
import '@mdxeditor/editor/style.css'
import { extractOutline, imagePreviewURL } from './markdown/markdown.js'
import { rawMarkdownPlugin } from './markdown/rawMarkdown.jsx'
import { engineBridgePlugin, runtime, post, postHistory } from './bridge/engineBridge.js'
import { addWheelDelta, cancelWheel, navigate, refreshHeadingElements } from './editor/scrolling.js'
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
import './styles/styles.css'

const plugins = [
  headingsPlugin({ allowedHeadingLevels: [1, 2, 3, 4, 5, 6] }),
  listsPlugin(),
  quotePlugin(),
  thematicBreakPlugin(),
  linkPlugin(),
  linkDialogPlugin(),
  imagePlugin({ imagePreviewHandler: async (source) => imagePreviewURL(source) }),
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
const compositionWaiters = new Set()
function finishCompositionWaits() {
  for (const resolve of compositionWaiters) resolve()
  compositionWaiters.clear()
}

let outlineTimer, outlineDeadline
let lastOutlineSource = null
let lastPublishedSequence = -1
function cancelOutline() {
  clearTimeout(outlineTimer)
  clearTimeout(outlineDeadline)
  outlineDeadline = undefined
}
function updateOutline(force = false) {
  cancelOutline()
  if (!force && lastOutlineSource === runtime.source) return
  try {
    const headings = extractOutline(runtime.source, runtime.outline)
    lastOutlineSource = runtime.source
    if (force || JSON.stringify(headings) !== JSON.stringify(runtime.outline)) {
      runtime.outline = headings
      post('outline', { headings })
    }
    requestAnimationFrame(refreshHeadingElements)
  } catch {
    // Keep navigation until the incomplete construct becomes parseable.
  }
}
function scheduleOutline() {
  clearTimeout(outlineTimer)
  outlineTimer = setTimeout(updateOutline, 160)
  outlineDeadline ??= setTimeout(updateOutline, 1000)
}
function publishSource() {
  if (lastPublishedSequence === runtime.sequence) {
    // A no-op input still needs to settle the native pending marker, without
    // sending another full document across the bridge.
    if (!runtime.composing) post('settled', { sequence: runtime.sequence })
    return
  }
  lastPublishedSequence = runtime.sequence
  post('change', {
    source: runtime.source,
    sequence: runtime.sequence,
    composing: runtime.composing,
  })
}
function changed(source, initial = false) {
  if (!runtime.loaded || runtime.programmatic || initial) return
  if (source === runtime.source) return
  runtime.source = source
  runtime.updateSourcePreview?.(source)
  runtime.sequence++
  publishSource()
  scheduleOutline()
  refreshSearch()
}

function App() {
  const editorRef = useRef(null)
  const [readOnly, setReadOnly] = useState(true)
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
    window.MyEditor = {
      async load(options) {
        const token = (runtime.loadToken = (runtime.loadToken || 0) + 1)
        finishCompositionWaits()
        cancelWheel()
        resetSearch()
        cancelOutline()
        lastOutlineSource = null
        lastPublishedSequence = -1
        runtime.outline = []
        const previousY = window.scrollY
        runtime.programmatic = true
        runtime.loaded = false
        runtime.sessionID = options.sessionID
        runtime.revision = options.revision
        runtime.validation = !!options.validation
        runtime.sequence = 0
        runtime.original = options.source
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
        editorRef.current?.setMarkdown(options.source)
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
        this.configure(options)
        updateOutline(true)
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
        const wasReadOnly = runtime.readOnly
        runtime.showsSource = !!options.showsSource
        setShowsSource(runtime.showsSource)
        setSourcePreview(runtime.source)
        runtime.readOnly = options.readOnly
        setReadOnly(options.readOnly)
        document.documentElement.style.setProperty(
          '--body-size',
          String((21 * options.fontPercent) / 100) + 'px',
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
      },
      async flush(commitComposition = false) {
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
        return {
          ok: true,
          source: runtime.source,
          sequence: runtime.sequence,
          revision: runtime.revision,
          sessionID: runtime.sessionID,
        }
      },
      async undo() {
        if (runtime.fallback) {
          const history = fallbackHistory.current
          if (history.undo.length) {
            history.redo.push(runtime.source)
            fallbackEdit(history.undo.pop(), false)
          }
        } else
          (runtime.historyTarget || runtime.activeEditor || runtime.editor)?.dispatchCommand(
            UNDO_COMMAND,
            undefined,
          )
        await nextFrame()
        publishSource()
        refreshSearch()
        if (runtime.historyTarget === runtime.editor) {
          runtime.canUndo = runtime.history.undoStack.length > 0
          runtime.canRedo = runtime.history.redoStack.length > 0
          postHistory()
        }
      },
      async redo() {
        if (runtime.fallback) {
          const history = fallbackHistory.current
          if (history.redo.length) {
            history.undo.push(runtime.source)
            fallbackEdit(history.redo.pop(), false)
          }
        } else
          (runtime.historyTarget || runtime.activeEditor || runtime.editor)?.dispatchCommand(
            REDO_COMMAND,
            undefined,
          )
        await nextFrame()
        publishSource()
        refreshSearch()
        if (runtime.historyTarget === runtime.editor) {
          runtime.canUndo = runtime.history.undoStack.length > 0
          runtime.canRedo = runtime.history.redoStack.length > 0
          postHistory()
        }
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
          post('pending')
          requestAnimationFrame(publishSource)
        }
      }}
      onCompositionStartCapture={() => {
        runtime.composing = true
        post('composition', { composing: true })
      }}
      onCompositionEndCapture={() => {
        runtime.composing = false
        queueMicrotask(() => {
          publishSource()
          post('composition', { composing: false })
          scheduleOutline()
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
          plugins={plugins}
          suppressHtmlProcessing={true}
          toMarkdownOptions={markdownOutput}
          onChange={changed}
          placeholder={readOnly ? '' : '开始写作…'}
          onError={({ source, error }) => {
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
