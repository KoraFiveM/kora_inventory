import React from "react"
import ReactDOM from "react-dom/client"
import App from "./App"
import "./styles.css"
import "./lib/fft"

const scaleNui = () => {
    const root = document.getElementById("root")!
    const scale = Math.min(2, Math.max(0.5, Math.min(window.innerWidth / 1920, window.innerHeight / 1080)))
    root.style.width = `${window.innerWidth / scale}px`
    root.style.height = `${window.innerHeight / scale}px`
    root.style.transform = `scale(${scale})`
    root.style.transformOrigin = "top left"
}

scaleNui()
window.addEventListener("resize", scaleNui)

ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode><App /></React.StrictMode>,
)
