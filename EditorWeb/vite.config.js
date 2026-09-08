import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    target: 'safari18',
    assetsInlineLimit: 0,
    rollupOptions: { output: { inlineDynamicImports: true } },
    chunkSizeWarningLimit: 3500,
  },
})
