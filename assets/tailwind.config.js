// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
module.exports = {
  content: [
    './js/**/*.js',
    '../lib/**/*.ex'
  ],
  theme: {
    extend: {
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