import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// assetsInlineLimit: 0 -> never inline assets (README: strict CSP, no inline content)
export default defineConfig({
  plugins: [vue()],
  build: { assetsInlineLimit: 0 }
})
