import { useContext, useEffect, useState } from "react"
import { useDragLayer } from "react-dnd"
import { Lightbulb } from "lucide-react"
import { UiConfigContext } from "@/context"
import { useLocale } from "@/lib/locales"
import { availableTips, chooseTip, dismissTips, loadTipsState, markSeen, registerOpening, saveTipsState, tipsActive, tipsContext, type TipId } from "@/lib/tips"

/**
 * A small dismissible tip at the bottom of the window for players who are new
 * to the inventory. Shown on at most `ui.tips.maxShows` openings, cycling
 * through tips for features that are enabled; "Got it" hides it for good.
 * Progress lives in the player's own localStorage. It never shows mid-drag.
 */
// One opening is counted per session even when the layout (and so this card)
// is remounted mid-session, and the tip on screen survives that remount.
let current: { sessionId: string; tip: TipId | undefined } | undefined

export function TipCard({ sessionId, quickSlotsEnabled }: { sessionId: string; quickSlotsEnabled: boolean }) {
    const t = useLocale()
    const config = useContext(UiConfigContext)
    const dragging = useDragLayer((monitor) => monitor.isDragging())
    const [tip, setTipState] = useState<TipId | undefined>(current?.sessionId === sessionId ? current.tip : undefined)
    const available = availableTips(tipsContext(config, quickSlotsEnabled))
    const availableKey = available.join(",")
    const setTip = (next: TipId | undefined) => {
        current = { sessionId, tip: next }
        setTipState(next)
    }

    useEffect(() => {
        if (current?.sessionId === sessionId) return
        current = { sessionId, tip: undefined }
        setTipState(undefined)
        if (!config.tips.enabled) return
        let state = registerOpening(loadTipsState())
        if (tipsActive(config.tips, state)) {
            const first = chooseTip(available, state.seen)
            if (first) state = markSeen(state, first)
            setTip(first)
        }
        saveTipsState(state)
        // `available` and the tips config are read as they are when the window opens.
    }, [sessionId])

    // A tip for a feature that has since been switched off is not kept on screen.
    useEffect(() => {
        if (tip && !available.includes(tip)) setTip(chooseTip(available, loadTipsState().seen))
    }, [availableKey])

    const visibleTip = tip && available.includes(tip) ? tip : undefined
    if (!visibleTip || !config.tips.enabled || dragging) return null

    const next = () => {
        const state = loadTipsState()
        const following = chooseTip(available, state.seen, visibleTip)
        saveTipsState(following ? markSeen(state, following) : state)
        setTip(following)
    }
    const dismiss = () => {
        saveTipsState(dismissTips(loadTipsState()))
        setTip(undefined)
    }

    return <aside className="tip-card" role="note" aria-label={t("ui.tips_title")}>
        <Lightbulb size={16} aria-hidden="true" />
        <p><strong>{t("ui.tips_title")}</strong> {t(`ui.tip_${visibleTip}`)}</p>
        <div className="tip-actions">
            {available.length > 1 && <button type="button" className="tip-button" onClick={next}>{t("ui.tip_next")}</button>}
            <button type="button" className="tip-button tip-button-primary" onClick={dismiss}>{t("ui.tip_got_it")}</button>
        </div>
    </aside>
}
