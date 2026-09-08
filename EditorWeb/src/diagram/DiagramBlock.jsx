import React, { useEffect, useId, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import { useCellValue } from '@mdxeditor/gurx'
import { readOnly$, useCodeBlockEditorContext } from '@mdxeditor/editor'
import { SourceEditor } from '../editor/SourceEditor.jsx'
import { registerSourceRevealer } from '../search/searchPresentation.js'
import { readContentFontStyle } from '../styles/fontStyles.js'

let mermaidModule
let queue = Promise.resolve()
let nextID = 0
const cache = new Map()
const rootStyleListeners = new Set()
let rootStyleObserver
let rootStyleSnapshot

function readRootStyleSnapshot() {
  const contentFont = readContentFontStyle()
  const dark = document.documentElement.classList.contains('dark-theme')
  const key = `${dark}:${contentFont.signature}`
  if (rootStyleSnapshot?.key === key) return rootStyleSnapshot
  return { key, dark, contentFont }
}

function getRootStyleSnapshot() {
  return (rootStyleSnapshot ??= readRootStyleSnapshot())
}

function subscribeRootStyle(listener) {
  rootStyleListeners.add(listener)
  if (!rootStyleObserver) {
    rootStyleObserver = new MutationObserver(() => {
      const previous = rootStyleSnapshot
      const next = readRootStyleSnapshot()
      if (next === previous) return
      rootStyleSnapshot = next
      for (const notify of rootStyleListeners) notify()
    })
    rootStyleObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'style', 'data-content-font-signature'],
    })
  }
  const current = readRootStyleSnapshot()
  if (current !== rootStyleSnapshot) rootStyleSnapshot = current
  return () => {
    rootStyleListeners.delete(listener)
    if (rootStyleListeners.size === 0) {
      rootStyleObserver?.disconnect()
      rootStyleObserver = undefined
      rootStyleSnapshot = undefined
    }
  }
}

async function renderDiagram(code, dark, contentFont) {
  const key = JSON.stringify([dark, contentFont.signature, code])
  if (cache.has(key)) return cache.get(key)
  const render = queue.then(async () => {
    const mermaid = await (mermaidModule ??= import('mermaid').then((module) => module.default))
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: dark ? 'dark' : 'default',
      suppressErrorRendering: true,
      fontFamily: contentFont.family,
      flowchart: { useMaxWidth: true },
      secure: ['securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering'],
    })
    const { svg } = await mermaid.render(`myeditor-diagram-${++nextID}`, code)
    cache.set(key, svg)
    if (cache.size > 24) cache.delete(cache.keys().next().value)
    return svg
  })
  queue = render.catch(() => {})
  return render
}

// A cached SVG can appear more than once. Scope both the element IDs and all
// their references so one diagram never uses another diagram's markers/styles.
function scopedDiagram(svg, prefix, contentFont) {
  if (!svg) return { markup: '', width: 0 }
  const root = new DOMParser().parseFromString(svg, 'image/svg+xml').documentElement
  const elements = [root, ...root.querySelectorAll('*')]
  const ids = new Map(
    elements
      .filter((element) => element.id)
      .map((element) => [element.id, `${prefix}-${element.id}`]),
  )
  const names = [...ids.keys()]
    .sort((a, b) => b.length - a.length)
    .map((id) => id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  const references = new RegExp(`#(${names.join('|')})(?![\\p{L}\\p{N}_-])`, 'gu')
  const reference = (value) => value.replace(references, (_, id) => `#${ids.get(id)}`)
  for (const element of elements) {
    if (element.id) element.id = ids.get(element.id)
    for (const attribute of [...element.attributes]) {
      if (attribute.name === 'id') continue
      attribute.value =
        attribute.name === 'aria-labelledby' || attribute.name === 'aria-describedby'
          ? attribute.value
              .split(/\s+/)
              .map((id) => ids.get(id) || id)
              .join(' ')
          : reference(attribute.value)
    }
    if (element.tagName === 'style') element.textContent = reference(element.textContent)
  }
  const fontStyle = root.ownerDocument.createElementNS('http://www.w3.org/2000/svg', 'style')
  fontStyle.setAttribute('data-myeditor-font', '')
  fontStyle.textContent = `text, foreignObject, foreignObject * { font-family: ${contentFont.family} !important; font-weight: ${contentFont.weight} !important; font-style: ${contentFont.style} !important; }`
  root.insertBefore(fontStyle, root.firstChild)
  root.setAttribute('data-myeditor-font-signature', contentFont.signature)
  return {
    markup: new XMLSerializer().serializeToString(root),
    width: root.viewBox?.baseVal.width || 0,
  }
}

function MermaidPreview({ code, actualSize }) {
  const [svg, setSVG] = useState('')
  const [error, setError] = useState('')
  const instanceID = useId().replace(/[^\w-]/g, '')
  const { dark, contentFont } = useSyncExternalStore(
    subscribeRootStyle,
    getRootStyleSnapshot,
    getRootStyleSnapshot,
  )
  const fontFamily = contentFont.family
  const fontWeight = contentFont.weight
  const fontStyle = contentFont.style
  const fontSignature = contentFont.signature
  const diagram = useMemo(
    () =>
      scopedDiagram(svg, instanceID, {
        family: fontFamily,
        weight: fontWeight,
        style: fontStyle,
        signature: fontSignature,
      }),
    [svg, instanceID, fontFamily, fontWeight, fontStyle, fontSignature],
  )
  const generation = useRef(0)
  const previousRender = useRef({ code, dark, fontSignature })
  useEffect(() => {
    const token = ++generation.current
    const configurationOnlyChange =
      previousRender.current.code === code &&
      (previousRender.current.dark !== dark ||
        previousRender.current.fontSignature !== fontSignature)
    previousRender.current = { code, dark, fontSignature }
    const timer = setTimeout(
      () => {
        renderDiagram(code, dark, {
          family: fontFamily,
          weight: fontWeight,
          style: fontStyle,
          signature: fontSignature,
        })
          .then((value) => {
            if (token === generation.current) {
              setSVG(value)
              setError('')
            }
          })
          .catch((reason) => {
            if (token === generation.current) {
              setSVG('')
              setError(
                String(reason.message || reason)
                  .split('\n')
                  .slice(0, 4)
                  .join('\n'),
              )
            }
          })
      },
      configurationOnlyChange ? 0 : 160,
    )
    return () => {
      clearTimeout(timer)
      generation.current++
    }
  }, [code, dark, fontFamily, fontWeight, fontStyle, fontSignature])
  if (error)
    return (
      <div className="diagram-error" role="status">
        流程图暂时无法渲染，源码已保留。<pre>{error}</pre>
      </div>
    )
  return svg ? (
    <div
      className="diagram-preview"
      data-scale={actualSize ? 'actual' : 'fit'}
      style={{ '--diagram-width': `${diagram.width}px` }}
      role="img"
      aria-label="Mermaid 流程图"
      dangerouslySetInnerHTML={{ __html: diagram.markup }}
    />
  ) : (
    <div className="diagram-loading">正在绘制流程图…</div>
  )
}

function CodeBlock({ code, language, nodeKey }) {
  const readOnly = useCellValue(readOnly$)
  const { setCode, setLanguage, parentEditor, lexicalNode } = useCodeBlockEditorContext()
  const mermaid = (language || '').toLowerCase() === 'mermaid'
  const [expanded, setExpanded] = useState(false)
  const [actualSize, setActualSize] = useState(false)
  useEffect(() => registerSourceRevealer(nodeKey, () => setExpanded(true)), [nodeKey])
  return (
    <div className={mermaid ? 'diagram-block' : 'code-block'}>
      <div className="source-toolbar">
        {readOnly ? (
          <span>{language || '纯文本'}</span>
        ) : (
          <select
            aria-label="代码语言"
            value={language}
            onChange={(event) => setLanguage(event.target.value)}
          >
            {[
              ...new Set([
                '',
                'mermaid',
                'js',
                'ts',
                'swift',
                'python',
                'json',
                'css',
                'html',
                'bash',
                'markdown',
                language,
              ]),
            ].map((value) => (
              <option key={value} value={value}>
                {value || '纯文本'}
              </option>
            ))}
          </select>
        )}
        {mermaid && (
          <button
            type="button"
            aria-pressed={actualSize}
            onClick={() => setActualSize((value) => !value)}
          >
            {actualSize ? '适应宽度' : '原始大小'}
          </button>
        )}
        {mermaid && (
          <button type="button" onClick={() => setExpanded((value) => !value)}>
            {expanded ? '收起源码' : readOnly ? '查看源码' : '编辑源码'}
          </button>
        )}
        {!readOnly && (
          <button
            type="button"
            aria-label="删除代码块"
            onClick={() => parentEditor.update(() => lexicalNode.getLatest().remove())}
          >
            删除
          </button>
        )}
      </div>
      {mermaid && <MermaidPreview code={code} actualSize={actualSize} />}
      {(!mermaid || expanded) && (
        <SourceEditor
          value={code}
          onChange={setCode}
          readOnly={readOnly}
          nodeKey={nodeKey}
          label={mermaid ? '流程图源码' : '代码内容'}
        />
      )}
    </div>
  )
}

export const codeBlockDescriptor = { priority: 10, match: () => true, Editor: CodeBlock }
