import { useEffect, useRef, useState } from "react"
import { parseSplitAmount } from "./lib/split"

interface SplitDialogProps {
    label: string
    stack: number
    onConfirm: (amount: number) => void
    onCancel: () => void
}

/** In-page replacement for window.prompt, which blocks and freezes the CEF NUI. */
export function SplitDialog({ label, stack, onConfirm, onCancel }: SplitDialogProps) {
    const [value, setValue] = useState(String(Math.floor(stack / 2)))
    const [error, setError] = useState<string>()
    const input = useRef<HTMLInputElement>(null)
    useEffect(() => { input.current?.focus(); input.current?.select() }, [])

    const submit = () => {
        const parsed = parseSplitAmount(value, stack)
        if ("error" in parsed) { setError(parsed.error); return }
        onConfirm(parsed.amount)
    }

    return <div className="split-backdrop" data-testid="split-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }} onContextMenu={(event) => { event.preventDefault(); onCancel() }}>
        <form className="split-dialog" role="dialog" aria-modal="true" aria-label={`Split ${label}`} onSubmit={(event) => { event.preventDefault(); submit() }}
            onKeyDown={(event) => { if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onCancel() } }}>
            <h3>Split {label}</h3>
            <label>Move how many? (1–{Math.floor(stack) - 1})
                <input ref={input} type="number" inputMode="numeric" min={1} max={Math.floor(stack) - 1} value={value} onChange={(event) => { setValue(event.target.value); setError(undefined) }} />
            </label>
            {error && <p className="split-error" role="alert">{error}</p>}
            <div className="split-actions">
                <button type="button" className="quiet-action" onClick={onCancel}>Cancel</button>
                <button type="submit" className="quiet-action split-confirm">Split</button>
            </div>
        </form>
    </div>
}
