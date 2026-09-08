import React, { useEffect, useLayoutEffect, useRef } from 'react'
import { Compartment, EditorState, StateEffect, StateField, Transaction } from '@codemirror/state'
import {
  Decoration,
  EditorView,
  keymap,
  highlightSpecialChars,
  drawSelection,
  lineNumbers,
  highlightWhitespace,
  ViewPlugin,
  WidgetType,
} from '@codemirror/view'
import { defaultKeymap, indentWithTab } from '@codemirror/commands'
import { markdownLanguage } from '@codemirror/lang-markdown'
import { Language, HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { tags, styleTags } from '@lezer/highlight'
import { registerSourceView } from '../search/searchPresentation.js'
import { runtime } from '../bridge/engineBridge.js'

class LineEnding extends WidgetType {
  eq() {
    return true
  }
  toDOM() {
    const marker = document.createElement('span')
    marker.className = 'source-line-ending'
    marker.textContent = '¬'
    marker.setAttribute('aria-hidden', 'true')
    return marker
  }
}
const lineEnding = new LineEnding()
function visibleLineEndings(view) {
  const marks = []
  const { doc } = view.state
  let line = doc.lineAt(view.viewport.from)
  while (line.to <= view.viewport.to) {
    if (line.to < doc.length)
      marks.push(Decoration.widget({ widget: lineEnding, side: 1 }).range(line.to))
    if (line.number === doc.lines) break
    line = doc.line(line.number + 1)
  }
  return Decoration.set(marks)
}
const lineEndings = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = visibleLineEndings(view)
    }
    update(update) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = visibleLineEndings(update.view)
    }
  },
  { decorations: (plugin) => plugin.decorations },
)

const markdownSourceExtensions = [
  lineEndings,
  lineNumbers(),
  highlightWhitespace(),
  new Language(
    markdownLanguage.data,
    markdownLanguage.parser.configure({
      props: [
        styleTags({
          HeaderMark: tags.heading,
          QuoteMark: tags.quote,
          ListMark: tags.list,
        }),
      ],
    }),
    [],
    'markdown',
  ),
  syntaxHighlighting(
    HighlightStyle.define([
      { tag: tags.heading, class: 'md-source-heading' },
      { tag: tags.strong, class: 'md-source-strong' },
      { tag: tags.emphasis, class: 'md-source-emphasis' },
      { tag: tags.strikethrough, class: 'md-source-strike' },
      { tag: [tags.quote, tags.link, tags.url], class: 'md-source-link' },
      { tag: tags.list, class: 'md-source-list' },
      { tag: tags.monospace, class: 'md-source-code' },
      { tag: [tags.processingInstruction, tags.meta], class: 'md-source-marker' },
    ]),
  ),
]

const searchEffect = StateEffect.define()
const searchMarks = StateField.define({
  create: () => Decoration.none,
  update(value, transaction) {
    value = value.map(transaction.changes)
    for (const effect of transaction.effects) {
      if (effect.is(searchEffect)) {
        value = Decoration.set(
          effect.value.ranges.map((range) =>
            Decoration.mark({
              class:
                effect.value.active?.from === range.from
                  ? 'source-search-current'
                  : 'source-search-match',
            }).range(range.from, range.to),
          ),
          true,
        )
      }
    }
    return value
  },
  provide: (field) => EditorView.decorations.from(field),
})

// One persistent source view; mode, controlled content and highlights reconfigure
// the view without constructing a new editor or a competing undo history.
export function SourceEditor({
  value,
  onChange,
  readOnly,
  nodeKey,
  label = '代码内容',
  inline = false,
  fullDocument = false,
}) {
  const element = useRef(null)
  const view = useRef(null)
  const onChangeRef = useRef(onChange)
  const syncing = useRef(false)
  const editable = useRef(new Compartment())
  onChangeRef.current = onChange
  useLayoutEffect(() => {
    const instance = new EditorView({
      parent: element.current,
      state: EditorState.create({
        doc: value,
        extensions: [
          editable.current.of([
            EditorState.readOnly.of(readOnly),
            EditorView.editable.of(!readOnly),
          ]),
          EditorView.contentAttributes.of({ 'aria-label': label, spellcheck: 'false' }),
          keymap.of([indentWithTab, ...defaultKeymap]),
          highlightSpecialChars(),
          drawSelection(),
          EditorView.lineWrapping,
          searchMarks,
          ...(fullDocument ? markdownSourceExtensions : []),
          EditorView.updateListener.of((update) => {
            if (update.docChanged && !syncing.current) {
              runtime.historyTarget = runtime.editor
              onChangeRef.current(update.state.doc.toString())
            }
          }),
          EditorView.domEventHandlers({
            keydown(event) {
              if (event.metaKey && event.key.toLowerCase() === 'z') {
                event.preventDefault()
                if (event.shiftKey) window.MyEditor.redo()
                else window.MyEditor.undo()
                return true
              }
              return false
            },
          }),
        ],
      }),
    })
    view.current = instance
    const unregister = registerSourceView(nodeKey, {
      highlight(ranges, active) {
        const valid = ranges.filter(
          (range) => range.from >= 0 && range.to <= instance.state.doc.length,
        )
        instance.dispatch({ effects: searchEffect.of({ ranges: valid, active }) })
      },
      navigate(offset) {
        const anchor = Math.max(0, Math.min(offset, instance.state.doc.length))
        instance.dispatch({
          selection: { anchor },
          effects: EditorView.scrollIntoView(anchor, { y: 'start' }),
          annotations: Transaction.addToHistory.of(false),
        })
        instance.focus()
      },
      reveal(match) {
        if (match.to <= instance.state.doc.length)
          instance.dispatch({ effects: EditorView.scrollIntoView(match.from, { y: 'center' }) })
        instance.dom.scrollIntoView({ block: 'center', behavior: 'auto' })
      },
    })
    return () => {
      unregister()
      instance.destroy()
      view.current = null
    }
  }, [nodeKey, fullDocument])
  useLayoutEffect(() => {
    const instance = view.current
    if (!instance || instance.state.doc.toString() === value) return
    syncing.current = true
    instance.dispatch({
      changes: { from: 0, to: instance.state.doc.length, insert: value },
      annotations: Transaction.addToHistory.of(false),
    })
    syncing.current = false
  }, [value])
  useEffect(() => {
    view.current?.dispatch({
      effects: editable.current.reconfigure([
        EditorState.readOnly.of(readOnly),
        EditorView.editable.of(!readOnly),
      ]),
    })
  }, [readOnly])
  return (
    <div
      ref={element}
      className={`source-editor${inline ? ' source-inline' : ''}${fullDocument ? ' source-document' : ''}`}
      data-source-key={nodeKey}
    />
  )
}
