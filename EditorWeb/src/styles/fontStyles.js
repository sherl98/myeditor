const CONTENT_FALLBACK = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'
const CODE_FALLBACK = '"SFMono-Regular", Menlo, Monaco, monospace'

const fallbackFace = (role) =>
  role === 'code'
    ? { family: 'ui-monospace', weight: 400, style: 'normal', isGeneric: true }
    : { family: 'system-ui', weight: 400, style: 'normal', isGeneric: true }

function normalizeFamily(value, role) {
  const fallback = fallbackFace(role)
  if (!value || typeof value !== 'object') return fallback
  const family = typeof value.family === 'string' ? value.family.trim() : ''
  const allowedGeneric = role === 'code' ? family === 'ui-monospace' : family === 'system-ui'
  const validCustom =
    family.length > 0 && family.length <= 256 && !/[\u0000-\u001f\u007f]/.test(family)
  if ((value.isGeneric && !allowedGeneric) || (!value.isGeneric && !validCustom)) return fallback
  const numericWeight = Number(value.weight)
  const weight = Number.isFinite(numericWeight)
    ? Math.min(900, Math.max(100, Math.round(numericWeight / 100) * 100))
    : 400
  return {
    family,
    weight,
    style: value.style === 'italic' ? 'italic' : 'normal',
    isGeneric: !!value.isGeneric,
  }
}

function familyStack(face, role) {
  const fallback = role === 'code' ? CODE_FALLBACK : CONTENT_FALLBACK
  return face.isGeneric
    ? `${face.family}, ${fallback}`
    : `${JSON.stringify(face.family)}, ${fallback}`
}

export function editorFontStyles(options = {}) {
  const content = normalizeFamily(options.contentFontFace, 'content')
  const code = normalizeFamily(options.codeFontFace, 'code')
  return {
    content: {
      family: familyStack(content, 'content'),
      weight: String(content.weight),
      style: content.style,
      signature: JSON.stringify(content),
    },
    code: {
      family: familyStack(code, 'code'),
      weight: String(code.weight),
      style: code.style,
      signature: JSON.stringify(code),
    },
  }
}

export function applyEditorFonts(root, options) {
  const fonts = editorFontStyles(options)
  const variables = {
    '--content-font-family': fonts.content.family,
    '--content-font-weight': fonts.content.weight,
    '--content-font-style': fonts.content.style,
    '--code-font-family': fonts.code.family,
    '--code-font-weight': fonts.code.weight,
    '--code-font-style': fonts.code.style,
  }
  for (const [name, value] of Object.entries(variables)) {
    if (root.style.getPropertyValue(name) !== value) root.style.setProperty(name, value)
  }
  if (root.dataset.contentFontSignature !== fonts.content.signature) {
    root.dataset.contentFontSignature = fonts.content.signature
  }
  return fonts
}

export function readContentFontStyle(root = document.documentElement) {
  const computed = getComputedStyle(root)
  return {
    family:
      computed.getPropertyValue('--content-font-family').trim() || `system-ui, ${CONTENT_FALLBACK}`,
    weight: computed.getPropertyValue('--content-font-weight').trim() || '400',
    style: computed.getPropertyValue('--content-font-style').trim() || 'normal',
    signature: root.dataset.contentFontSignature || JSON.stringify(fallbackFace('content')),
  }
}
