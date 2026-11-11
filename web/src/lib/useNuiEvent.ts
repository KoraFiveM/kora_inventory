import { useEffect, useRef } from "react"
import type { NuiWireMessage } from "./types"

export function useNuiEvent<T>(action: string, handler: (payload: T) => void) {
    const latest = useRef(handler)
    latest.current = handler

    useEffect(() => {
        const listener = (event: MessageEvent<NuiWireMessage<T>>) => {
            if (event.data?.action === action) latest.current(event.data.data)
        }
        window.addEventListener("message", listener)
        return () => window.removeEventListener("message", listener)
    }, [action])
}
