import test from 'node:test'
import assert from 'node:assert/strict'
import {
  extractOutline,
  primaryHeadings,
  parseMarkdown,
  imagePreviewURL,
  needsRawParagraph,
  hasMixedTaskItems,
} from '../src/markdown/markdown.js'

test('empty and heading-free documents are valid', () => {
  assert.deepEqual(extractOutline(''), [])
  assert.deepEqual(extractOutline('普通正文\n\n- 项目'), [])
})
test('AST outline includes all heading forms and ignores code/front matter', () => {
  const text =
    '---\ntitle: 标题\n---\n\n书名\n====\n\n## 重复\n\n```md\n# 代码，不是标题\n```\n\n    ## 缩进代码\n\n#### 小节\n\n## 重复\n\n六级\n----\n\n###### 末尾'
  const headings = extractOutline(text)
  assert.deepEqual(
    headings.map((h) => h.level),
    [1, 2, 4, 2, 2, 6],
  )
  assert.equal(new Set(headings.map((h) => h.id)).size, headings.length)
  assert.deepEqual(
    primaryHeadings(headings).map((h) => h.title),
    ['重复', '重复', '六级'],
  )
  const updated = extractOutline(text.replace('#### 小节', '增加正文。\n\n#### 小节'), headings)
  assert.deepEqual(
    updated.map((h) => h.id),
    headings.map((h) => h.id),
  )
})
test('GFM lists, table, strikethrough, links, images and raw HTML parse together', () => {
  const ast = parseMarkdown(
    '- [x] 任务\n\n| A | B |\n| - | - |\n| 中 | 文 |\n\n~~旧~~ [链接](https://example.com) ![图](./图.png)\n\n<script>不执行</script>',
  )
  assert.ok(ast.children.some((n) => n.type === 'list'))
  assert.ok(ast.children.some((n) => n.type === 'table'))
  assert.ok(ast.children.some((n) => n.type === 'html' && n.value.includes('<script>')))
})
test('main chapter policy handles a single title and several top-level sections', () => {
  assert.equal(primaryHeadings(extractOutline('# 单标题')).length, 1)
  assert.deepEqual(
    primaryHeadings(extractOutline('# 一\n\n## 小节\n\n# 二')).map((h) => h.title),
    ['一', '二'],
  )
})
test('local image preview leaves the Markdown URL unchanged and encodes Unicode paths', () => {
  assert.equal(
    imagePreviewURL('../图 片/a.png'),
    'myeditor-resource://document/image?path=..%2F%E5%9B%BE%20%E7%89%87%2Fa.png',
  )
  assert.equal(imagePreviewURL('https://example.com/a.png'), 'https://example.com/a.png')
  assert.equal(imagePreviewURL('javascript:alert(1)'), '')
})

test('raw extension text survives parsing and CommonMark references resolve', () => {
  const raw = '[[双向链接]] 与 $x^2$，脚注[^注]。'
  const ast = parseMarkdown(
    '# 标题\n\n' +
      raw +
      '\n\n[网站][site]\n\n![相对图片][photo]\n\n[site]: https://example.com "说明"\n[photo]: ./图.png\n',
  )
  assert.equal(ast.children[1].data.originalMarkdown, raw)
  assert.ok(needsRawParagraph(ast.children[1]))
  assert.equal(ast.children[2].children[0].type, 'link')
  assert.equal(ast.children[2].children[0].url, 'https://example.com')
  assert.equal(ast.children[3].children[0].type, 'image')
  assert.equal(ast.children[3].children[0].url, './图.png')
  assert.equal(ast.children[4].data.originalMarkdown, '[site]: https://example.com "说明"')

  const mixedList = '- [x] 已完成的任务\n- 普通列表'
  const list = parseMarkdown(mixedList).children[0]
  assert.ok(hasMixedTaskItems(list))
  assert.equal(list.data.originalMarkdown, mixedList)
  assert.equal(list.children[0].children[0].children[0].value, '已完成的任务')
  assert.equal(list.children[1].checked, null)
})

test('first duplicate reference definition wins for links and images', () => {
  const root = parseMarkdown('[foo] ![foo]\n\n[foo]: first "first title"\n[FOO]: second\n')
  const links = root.children[0].children.filter((node) => ['link', 'image'].includes(node.type))
  assert.equal(links.length, 2)
  for (const link of links) {
    assert.equal(link.url, 'first')
    assert.equal(link.title, 'first title')
  }
})
