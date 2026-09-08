import { build } from '../../EditorWeb/node_modules/vite/dist/node/index.js'
import { writeFile, mkdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const root = fileURLToPath(new URL('../../EditorWeb', import.meta.url))
const variants = {}
for (const stub of [false, true]) {
  const result = await build({
    root,
    logLevel: 'silent',
    build: { write: false },
    plugins: stub
      ? [
          {
            name: 'audit-mermaid-stub',
            enforce: 'pre',
            resolveId(id) {
              if (id === 'mermaid') return '\0audit-mermaid-stub'
            },
            load(id) {
              if (id === '\0audit-mermaid-stub')
                return 'export default { initialize(){}, async render(){ return {svg:""} } }'
            },
          },
        ]
      : [],
  })
  variants[stub ? 'mermaidStub' : 'full'] = result.output.map((item) => ({
    fileName: item.fileName,
    bytes: Buffer.byteLength(item.type === 'chunk' ? item.code : item.source),
    modules: item.type === 'chunk' ? Object.keys(item.modules).length : undefined,
  }))
}
const jsBytes = (items) =>
  items.filter((i) => i.fileName.endsWith('.js')).reduce((n, i) => n + i.bytes, 0)
variants.javaScriptDifferenceBytes = jsBytes(variants.full) - jsBytes(variants.mermaidStub)
variants.note =
  'Controlled Vite write:false build of current source; stub removes functionality, not an optimization to ship.'
const output = new URL('../../.cache/validation/bundle-audit-' + Date.now() + '/', import.meta.url)
await mkdir(output, { recursive: true })
await writeFile(new URL('bundle-evidence.json', output), JSON.stringify(variants, null, 2) + '\n')
console.log(JSON.stringify(variants, null, 2))
