import { defineConfig } from "vite"
import { VitePWA } from "vite-plugin-pwa"

// GitHub Pages serves this project from https://m0n01d.github.io/g0lf/, so every
// emitted asset URL needs the repo name as a prefix. Locally `vite dev` ignores
// `base`, so this is safe to leave on. The service worker inherits it, which is
// what keeps its scope at /g0lf/ rather than the domain root.
const base = process.env.VITE_BASE ?? "/g0lf/"

export default defineConfig({
  base,
  build: { outDir: "dist", emptyOutDir: true },
  plugins: [
    VitePWA({
      // The game makes no network calls at runtime, so precaching the build is
      // the whole of offline support.
      registerType: "autoUpdate",
      injectRegister: "auto",
      // No includeAssets: everything in public/ is already copied into dist and
      // picked up by globPatterns below. Listing it twice puts duplicate URLs in
      // the precache manifest, which Workbox rejects at install time.
      manifest: {
        id: base,
        name: "g0lf",
        short_name: "g0lf",
        description: "A cozy infinite golf game animated entirely by CSS.",
        start_url: base,
        scope: base,
        display: "standalone",
        background_color: "#1b1430",
        theme_color: "#1b1430",
        icons: [
          { src: "pwa-192.png", sizes: "192x192", type: "image/png" },
          { src: "pwa-512.png", sizes: "512x512", type: "image/png" },
          { src: "maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        // The plugin injects the manifest and its three icons into the precache
        // list itself, so globbing them again produces duplicate URLs. This
        // covers exactly what the plugin does not.
        globPatterns: ["index.html", "registerSW.js", "assets/**/*.{js,css}", "apple-touch-icon.png"],
        // Without this an old build's precache lingers and can be served after
        // an update — the "I deployed and nothing changed" failure.
        cleanupOutdatedCaches: true,
        clientsClaim: true,
        skipWaiting: true,
      },
    }),
  ],
})
