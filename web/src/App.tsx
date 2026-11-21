import { SplitDialog } from "./SplitDialog"
import { DndProvider } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { UiConfigContext } from "@/context"
import { openDevHarness } from "@/lib/dev"
import { useLocale } from "@/lib/locales"
import { DragGuard } from "@/components/DragGuard"
import { DragPreview } from "@/components/DragPreview"
import { HotbarHud } from "@/components/HotbarHud"
import { Inspector } from "@/components/Inspector"
import { InventoryPanel } from "@/components/InventoryPanel"
import { ItemBoxStack } from "@/components/ItemBoxStack"
import { QuickSlotBar } from "@/components/QuickSlotBar"
import { ShortcutBar } from "@/components/ShortcutBar"
import { TopBar } from "@/components/TopBar"
import { WorldDropZone } from "@/components/WorldDropZone"
import { useInventorySession } from "@/hooks/useInventorySession"
import { useShellLayout } from "@/hooks/useShellLayout"
import { LAYOUTS, resolveLayout } from "@/layouts"
import type { LayoutProps } from "@/layouts/types"
import { PackageOpen } from "lucide-react"

// One stable reference: an inline arrow is a new useDrag dependency every render.
const noop = () => undefined

function InventoryApp() {
    const t = useLocale()
    const s = useInventorySession()
    const { session, uiConfig } = s
    const shell = useShellLayout({ hasSession: Boolean(session), transferView: Boolean(session?.secondary) })

    if (!session) return <UiConfigContext.Provider value={uiConfig}><DragGuard open={false} />{s.hotbar && <HotbarHud hotbar={s.hotbar} />}<ItemBoxStack boxes={s.itemBoxes} />{import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null}</UiConfigContext.Provider>

    const { solo, selected, inspected, locked } = s
    const layoutId = resolveLayout(uiConfig, shell.playerLayout)
    const Layout = LAYOUTS[layoutId]

    const panelHandlers = { selected, busy: locked, canDropSlot: s.canDropSlot, onDrop: s.dropSlot, onDragEnd: noop, onSelect: s.selectSlot, onActivate: s.activateItem, onSplit: s.promptSplit }
    const buildInspector = (drawer: boolean) => <Inspector
            inspected={inspected}
            selected={selected}
            solo={drawer}
            playerId={session.player.id}
            movePending={s.movePending}
            giveAvailable={s.giveAvailable}
            inspectorCopy={uiConfig.inspectorCopy}
            inspectorDecimals={uiConfig.inspectorDecimals}
            copyState={s.copyState}
            selectedMax={s.selectedMax}
            selectedCount={s.selectedCount}
            onAmountChange={s.setSelectedAmount}
            onCopy={s.copySelected}
            onCloseDrawer={s.clearSelection}
            onBuy={s.buy}
            onUse={s.use}
            onSplitSelected={s.split}
            onSubmit={(intent, payload) => s.submit(intent, payload)}
        />
    const layoutProps: LayoutProps = {
        layoutId,
        session,
        inspected,
        solo,
        transferView: Boolean(session.secondary),
        playerLayout: shell.playerLayout,
        drawerLeft: shell.offsetPx.x > 0,
        movePending: s.movePending,
        uiConfig,
        shellRef: shell.shellRef,
        shellStyle: shell.shellStyle,
        ...panelHandlers,
        onClose: s.close,
        onClearSelection: s.clearSelection,
        dragPreview: <DragPreview session={session} />,
        topbar: <TopBar transfer={Boolean(session.secondary)} query={s.query} onQueryChange={s.setQuery} error={s.error} onClose={s.close} />,
        playerPanel: <InventoryPanel inventory={session.player} isPlayer {...panelHandlers} />,
        // Solo layout starts as the player's inventory alone. Its inspector is a
        // drawer, mounted only after selection, so an idle personal inventory does
        // not reserve a permanently empty actions column.
        inspector: (!solo || selected) ? buildInspector(solo) : null,
        // The drawer-styled inspector (with its close button) whatever the view,
        // mounted only once something is selected: for layouts that float it.
        drawerInspector: selected ? buildInspector(true) : null,
        secondaryPanel: session.secondary
            ? <InventoryPanel inventory={session.secondary} {...panelHandlers} />
            : solo ? null : <section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>{t("ui.no_secondary_inventory")}</h2><p>{t("ui.open_secondary_inventory")}</p></section>,
        shortcutBar: <ShortcutBar movePending={s.movePending} revision={session.revision} />,
        renderQuickSlots: (position) => <QuickSlotBar position={position} />,
    }

    return <UiConfigContext.Provider value={uiConfig}><ItemBoxStack boxes={s.itemBoxes} /><DragGuard open /><WorldDropZone session={session} busy={locked} onDropOut={s.dropOut} />{s.splitTarget && <SplitDialog label={s.splitTarget.item.label ?? s.splitTarget.item.name} stack={s.splitTarget.item.amount} onConfirm={s.confirmSplit} onCancel={s.cancelSplit} />}<Layout {...layoutProps} /></UiConfigContext.Provider>
}

export default function App() {
    return <DndProvider backend={TouchBackend} options={{ enableMouseEvents: true }}><InventoryApp /></DndProvider>
}
