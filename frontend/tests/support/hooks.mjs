// Lets `node --test` load the app's own TypeScript modules the way Vite does:
// extensionless relative imports resolve to .ts/.tsx, and `import.meta.env`
// (a Vite-only object) reads as empty, so api.ts falls back to its defaults.
// Tests import this first, then load app modules with a dynamic import().
import { registerHooks } from 'node:module'

const RELATIVE = /^\.\.?\//
const HAS_EXT = /\.[cm]?[jt]sx?$/

registerHooks({
  resolve(specifier, context, next) {
    try {
      return next(specifier, context)
    } catch (err) {
      if (!RELATIVE.test(specifier) || HAS_EXT.test(specifier)) throw err
      for (const ext of ['.ts', '.tsx']) {
        try {
          return next(specifier + ext, context)
        } catch {
          /* try the next extension */
        }
      }
      throw err
    }
  },
  load(url, context, next) {
    const result = next(url, context)
    if (url.includes('/src/') && url.endsWith('.ts') && result.source != null) {
      const source = String(result.source).replaceAll('import.meta.env', '({})')
      return { ...result, source }
    }
    return result
  },
})
