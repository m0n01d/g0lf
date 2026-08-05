import { defineConfig } from "vite"

// GitHub Pages serves this project from https://m0n01d.github.io/g0lf/, so every
// emitted asset URL needs the repo name as a prefix. Locally `vite dev` ignores
// `base`, so this is safe to leave on.
export default defineConfig({
  base: process.env.VITE_BASE ?? "/g0lf/",
  build: { outDir: "dist", emptyOutDir: true },
})
