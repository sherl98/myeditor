import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

// Deterministic synthetic data: no personal manuscript is required.
export function largeManuscript() {
  const paragraph =
    '测试读者沿着河岸阅读文档。这里包含中文、Unicode 👩🏽‍💻 与 **格式文本**，用于检验全文搜索和编辑同步。\n\n'
  return (
    '# 合成长文档\n\n' +
    Array.from({ length: 30 }, (_, i) => `## 第 ${i + 1} 章\n\n` + paragraph.repeat(65)).join('')
  )
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.argv[2]) throw new Error('Usage: node Fixtures/large-manuscript.mjs OUTPUT')
  await writeFile(process.argv[2], largeManuscript())
}
