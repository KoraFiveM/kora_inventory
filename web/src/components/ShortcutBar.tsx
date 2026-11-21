import { useLocale } from "@/lib/locales"

/**
 * What used to be a row of keyboard hint chips is now GTA's native controls
 * overlay (the keyboard button in the TopBar). This slot is kept for the
 * layouts and only draws a subtle status while a move waits for the server;
 * otherwise it renders nothing, so no empty footer is left behind.
 */
export function ShortcutBar({ movePending }: { movePending: boolean }) {
    const t = useLocale()
    if (!movePending) return null
    return <footer className="shortcut-bar" role="status">{t("ui.updating_inventory")}</footer>
}
