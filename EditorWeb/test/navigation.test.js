import assert from 'node:assert/strict'
import test from 'node:test'
import { runtime } from '../src/bridge/engineBridge.js'
import { registerSourceView } from '../src/search/searchPresentation.js'

test('fallback heading navigation uses the CodeMirror adapter, not a textarea API', async () => {
  globalThis.window = { addEventListener() {} }
  globalThis.document = { querySelector: () => ({ tagName: 'DIV' }) }
  const { navigate } = await import('../src/editor/scrolling.js')
  let selected
  const unregister = registerSourceView('fallback', {
    highlight() {},
    navigate(offset) {
      selected = offset
    },
  })
  try {
    Object.assign(runtime, {
      fallback: true,
      source: '# A\n\n## B',
      outline: [{ id: 'b', offset: 5 }],
    })
    navigate('b')
    assert.equal(selected, 5)
    assert.equal(runtime.source, '# A\n\n## B')
  } finally {
    unregister()
  }
})
