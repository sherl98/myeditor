export const sourceViews = new Map()
const revealers = new Map()
let revealGeneration = 0
export function cancelSourceReveal() {
  revealGeneration++
}
export let sourceMatches = new Map()
export let activeSourceMatch = null

export function registerSourceView(key, adapter) {
  sourceViews.set(key, adapter)
  adapter.highlight(
    sourceMatches.get(key) || [],
    activeSourceMatch?.key === key ? activeSourceMatch : null,
  )
  return () => {
    if (sourceViews.get(key) === adapter) sourceViews.delete(key)
  }
}

export function registerSourceRevealer(key, reveal) {
  revealers.set(key, reveal)
  if (activeSourceMatch?.key === key) reveal()
  return () => {
    if (revealers.get(key) === reveal) revealers.delete(key)
  }
}

export function showSourceMatches(matches, active) {
  sourceMatches = matches
  activeSourceMatch = active
  for (const [key, adapter] of sourceViews)
    adapter.highlight(matches.get(key) || [], active?.key === key ? active : null)
  if (active) revealers.get(active.key)?.()
}

export function revealSourceMatch(key, match) {
  revealers.get(key)?.()
  const generation = ++revealGeneration
  requestAnimationFrame(() => {
    if (generation === revealGeneration) sourceViews.get(key)?.reveal(match)
  })
}
