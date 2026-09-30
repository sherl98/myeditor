import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// MDXEditor serializes the whole document after every keystroke. The editor
// exports changed blocks itself (src/editor/documentSync.js), so the built-in
// export is skipped while that flag is set. Fail the build if the pinned
// version no longer contains the exact code this depends on.
function deferMarkdownExport() {
  const target = '@mdxeditor/editor/dist/plugins/core/index.js'
  const replacements = [
    [
      'theNewMarkdownValue = exportMarkdownFromLexical({',
      'if (globalThis.__myEditorSkipMarkdownExport) return;\n          theNewMarkdownValue = exportMarkdownFromLexical({',
    ],
    [
      'r.pub(markdown$, theNewMarkdownValue.trim());',
      'if (theNewMarkdownValue !== void 0) r.pub(markdown$, theNewMarkdownValue.trim());',
    ],
  ]
  return {
    name: 'myeditor-defer-markdown-export',
    enforce: 'pre',
    transform(code, id) {
      if (!id.replaceAll('\\', '/').endsWith(target)) return null
      let patched = code
      for (const [search, replacement] of replacements) {
        if (patched.split(search).length !== 2)
          throw new Error(`MDXEditor export patch no longer matches: ${search}`)
        patched = patched.replace(search, replacement)
      }
      return { code: patched, map: null }
    },
  }
}

export default defineConfig({
  base: './',
  plugins: [deferMarkdownExport(), react()],
  build: {
    target: 'safari18',
    assetsInlineLimit: 0,
    // The page is served from the app bundle (EditorResourceHandler), so
    // dynamic imports such as Mermaid stay separate and load on demand.
    modulePreload: { polyfill: false },
    chunkSizeWarningLimit: 1500,
  },
})
