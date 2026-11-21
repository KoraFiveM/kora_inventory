import { useContext } from "react"
import { UiConfigContext } from "@/context"
import { useLocale } from "@/lib/locales"

export function ShortcutBar({ movePending, revision }: { movePending: boolean; revision?: number }) {
    const t = useLocale()
    const { quickTransfer, modifierDrag } = useContext(UiConfigContext)
    return <footer className="shortcut-bar"><span><kbd>Esc</kbd> {t("ui.close")}</span><span><kbd>↵</kbd> {t("ui.use_selected")}</span><span><kbd>Drag</kbd> {t("ui.move_or_stack")}</span>{quickTransfer && <span><kbd>Shift+Click</kbd> {t("ui.quick_transfer")}</span>}{modifierDrag && <span><kbd>Ctrl+Drag</kbd> {t("ui.move_half")} <kbd>Alt+Drag</kbd> {t("ui.move_one")}</span>}<span><kbd>Drag out</kbd> {t("ui.drop")}</span><span>{movePending ? t("ui.updating_inventory") : t("ui.revision", { revision: revision ?? 0 })}</span></footer>
}
