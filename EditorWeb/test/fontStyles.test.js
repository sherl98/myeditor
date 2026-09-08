import test from 'node:test'
import assert from 'node:assert/strict'
import { applyEditorFonts, editorFontStyles } from '../src/styles/fontStyles.js'

test('font settings preserve current system defaults', () => {
  const fonts = editorFontStyles()
  assert.match(fonts.content.family, /^system-ui, -apple-system/)
  assert.match(fonts.code.family, /^ui-monospace, "SFMono-Regular"/)
  assert.equal(fonts.content.weight, '400')
  assert.equal(fonts.code.style, 'normal')
})

test('installed family names remain quoted and face traits are bounded', () => {
  const fonts = editorFontStyles({
    contentFontFace: {
      family: 'Example"; color: red',
      weight: 742,
      style: 'italic',
      isGeneric: false,
    },
  })
  assert.ok(fonts.content.family.startsWith('"Example\\\"; color: red",'))
  assert.equal(fonts.content.weight, '700')
  assert.equal(fonts.content.style, 'italic')
})

test('unknown generic families and malformed values fall back by role', () => {
  const fonts = editorFontStyles({
    contentFontFace: { family: 'ui-monospace', weight: 900, style: 'italic', isGeneric: true },
    codeFontFace: { family: 'Not\nA Font', weight: 0, style: 'oblique', isGeneric: false },
  })
  assert.match(fonts.content.family, /^system-ui, /)
  assert.match(fonts.code.family, /^ui-monospace, /)
  assert.equal(fonts.content.weight, '400')
  assert.equal(fonts.code.style, 'normal')
})

test('font configuration updates CSS variables without replacing the root', () => {
  const properties = new Map()
  const root = {
    dataset: {},
    style: {
      getPropertyValue: (name) => properties.get(name) || '',
      setProperty: (name, value) => properties.set(name, value),
    },
  }
  const returned = applyEditorFonts(root, {
    contentFontFace: { family: 'Georgia', weight: 700, style: 'italic', isGeneric: false },
    codeFontFace: { family: 'Menlo', weight: 400, style: 'normal', isGeneric: false },
  })
  assert.match(properties.get('--content-font-family'), /^"Georgia", /)
  assert.equal(properties.get('--content-font-weight'), '700')
  assert.match(properties.get('--code-font-family'), /^"Menlo", /)
  assert.equal(root.dataset.contentFontSignature, returned.content.signature)
})
