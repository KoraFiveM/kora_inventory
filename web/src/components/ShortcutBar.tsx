import { useLocale } from "@/lib/locales"

export function ShortcutBar({ movePending, revision }: { movePending: boolean; revision?: number }) {
    const t = useLocale()
    return <footer className="shortcut-bar"><span><kbd>Esc</kbd> {t("ui.close")}</span><span><kbd>↵</kbd> {t("ui.use_selected")}</span><span><kbd>Drag</kbd> {t("ui.move_or_stack")}</span><span><kbd>Drag out</kbd> {t("ui.drop")}</span><span>{movePending ? t("ui.updating_inventory") : t("ui.revision", { revision: revision ?? 0 })}</span></footer>
}
