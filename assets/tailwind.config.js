// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
module.exports = {
  // dark: utilities key off the same [data-theme] attribute the rest of
  // the theme uses — never the OS preference, which would disagree with
  // an explicit Light/Dark choice in Settings.
  darkMode: ['class', '[data-theme="dark"]'],
  content: [
    './js/**/*.js',
    '../lib/**/*.ex',
    '../lib/**/*.heex'
  ],
  theme: {
    extend: {
      // Semantic colour tokens, bound to CSS custom properties so a single
      // [data-theme="light"] override on <html> repaints the whole app.
      colors: {
        app: 'var(--bg-app)',
        panel: 'var(--bg-panel)',
        raised: 'var(--bg-raised)',
        input: 'var(--bg-input)',
        active: 'var(--bg-active)',
        edge: 'var(--border)',
        'edge-soft': 'var(--border-soft)',
        focus: 'var(--border-focus)',
        ink: 'var(--text)',
        paper: 'var(--text-strong)',
        muted: 'var(--text-muted)',
        sub: 'var(--text-sub)',
        dim: 'var(--text-dim)',
        faint: 'var(--text-faint)',
        dot: 'var(--dot-idle)',
        'dot-ok': 'var(--dot-ok)',
        'dot-info': 'var(--dot-info)',
        'dot-bad': 'var(--dot-bad)',
        accent: 'var(--accent)',
        ok: 'var(--ok-text)',
        info: 'var(--info-text)',
        warn: 'var(--warn-text)',
        bad: 'var(--bad-text)'
      },
      fontFamily: {
        // System-native sans. Kept local so the UI can use the platform's
        // typeface without a webfont dependency, which also guarantees the
        // many unicode glyphs this interface uses (⤶ ⤷ ⛒ ✎ ⌘ ⇆ ...) resolve.
        sans: [
          'ui-sans-serif',
          'system-ui',
          '-apple-system',
          'BlinkMacSystemFont',
          '"Segoe UI"',
          'Roboto',
          '"Helvetica Neue"',
          'Arial',
          '"Noto Sans"',
          'sans-serif',
          '"Apple Color Emoji"',
          '"Segoe UI Emoji"',
          '"Segoe UI Symbol"',
          '"Noto Color Emoji"'
        ],
        // System-native mono for identifiers, statuses and code.
        mono: [
          'ui-monospace',
          'SFMono-Regular',
          'Menlo',
          'Monaco',
          'Consolas',
          '"Liberation Mono"',
          '"Courier New"',
          'monospace'
        ]
      }
    },
  },
  plugins: [
    require('@tailwindcss/forms')
  ]
}