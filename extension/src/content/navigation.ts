// ─────────────────────────────────────────────────────────────────────────────
// Leaving the page without unloading it.
//
// A single-page app moves to the next article with history.pushState, which
// fires neither `popstate` nor `hashchange` — so a reader that only watched
// those kept narrating the old article over the new page. The Navigation API
// (Chrome 102+, and our floor is 114) reports every same-document move as a
// `currententrychange`, pushState included.
// ─────────────────────────────────────────────────────────────────────────────

/** The slice of `window` this needs, so a test can hand in a stand-in. */
export interface NavigationHost extends EventTarget {
  location: { pathname: string; search: string }
  navigation?: EventTarget
}

/**
 * Call `onLeave` whenever the document's address (path + query) changes without
 * an unload: back/forward, a hash route, or an app's own pushState. A
 * replaceState is not a move — sites use it to tidy the address of the page you
 * are already on (tracking parameters, scroll position) — so it only updates
 * the address later moves are compared against.
 */
export function watchNavigation(host: NavigationHost, onLeave: () => void): void {
  const here = () => host.location.pathname + host.location.search
  let last = here()
  const check = () => {
    const now = here()
    if (now === last) return
    last = now
    onLeave()
  }
  host.addEventListener('popstate', check)
  host.addEventListener('hashchange', check)
  host.navigation?.addEventListener('currententrychange', (e) => {
    if ((e as Event & { navigationType?: string | null }).navigationType === 'replace') {
      last = here()
      return
    }
    check()
  })
}
