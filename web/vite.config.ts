import path from "path"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"
import qbtheme from "../../qbtheme/vite-plugin.mjs"

export default defineConfig({
    plugins: [qbtheme(), react()],
    base: "./",
    build: { outDir: "build" },
    resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
})
