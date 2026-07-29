import { useStore } from '../store'
import { MoonIcon, SunIcon } from './Icons'

export function ThemeToggle() {
  const theme = useStore((s) => s.theme)
  const toggleTheme = useStore((s) => s.toggleTheme)
  const isDark = theme === 'dark'

  return (
    <button
      type="button"
      className="icon-btn theme-toggle"
      onClick={toggleTheme}
      aria-label={isDark ? 'Switch to light theme' : 'Switch to dark theme'}
      title={isDark ? 'Light mode' : 'Dark mode'}
    >
      <span className={`theme-toggle__glyph ${isDark ? 'is-dark' : 'is-light'}`}>
        <SunIcon className="theme-toggle__sun" size={19} />
        <MoonIcon className="theme-toggle__moon" size={18} />
      </span>
    </button>
  )
}
