import { sourceViews } from '../search/searchPresentation.js'
import { runtime, post } from '../bridge/engineBridge.js'

let frame = 0
let start = 0
let target = 0
let startedAt = 0
let activeHeading = null
let scrollFrame = 0
let headingElements = []

export function cancelWheel() {
  if (frame) cancelAnimationFrame(frame)
  frame = 0
}
export function addWheelDelta(delta) {
  if (!runtime.readOnly || matchMedia('(prefers-reduced-motion: reduce)').matches) {
    window.scrollBy(0, delta)
    return
  }
  const current = window.scrollY
  const remaining = frame ? target - current : 0
  const sameDirection = Math.sign(remaining) === Math.sign(delta)
  target = Math.max(
    0,
    Math.min(
      document.documentElement.scrollHeight - innerHeight,
      current + delta + (sameDirection ? remaining : 0),
    ),
  )
  start = current
  startedAt = performance.now()
  cancelWheel()
  function advance(time) {
    const t = Math.min(1, (time - startedAt) / 180)
    window.scrollTo(0, start + (target - start) * (1 - (1 - t) ** 3))
    frame = t < 1 ? requestAnimationFrame(advance) : 0
  }
  frame = requestAnimationFrame(advance)
}

export function refreshHeadingElements() {
  headingElements = [
    ...document.querySelectorAll(
      '.document-content h1, .document-content h2, .document-content h3, .document-content h4, .document-content h5, .document-content h6',
    ),
  ]
  activeHeading = null
  observeScroll()
}

function observeScroll() {
  if (scrollFrame) return
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0
    if (!runtime.loaded || runtime.fallback || runtime.showsSource || !headingElements.length)
      return
    let index = 0
    for (let i = 0; i < headingElements.length; i++) {
      if (headingElements[i].getBoundingClientRect().top <= 110) index = i
      else break
    }
    const id = runtime.outline[index]?.id
    if (id && id !== activeHeading) {
      activeHeading = id
      post('activeHeading', { id })
    }
  })
}

export function navigate(id) {
  cancelWheel()
  const index = runtime.outline.findIndex((item) => item.id === id)
  if (index < 0) return
  if (runtime.fallback || runtime.showsSource) {
    const view = sourceViews.get(runtime.fallback ? 'fallback' : 'source-preview')
    if (!view) return
    view.navigate(runtime.outline[index].offset)
  } else {
    refreshHeadingElements()
    const element = headingElements[index]
    if (!element) return
    element.scrollIntoView({ block: 'start', behavior: 'instant' })
    if (!runtime.readOnly) {
      const range = document.createRange()
      range.selectNodeContents(element)
      range.collapse(true)
      const selection = getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
      document.querySelector('.document-content')?.focus({ preventScroll: true })
    }
  }
  activeHeading = id
  post('activeHeading', { id })
}

window.addEventListener('scroll', observeScroll, { passive: true })
window.addEventListener(
  'resize',
  () => {
    cancelWheel()
    observeScroll()
  },
  { passive: true },
)
window.addEventListener('pointerdown', cancelWheel, { passive: true })
window.addEventListener('keydown', cancelWheel)
