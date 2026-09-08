import React from 'react'
import { DecoratorNode, $getNodeByKey } from 'lexical'
import { useCellValue } from '@mdxeditor/gurx'
import {
  realmPlugin,
  addImportVisitor$,
  addExportVisitor$,
  addLexicalNode$,
  addSyntaxExtension$,
  addMdastExtension$,
  addToMarkdownExtension$,
  readOnly$,
} from '@mdxeditor/editor'
import { toMarkdown } from 'mdast-util-to-markdown'
import { gfmToMarkdown } from 'mdast-util-gfm'
import { frontmatterToMarkdown } from 'mdast-util-frontmatter'
import { markdownOptions, needsRawParagraph, hasMixedTaskItems } from './markdown.js'
import { SourceEditor } from '../editor/SourceEditor.jsx'

function RawBlock({ editor, nodeKey, value, inline }) {
  const readOnly = useCellValue(readOnly$)
  return (
    <SourceEditor
      value={value}
      readOnly={readOnly}
      inline={inline}
      nodeKey={nodeKey}
      label="Markdown 原文块"
      onChange={(next) => {
        editor.update(() => {
          const node = $getNodeByKey(nodeKey)
          if (node instanceof RawMarkdownNode) node.setRaw(next)
        })
      }}
    />
  )
}

class RawMarkdownNode extends DecoratorNode {
  constructor(raw = '', inline = false, key) {
    super(key)
    this.__raw = raw
    this.__inline = inline
  }
  static getType() {
    return 'raw-markdown'
  }
  static clone(node) {
    return new RawMarkdownNode(node.__raw, node.__inline, node.__key)
  }
  static importJSON(node) {
    return new RawMarkdownNode(node.raw, node.inline)
  }
  exportJSON() {
    return { type: 'raw-markdown', version: 1, raw: this.__raw, inline: this.__inline }
  }
  createDOM() {
    return document.createElement(this.__inline ? 'span' : 'div')
  }
  updateDOM() {
    return false
  }
  isInline() {
    return this.__inline
  }
  getTextContent() {
    return this.__raw
  }
  setRaw(value) {
    if (value !== this.__raw) this.getWritable().__raw = value
  }
  decorate(editor) {
    return (
      <RawBlock editor={editor} nodeKey={this.getKey()} value={this.__raw} inline={this.__inline} />
    )
  }
}

function rawSource(node) {
  if (node.data?.originalMarkdown) return node.data.originalMarkdown
  if (node.type === 'html') return node.value
  if (node.type === 'yaml') return `---\n${node.value}\n---`
  if (node.type === 'toml') return `+++\n${node.value}\n+++`
  try {
    return toMarkdown(node, {
      extensions: [gfmToMarkdown(), frontmatterToMarkdown(['yaml', 'toml'])],
    }).trimEnd()
  } catch {
    return node.value || node.raw || ''
  }
}

export const rawMarkdownPlugin = realmPlugin({
  init(realm) {
    realm.pubIn({
      [addSyntaxExtension$]: markdownOptions.extensions,
      [addMdastExtension$]: markdownOptions.mdastExtensions,
      [addLexicalNode$]: RawMarkdownNode,
      [addImportVisitor$]: [
        {
          priority: 100,
          testNode: (node) =>
            ['html', 'yaml', 'toml'].includes(node.type) ||
            needsRawParagraph(node) ||
            hasMixedTaskItems(node),
          visitNode({ mdastNode, mdastParent, lexicalParent }) {
            lexicalParent.append(
              new RawMarkdownNode(rawSource(mdastNode), mdastParent?.type === 'paragraph'),
            )
          },
        },
        {
          priority: -100,
          testNode: () => true,
          visitNode({ mdastNode, mdastParent, lexicalParent }) {
            const raw = rawSource(mdastNode)
            if (!raw) throw new Error('无法无损显示此 Markdown 结构')
            lexicalParent.append(new RawMarkdownNode(raw, mdastParent?.type === 'paragraph'))
          },
        },
      ],
      [addExportVisitor$]: {
        testLexicalNode: (node) => node instanceof RawMarkdownNode,
        visitLexicalNode({ lexicalNode, mdastParent, actions }) {
          actions.appendToParent(mdastParent, { type: 'rawMarkdown', value: lexicalNode.__raw })
        },
      },
      [addToMarkdownExtension$]: { handlers: { rawMarkdown: (node) => node.value } },
    })
  },
})
