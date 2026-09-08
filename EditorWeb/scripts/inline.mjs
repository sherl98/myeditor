import { readFile, writeFile, unlink } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createHash } from 'node:crypto'

// A self-contained page can be loaded from memory without granting WebKit
// filesystem access to the app bundle or weakening its script CSP.
const index = resolve('dist/index.html')
let html = await readFile(index, 'utf8')
const script = html.match(/<script\b[^>]*src="([^"]+)"[^>]*><\/script>/)
const stylesheet = html.match(/<link\b[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/)
if (!script || !stylesheet) throw new Error('Expected one bundled script and stylesheet')
const scriptPath = resolve('dist', script[1])
const stylePath = resolve('dist', stylesheet[1])
const code = (await readFile(scriptPath, 'utf8')).replace(/<\/script/gi, '<\\/script')
const css = (await readFile(stylePath, 'utf8')).replace(/<\/style/gi, '<\\/style')
const hash = createHash('sha256').update(code).digest('base64')
html = html
  .replace(script[0], () => `<script type="module">${code}</script>`)
  .replace(stylesheet[0], () => `<style>${css}</style>`)
  .replace("script-src 'self'", `script-src 'sha256-${hash}'`)
await writeFile(index, html)
await unlink(scriptPath)
await unlink(stylePath)
console.log('Bundled local editor into one HTML resource with a script CSP hash.')
