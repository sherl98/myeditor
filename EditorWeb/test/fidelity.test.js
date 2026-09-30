import test from 'node:test'
import assert from 'node:assert/strict'
import {
  blockHeadings,
  extractOutline,
  inferMarkdownStyle,
  outlineFromBlocks,
  parseMarkdown,
  referenceDefinitions,
  referenceUsages,
  restoreReferenceLinks,
  visibleCharacterCount,
} from '../src/markdown/markdown.js'
import { largeManuscript } from '../../Fixtures/large-manuscript.mjs'

// Mirrors how the editor describes top-level blocks after an export.
function outlineByBlocks(text) {
  const blocks = parseMarkdown(text).children.map((node) => {
    const slice = text.slice(node.position.start.offset, node.position.end.offset)
    return {
      start: node.position.start.offset,
      count: visibleCharacterCount(slice),
      headings: blockHeadings(slice),
    }
  })
  return outlineFromBlocks(blocks)
}
const shape = (outline) => outline.map(({ id, ...heading }) => heading)

test('block outline matches the whole-document outline', () => {
  const samples = [
    largeManuscript(),
    '---\ntitle: 标题\n---\n\n书名\n====\n\n## 重复\n\n```md\n# 代码，不是标题\n```\n\n    ## 缩进代码\n\n#### 小节\n\n正文 **粗体**。\n\n## 重复\n\n六级\n----\n\n###### 末尾',
    '# 一\n\n> ## 引文中的标题\n>\n> 引文正文。\n\n- ## 列表中的标题\n\n  列表正文。\n\n## 二\n\n中文与 emoji 👩🏽‍💻。\n',
    '',
    '只有正文，没有标题。\n',
  ]
  for (const text of samples)
    assert.deepEqual(shape(outlineByBlocks(text)), shape(extractOutline(text)))
})

test('block outline keeps heading identities across edits', () => {
  const text = '# 书\n\n## 甲\n\n正文。\n\n## 乙\n'
  const blocks = (source) =>
    parseMarkdown(source).children.map((node) => {
      const slice = source.slice(node.position.start.offset, node.position.end.offset)
      return { start: node.position.start.offset, count: 0, headings: blockHeadings(slice) }
    })
  const first = outlineFromBlocks(blocks(text))
  const second = outlineFromBlocks(blocks(text.replace('正文。', '更多正文。')), first)
  assert.deepEqual(
    second.map((heading) => heading.id),
    first.map((heading) => heading.id),
  )
})

test('visible character count ignores whitespace and counts code points', () => {
  assert.equal(visibleCharacterCount(' 中文\n\t👩🏽‍💻 a　b '), Array.from('中文👩🏽‍💻ab').length)
  assert.equal(visibleCharacterCount(''), 0)
})

test('syntax style is inferred from the original Markdown', () => {
  assert.deepEqual(inferMarkdownStyle('+ 甲\n+ 乙'), { bullet: '+' })
  assert.deepEqual(inferMarkdownStyle('1) 甲\n2) 乙'), { bulletOrdered: ')' })
  assert.deepEqual(inferMarkdownStyle('有 _斜体_ 和 __粗体__。'), { emphasis: '_', strong: '_' })
  assert.deepEqual(inferMarkdownStyle('snake_case_name 与 *星号*'), { emphasis: '*' })
  assert.deepEqual(inferMarkdownStyle('* * *'), {
    bullet: '*',
    rule: '*',
    ruleSpaces: true,
    ruleRepetition: 3,
  })
  assert.deepEqual(inferMarkdownStyle('~~~js\ncode\n~~~'), { fence: '~' })
  assert.deepEqual(inferMarkdownStyle('    缩进代码'), { fences: false })
  assert.deepEqual(inferMarkdownStyle('标题\n===='), { setext: true })
  assert.deepEqual(inferMarkdownStyle('标题\n----'), {
    setext: true,
    rule: '-',
    ruleSpaces: false,
    ruleRepetition: 4,
  })
  // Front matter's closing `---` is not a setext underline for the document.
  assert.equal(inferMarkdownStyle('---\ntitle: 书\n---\n\n# 书').setext, undefined)
})

test('edited reference links are written as references again', () => {
  const source =
    '参考 [示例][ref] 与 [简写][]、![图][pic]。\n\n[ref]: https://example.com "标题"\n[简写]: https://short.example\n[pic]: ./图.png'
  const definitions = referenceDefinitions(source)
  assert.deepEqual(definitions.get('ref'), { url: 'https://example.com', title: '标题' })
  const usages = referenceUsages(source)
  const exported =
    '改过的 [示例](https://example.com "标题") 与 [简写](https://short.example)、![图](./图.png)，[其他](https://other.example)。'
  assert.equal(
    restoreReferenceLinks(exported, usages, definitions),
    '改过的 [示例][ref] 与 [简写][]、![图][pic]，[其他](https://other.example)。',
  )
  // A link whose destination differs from the definition stays inline.
  assert.equal(
    restoreReferenceLinks('[示例](https://changed.example)', usages, definitions),
    '[示例](https://changed.example)',
  )
})
