Config = Config or {}

-- Whether shop counters show a floating world icon. nil (default) follows
-- kora_target's Config.target.sprites.enabled; true forces the icon on and
-- false forces it off for kora_inventory's shop zones. Needs kora_target's
-- sprites.allowPerZoneOverride (default true) for `true` to take effect.
-- Read when the zones are registered (resource or kora_target start).
Config.showTargetHints = nil

-- Prefix of newly generated weapon serials (`KORA-WEAPONPISTOL50-<time>-<n>`).
-- Upper-cased and reduced to A-Z0-9, max 12 characters; empty falls back to
-- KORA. Existing items keep the serial they already have.
Config.SerialPrefix = 'KORA'

-- Item inspector number formatting. Decimals shown for fractional metadata
-- values such as Durability/Quality (0-3); trailing zeros are dropped, so 1
-- shows 92.7 and 100.
-- allowCopy: the inspector's details and metadata can be selected with the
-- mouse, and a Copy button in its header copies the selected item (label,
-- name, amount, slot, inventory, full metadata) as JSON. Text elsewhere in the
-- inventory stays unselectable. false hides the button and keeps it all locked.
Config.Inspector = {
    decimals = 1,
    allowCopy = true,
}

-- Inventory slot border thickness in CSS pixels (1-4), also used for the green
-- hotbar frame around slots 1-5. 1 is the old thin look.
Config.Slots = {
    borderWidth = 2,
}

-- On-screen hotbar (the overlay shown by the show-hotbar key). Distance in CSS
-- pixels from the bottom edge of the screen to the bottom of the hotbar. The
-- defaults sit above kora_hud's status circles and the minimap strip; on foot
-- and seated are separate because the vehicle HUD takes more room. Raise the
-- numbers to move the hotbar up, lower them to move it down. Colours follow
-- kora_theme.
Config.Hotbar = {
    bottomOffset = 90, -- on foot
    vehicleBottomOffset = 130, -- in a vehicle
}

-- Draws a small marker (and optional "[ALT] Shop" text) at fixed shop
-- interaction points (convenience, liquor, Ammu-Nation, ...). Counters served by
-- a ped (a 24/7/liquor clerk or an Ammu-Nation shopkeeper) get no marker unless
-- `markerAtPeds`, so the ped is the only cue there. The text is off by default
-- (`showText`); when on, it is still hidden at counters that have a ped (any
-- shop type) unless Config.ShopClerks.showLabel. Colour follows
-- kora_theme's primary colour. Set `hint = false` on a shop's config to opt that
-- shop out. Vending machines are model targets without fixed points and get no
-- marker. Plain {x,y,z} tables rather than vec3, like the other offsets here.
Config.ShopHints = {
    enabled = true,
    drawDistance = 10.0, -- metres; nothing is drawn or checked per frame beyond this
    alpha = 160, -- 0-255 marker opacity
    marker = {
        type = 20, -- chevron; 2 is an inverted cone, 1 a cylinder
        scale = { x = 0.3, y = 0.3, z = 0.3 },
        zOffset = 0.0, -- added to the point's z
        bob = true,
        rotate = true,
    },
    markerAtPeds = false, -- true also draws the marker at counters served by a ped (clerk or Ammu-Nation shopkeeper)
    showText = false, -- true draws locale key shop_hints.text above the marker at counters without a ped
}

-- Shop clerk peds at the general shops (24/7, liquor): a frozen, invincible
-- clerk stands behind the counter and opens the shop through kora_target.
-- Locations opt in with a `ped` spot ({ x, y, z, heading }, z = floor height);
-- see config/shops/*.lua. Ammu-Nation keeps its own shop.shopkeeper peds (they
-- also hide the floating label, see showLabel).
-- Per shop, `clerk = { model, scenario, radius, enabled }` overrides these
-- (`clerk = false` turns clerks off for that shop); a location can override
-- with `ped.model` / `ped.scenario` or opt out with `clerk = false`.
Config.ShopClerks = {
    enabled = true, -- false = no clerk peds; the old counter zone and label are used
    showLabel = false, -- true keeps the floating "[ALT] Shop" text (needs Config.ShopHints.showText) at counters that have a ped, clerk or Ammu-Nation shopkeeper
    model = 's_m_m_ammucountry', -- default clerk model
    scenario = 'WORLD_HUMAN_CLIPBOARD', -- scenario the clerk plays; '' = stand still
    radius = 40.0, -- metres: the ped spawns when a player comes this close and is deleted when they leave
    interactionDistance = 3.0, -- kora_target distance to the clerk
}

Config.kora_inventory = {
    playerSlots = 41,
    playerMaxWeight = 120000,
    -- Weapons that stack in one slot instead of taking a slot each (no serial
    -- is issued for them). Remove an entry or set it to false to make that
    -- item unique again. Only affects items added after the change.
    stackableWeapons = {
        weapon_grenade = true,
        weapon_molotov = true,
    },
    -- Slots 1..hotbarSlots double as the hotbar. client/hotbar.lua binds the
    -- number keys to exactly this range, and weaponCarry's 'hotbar'
    -- visibility mode treats exactly this range as "openly carried", so the
    -- two can never drift apart into two different meanings of "hotbar".
    --
    -- This is on by default: keys 1..hotbarSlots are bound as the rebindable
    -- keybinds `kora_inventory:hotbar1`..`kora_inventory:hotbarN` (Settings > Key
    -- Bindings > FiveM). There is no always-on bar on the HUD while the
    -- inventory is closed; the only visual is the accent outline on those
    -- slots inside the open panel (ui.showHotbar). 0 disables the key binds.
    hotbarSlots = 5,
    -- Sort and Stack-all buttons on every inventory panel header (player,
    -- stash, trunk, glovebox, container, drop; never shops). Both are server
    -- operations: the `organize` intent is validated exactly like a move
    -- (session, revisions, access, routing bucket, distance), runs under the
    -- inventory lock and never creates, destroys or merges different items.
    -- Read on every request, so changes apply without a restart (the buttons
    -- themselves appear the next time the inventory opens).
    organize = {
        enabled = true,
        -- 'stack': merge stackable stacks of the same item with identical
        -- metadata into the lowest slots (unique items never merge).
        stack = true,
        -- 'sort': stack, then reorder by sortOrder, label, name, original slot.
        sort = true,
        -- Player inventory only: slots 1..hotbarSlots are never moved or
        -- emptied, so hotbar keys and visible weapon carry do not change.
        -- (Their stacks may still grow when the same item is stacked in.)
        keepHotbar = true,
        -- Minimum milliseconds between two organizes by the same player.
        cooldownMs = 1000,
        -- Category order for Sort. Categories: 'weapon', 'ammo', 'useable',
        -- 'other'. A category left out sorts last.
        sortOrder = { 'weapon', 'ammo', 'useable', 'other' },
        -- A small search box in every panel header that dims non-matching
        -- slots in that panel. Browser-only.
        panelSearch = true,
    },
    -- Quick slots are SHORTCUTS, not physical slots. Items stay wherever they
    -- are in the normal inventory; a quick slot is a pointer that resolves to
    -- the real slot of a matching item. It is shown at the side of the
    -- inventory (and optionally in the U-key hotbar) and can have a hotkey
    -- (rebindable keybinds `kora_inventory:quick_<id>`, Settings > Key
    -- Bindings > FiveM). Nothing is stored on the server; pins (see below) are
    -- a per-character preference kept on the player's own machine.
    --
    -- Each slot picks its item in this order: the item the player pinned to it
    -- from the UI, then (weapon slots) the weapon currently drawn, then the
    -- lowest-numbered matching slot. A weapon taken by one weapon quick slot is
    -- not offered again to another one unless it was pinned there.
    quickSlots = {
        -- false registers no keys or callbacks and the UI shows no quick slots.
        enabled = true,
        -- true hides quick slots that resolve to nothing; false shows a greyed
        -- placeholder for them.
        hideWhenMissing = true,
        -- Show the bound key on each quick slot in the UI.
        showKeyHints = true,
        -- The quick slots are drawn in a drawer on the side of the inventory
        -- window (classic, compact and dock layouts). startCollapsed = true
        -- opens it as a slim strip; once the player toggles the handle, their
        -- choice is remembered on their own machine and wins over this.
        drawer = { startCollapsed = false },
        -- Include resolved quick slots in the U-key on-screen hotbar.
        inHotbarHud = true,
        -- Informational: ammunition is always loaded through the normal ammo
        -- use path, so it is validated by the server against the drawn weapon.
        reloadFromPockets = true,
        -- id:       letters, digits and underscores; the command is
        --           `kora_inventory:quick_<id>`.
        -- label:    shown in the UI and in the key bindings list.
        -- accepts:  which items fit. `names` (any of), `type` (item definition
        --           type, e.g. 'weapon') and `weapontype` (kora_core weapon
        --           definition weapontype, e.g. 'Pistol'); all given criteria
        --           must match. Names are not case sensitive.
        -- linkedTo: the id of another slot. This slot then shows the ammunition
        --           item whose `ammoType` matches the `ammotype` of the weapon
        --           resolved for that slot, with the total across all slots.
        --           Linked slots cannot be pinned.
        -- key:      default key, '' = unbound. Phone/radio resources and GTA's
        --           own R reload would clash, so nothing is bound by default.
        slots = {
            { id = 'weapon', label = 'Weapon', accepts = { type = 'weapon' }, key = '' },
            { id = 'ammo',   label = 'Ammo',   linkedTo = 'weapon', key = '' },
            { id = 'phone',  label = 'Phone',  accepts = { names = { 'phone', 'iphone', 'samsungphone' } }, key = '' },
            { id = 'radio',  label = 'Radio',  accepts = { names = { 'radio' } }, key = '' },
            -- { id = 'sidearm', label = 'Sidearm', accepts = { type = 'weapon', weapontype = 'Pistol' }, key = '' },
        },
    },
    -- Built-in use handlers owned by kora_inventory for items that otherwise
    -- have no handler anywhere. Set an entry to false to leave that item to
    -- another resource (it then falls back to the legacy UseItem event).
    builtinUsables = {
        -- Using the `parachute` item gives the player GADGET_PARACHUTE and
        -- consumes one item. Refused (item kept) while a parachute is already
        -- equipped.
        parachute = true,
        -- Milliseconds of the kora_lib progress bar (cancellable, with a
        -- pack-up animation) before the parachute is given. 0 skips the bar.
        parachuteTime = 2500,
        -- Optional SetPedParachuteTintIndex value (0-7). nil leaves the default.
        parachuteTint = nil,
        -- Shows the parachute pack on the ped's back while it is worn, by setting
        -- the bag component (5). Freemode peds only; other models are skipped.
        -- The previous bag is restored once the parachute is deployed or gone
        -- (unless the player changed their bag in between). Set enabled = false
        -- to leave clothing alone. Drawables are the stock freemode parachute
        -- pack; adjust per server clothing pack.
        parachuteBag = {
            enabled = true,
            male = { drawable = 8, texture = 0 },
            female = { drawable = 8, texture = 0 },
        },
    },
    -- Downed / last stand / dead players (kora_ambulance sets the
    -- `isdead` / `inlaststand` player metadata, replicated by kora_core) cannot
    -- open the inventory, use hotbar keys or use items. Enforced on the
    -- server as well as the client. Set false to restore the old behaviour.
    blockWhenDowned = true,
    -- Cuffed players (kora_police sets the `ishandcuffed` player metadata and the
    -- replicated `koraCuffed` state bag) cannot open their inventory, use hotbar
    -- keys or use items, and an open inventory is closed the moment they are
    -- cuffed. Enforced on the server (metadata) as well as the client. Set false
    -- to let cuffed players keep using their inventory.
    blockWhenCuffed = true,
    -- Item names that may still be used while downed (e.g. { "bandage" }).
    -- Only affects item use; opening the inventory stays blocked. Default none.
    downedAllowedItems = {},
    -- Minimum milliseconds between "you cannot do that while downed" notifies.
    downedNotifyCooldown = 3000,
    -- Anti-exploit: while an item is being used (a useable handler is running,
    -- e.g. kora_consumables waiting on its progress bar) or any kora_lib
    -- progress bar is active, the inventory cannot be opened (and is closed if
    -- open) and hotbar use is refused. The server also refuses to drop, give
    -- or move the slot being used, so the item cannot be dropped mid-use and
    -- kept together with its effect. Set false to restore the old behaviour.
    blockWhileBusy = true,
    -- Generic "UI blocked" player state bag. While another resource sets this bag
    -- to true on the local player (kora_emotemenu does so during the Emote Maker
    -- freecam), the inventory cannot be opened, hotbar use is refused and an
    -- open inventory is closed the moment the bag turns true. Independent of
    -- blockWhileBusy. The name is read once at resource start. Set false or "" to
    -- ignore the bag.
    uiBlockBag = "koraUiBlocked",
    -- Safety timeout (ms): a slot stays locked at most this long if a useable
    -- handler never returns. It is cleared as soon as the handler finishes,
    -- errors, or the player disconnects.
    busyTimeout = 30000,
    defaultSlots = 50,
    defaultMaxWeight = 100000,
    interactionDistance = 3.0,
    -- Close the giver's inventory panel after a successful give from the UI.
    closeOnGive = true,
    -- Show a "you gave / you received" notification to both players on a give.
    giveNotify = true,
    -- Show a "you bought Nx item for $X (cash/bank)" notification after a shop
    -- purchase made from the inventory shop UI. The item box receipt is separate
    -- (itemBoxes.showPurchases) and does not say what was charged.
    purchaseNotify = true,
    -- Two-sided confirmed trade window between two nearby players. A player
    -- asks with the inventory's Trade button, /trade or the (unbound) trade
    -- keybind; the other accepts or declines. Both then offer items and cash.
    -- Offers are references to the items in each inventory -- nothing moves
    -- until both players have pressed Ready, waited `confirmDelay` seconds and
    -- pressed Confirm. Any change to either side, or to either inventory,
    -- clears both players' Ready. The server re-checks everything (players,
    -- distance, bucket, items, cash, room) and swaps it all at once, or
    -- nothing at all. Read on every action, so /config changes apply at once
    -- (an open trade is ended when `enabled` turns off). `command` is read
    -- when the resource starts.
    trade = {
        enabled = true,
        slots = 8, -- offer slots per side (1-32)
        allowCash = true, -- each side may add cash (the cash account, or the cash item when cash.asItem is on)
        distance = 3.0, -- metres the two players must stay within
        requestTimeout = 20, -- seconds the other player has to answer a request
        confirmDelay = 3, -- seconds offers are frozen after both press Ready before Confirm is accepted
        maxDuration = 300, -- seconds a trade window may stay open before it is cancelled
        requestCooldown = 10, -- seconds between trade requests from the same player
        command = 'trade', -- chat command that requests a trade with the nearest player; '' for none
    },
    -- Opening another player's inventory is denied by default. Supply a
    -- trusted server callback here (or register one at runtime) to opt into
    -- police/admin/consent rules; proximity alone is never authority.
    playerInspection = { access = nil },
    -- What a searcher sees when they open ANOTHER player's inventory (search,
    -- rob, police). Server-side; the browser only renders what it is sent.
    search = {
        -- Portable containers (bags) in the searched player's inventory are
        -- shown closed: no bound container id and nothing about their contents.
        -- A bag's own weight never includes its contents, so no weight leaks.
        hideContainerContents = true,
        -- Let the searcher open a searched player's bag (openTargetContainer
        -- intent). Needs the normal search permission; the server re-checks
        -- the session, the slot, the target's range/bucket and policy.
        openContainers = true,
        -- Milliseconds of progress bar the searcher must complete before the bag
        -- opens (0..20000, 0 = instant). The SERVER runs the bar on the
        -- searcher's client and refuses an answer that comes back too early.
        openTime = 2000,
    },
    -- Water damage for electronics. Off by default. The client reports (payload
    -- free) that its own player has been swimming; the server rolls each
    -- configured item in that player's own pockets.
    waterDamage = {
        enabled = false,
        -- Seconds in the water before the client reports it.
        swimSeconds = 3,
        -- Item name -> { chance = 0..1 } per report. Defaults are existing items.
        items = {
            phone = { chance = 1.0 },
            iphone = { chance = 1.0 },
            samsungphone = { chance = 1.0 },
            radio = { chance = 0.5 },
        },
        -- 'flag' marks info.waterDamaged (item cannot be used until repaired),
        -- 'convert' turns the item into `into`, 'remove' deletes it.
        mode = 'flag',
        -- Item name used by mode = 'convert' (e.g. 'garbage'). WARNING: the
        -- swim report is self-reported (it can only harm the sender, who can
        -- trigger it at will), so `into` must NEVER be worth more than the
        -- original item. Use junk such as garbage.
        into = nil,
        -- Using this item clears the flag from a damaged item (one is consumed).
        repairItem = 'electronickit',
        -- Item names that protect what is stored in them. Portable containers
        -- protect their contents automatically; only pockets are rolled.
        protectedBy = { 'paperbag' },
    },
    -- Milliseconds an open inventory may sit unused before the server closes it
    -- (the lease). With sessionSliding on, every request the player makes renews
    -- it, so it is an idle timeout. Off, it is a hard limit counted from the
    -- moment the inventory was opened: a player who keeps dragging or buying is
    -- force-closed when it runs out. Vending machine approvals follow the same
    -- rule. Changes apply to the next request.
    sessionTtl = 120000,
    sessionSliding = true,
    -- Log a "slow ... request" line to the server console when answering one
    -- inventory request (move, buy, drop, use) takes the server this many
    -- milliseconds or more. A move normally takes a few; 0 turns the line off.
    -- Use it to tell a slow server from a slow network when drags feel late.
    slowRequestMs = 250,
    dropDistance = 2.0,

    -- A dropped item leaves a real bag on the floor to walk up to, rather than
    -- an invisible interaction point.
    --
    -- The prop is PRESENTATION ONLY and lives entirely on each client: it is a
    -- local, non-networked object, it carries no inventory identity, and
    -- interacting with it opens the drop by the id the server broadcast --
    -- which the server re-checks for access, distance and routing bucket like
    -- any other inventory. Deleting or spoofing the prop gains nothing.
    drops = {
        enabled = true,
        -- Metres. An item dropped within this distance of an existing ground
        -- drop (same routing bucket, with room for it) goes into that drop
        -- instead of creating another bag. 0 turns merging off.
        mergeRadius = 1.5,
        model = 'prop_med_bag_01b',
        -- Drop coordinates come from the player's ped, which is roughly a metre
        -- off the floor. Trace down to the ground so the bag sits on the
        -- surface instead of hovering at waist height.
        placeOnGround = true,
        -- Metres added to the bag's height after it has been placed on the
        -- ground. Positive lifts it, negative sinks it; use it if a custom
        -- `model` still floats or clips. Ignored when placeOnGround is false.
        groundOffset = 0.0,
        -- Metres. Kept at or below dropDistance so the prompt can never appear
        -- at a range the server will refuse to open the drop from.
        interactionDistance = 1.5,
        label = 'Pick up',
        icon = 'package',
    },

    -- Presentation only. Everything in here is pushed to the browser on
    -- `kora_inventory:nui:config` and changes nothing the server decides -- the
    -- inventory engine never reads it. Kept in one sub-table so it is obvious
    -- at a glance which config values cross into the NUI and which do not.
    ui = {
        -- With no second inventory open, show a compact centred player grid.
        -- Selecting an item opens its inspector/actions in a side drawer.
        centreWhenSolo = true,

        -- Outline the first `hotbarSlots` slots in the accent colour so the
        -- keys 1-5 already bound in client/hotbar.lua are visible rather than
        -- folklore. Purely a border: the slots behave identically either way,
        -- and the number keys keep working with this off (see hotbarSlots).
        showHotbar = true,

        -- Seconds the on-screen hotbar stays visible after the player presses
        -- the `kora_inventory:hotbarshow` key (rebindable in Settings > Key
        -- Bindings, default U). It lists the first `hotbarSlots` items and
        -- fades away on its own; 0 disables the key. Read on every press.
        hotbarSeconds = 5,

        -- Size multiplier for the inventory's text, slots and counts, for
        -- players who find the default too small. 1.0 is the original size.
        -- Applied the next time the inventory opens.
        scale = 1.0,

        -- Register the inventory window with kora_hud's /ui editor so each
        -- player can move and resize it (75-125 %) and pick which side their
        -- personal inventory sits on. Saved on the player's own machine. false
        -- = every player gets the layout above. Needs kora_hud.
        playerLayout = true,
        -- Default for the player's "Use my position for stashes and trunks"
        -- choice. false: stashes, trunks and gloveboxes open centred in the
        -- default two-panel layout, and the custom position comes back for the
        -- personal inventory. Size and side apply either way.
        playerLayoutTransfer = false,

        -- Inventory layout the NUI renders: 'classic' (the original window),
        -- 'loadout', 'compact' or 'dock'. This is the server default; players
        -- can override it when playerLayoutChoice is on. Unknown values fall
        -- back to 'classic'. Applied the next time the inventory opens.
        layout = 'classic',
        -- Which layouts players may pick (and the server layout may use). A
        -- layout set to false is hidden from the picker; if every entry is
        -- false, 'classic' stays available.
        layouts = { classic = true, loadout = true, compact = true, dock = true },
        -- Players choose their layout in kora_hud's /ui editor ("Inventory
        -- layout"). false = everyone gets `layout` above. Needs playerLayout =
        -- true and kora_hud.
        playerLayoutChoice = true,

        -- Right-clicking a stack of 2 or more in your own or a stash inventory
        -- opens an in-page "split" dialog (amount, Split, Cancel; Escape or a
        -- click outside cancels). Set to false to make right-click do nothing.
        -- Applied the next time the inventory opens.
        rightClickSplit = true,

        -- What right-clicking an item does (this replaces rightClickSplit,
        -- which is only read when `rightClick` is absent or invalid):
        --   'split' - the split dialog described above (default)
        --   'menu'  - a small context menu at the cursor with Use, Split,
        --             Drop, Give, Ammo info (see weapons.ammoInfo) and Copy,
        --             showing only what applies to that item
        --   'none'  - right-click does nothing
        -- Applied the next time the inventory opens.
        rightClick = 'split',

        -- Quality-of-life presentation flags. Browser-only: the server still
        -- validates every resulting move. Applied the next time the inventory opens.
        -- Shift+click moves a whole stack to the other open inventory.
        quickTransfer = true,
        -- Ctrl+drag moves half a stack, Alt+drag moves one.
        modifierDrag = true,
        -- 1 / 5 / 10 / half / All buttons beside the amount slider.
        quickAmounts = true,
        -- Category chips (All, Weapons, Ammo, Consumables, Other) that dim non-matching slots.
        filters = true,
        -- Hover tooltip on filled slots.
        tooltips = true,
        -- Weight bar turns amber at warnAt and red at dangerAt (fractions of max weight).
        weightWarnings = { enabled = true, warnAt = 0.75, dangerAt = 0.95 },

        -- Paint a drag-and-drop move or a shop purchase in the browser straight
        -- away instead of waiting for the server's reply, then reconcile with
        -- the server's own inventory. The painted item is dimmed (and dashed)
        -- until the server confirms it, and never jumps back to the source slot
        -- while it waits; a move the server refuses, fails or does not answer
        -- in time is undone with a notice saying why. The server still
        -- validates and decides every move and charges every purchase -- this
        -- only changes when the result is drawn. Set to false to show moves
        -- only once the server has confirmed them. Applied the next time the
        -- inventory opens.
        optimisticMoves = true,

        -- While a move is waiting for the server, further drags are queued and
        -- sent in order instead of being refused behind a busy cursor. The
        -- inventory stays draggable at all times; a refused or unanswered move
        -- rolls back on its own, the server is asked to re-send the real state,
        -- and the drags queued behind it still go out. Needs optimisticMoves. Set to false
        -- to lock the inventory (without a wait cursor) until the server
        -- answers. Applied the next time the inventory opens.
        queueMoves = true,

        -- Send the bundled UI's requests to the server as one direct net event
        -- (and get the verdict back as one) instead of through kora_lib's
        -- callback layer, and acknowledge the browser's fetch at once so it never
        -- sits pending behind a busy cursor. The server runs the very same
        -- handlers and checks either way; this only changes the carrier. Set to
        -- false to fall back to kora_lib callbacks (the blocking reply, with the
        -- short 1500 ms deadline below as its default). Third-party renderers
        -- calling the callbacks are unaffected. Applied the next time the
        -- inventory opens.
        directTransport = true,

        -- Milliseconds the UI waits for the server to answer a move before
        -- rolling it back as unanswered and re-syncing (500-60000). With
        -- directTransport nothing blocks while it waits, so the default is
        -- generous: a lag spike should not be shown as a failure. With
        -- directTransport off the browser shows a busy cursor while a request
        -- is outstanding, so keep it near 1500. The same deadline bounds how
        -- long a confirmed move waits for its confirming patch. Applied the
        -- next time the inventory opens.
        moveTimeoutMs = 6000,

        -- Legacy form of moveTimeoutMs, in seconds (0.5-60). Not set by
        -- default; only read when moveTimeoutMs is absent from your config.
        -- moveTimeout = 10,

        -- Small dismissible tip card at the bottom of the inventory window for
        -- players who are new to it. Shown on at most `maxShows` openings,
        -- cycling through short tips about features that are switched on; the
        -- player can press Got it to hide it forever. Progress is kept on the
        -- player's own machine. Applied the next time the inventory opens.
        tips = { enabled = true, maxShows = 5 },

        -- Controls overlay. A keyboard button in the inventory's top bar shows
        -- GTA's native instructional buttons (bottom-right of the screen) listing
        -- what Esc, Enter, the mouse and the Shift / Ctrl / Alt modifiers do, for
        -- the features that are switched on. It is client-side presentation only.
        --   button         - show the toggle button. false hides it and the overlay
        --                    is never shown.
        --   defaultVisible - show the overlay on the first opening, before the
        --                    player has pressed the button (their own choice is
        --                    remembered on their machine afterwards).
        -- Applied the next time the inventory opens.
        controls = { button = true, defaultVisible = false },

        -- Local item artwork. Definition image filenames and per-item
        -- `info.image` filenames resolve under localPath. A full https:// or
        -- nui:// value in info.image is used directly.
        images = {
            localPath = 'nui://kora_inventory/images',
            extensions = { 'webp', 'png', 'gif', 'jpg' },
        },
    },
    auditLimit = 1000,
    -- Item-creation audit log: which script (resource) or player created which
    -- items, to find duplication and badly written scripts. Every item ADD
    -- (AddItem/addItem exports, qb/ox compat, shop purchases, crafting,
    -- exchange, omnipack) is recorded with the invoking resource captured where
    -- the export enters. Transfers between inventories are not creations and
    -- are not logged here. Admins read it with /invaudit (ACE below).
    audit = {
        enabled = true,
        -- Write rows to the kora_inventory_audit table. false keeps only the
        -- in-memory ring (Config.kora_inventory.auditLimit entries).
        persist = true,
        -- Queued rows are written in one batch every flushSeconds, or as soon
        -- as 200 are waiting, so an item add never waits on SQL.
        flushSeconds = 10,
        -- Rows older than this are pruned (once an hour and at start).
        retentionDays = 14,
        -- Also log removals (AddItem's counterpart). Off by default: removals
        -- are far more frequent and rarely explain a duplication.
        trackRemovals = false,
        -- ACE permission needed for /invaudit and its data requests.
        ace = 'kora_inventory.audit',
        command = 'invaudit',
        -- Rolling counters of item AMOUNTS added by one invoking resource
        -- (other than kora_inventory itself) and by one player inside
        -- windowSeconds. Crossing a threshold logs one warning and fires
        -- kora_inventory:server:auditAnomaly, once per window per key.
        anomaly = {
            enabled = true,
            windowSeconds = 300,
            perResourceThreshold = 500,
            perPlayerThreshold = 200,
        },
    },
    -- Admin "omnipack": a read-only shop listing every registered item and
    -- weapon at price 0 and infinite stock. Taking an item adds it to the
    -- admin's inventory through the normal add path (weapons get a fresh
    -- serial) and is recorded in the audit log as 'omnipack'. The server checks
    -- the ACE on open and again on every take.
    omnipack = {
        enabled = true,
        command = 'omnipack',
        ace = 'kora_inventory.omnipack',
        -- Largest single take (the amount picker is bounded by this).
        maxAmount = 100,
    },
    -- Trusted server domains only; client intent must be validated by the caller.
    exchangeCallers = { kora_drugs = true },
    requireSameBucket = true,
    -- Physical cash is opt-in. When enabled, the configured kora_core account is
    -- represented exclusively by this stackable item: it can be given, moved,
    -- stashed and dropped like any other inventory item. kora_core remains the
    -- only money API; kora_inventory's AddItem/RemoveItem cash compatibility
    -- calls are routed back through it so no second balance can be minted.
    -- Enabling/disabling this on an established server is a data migration:
    -- kora_inventory converts ledger cash when it activates and deliberately
    -- fails closed if its provider is stopped. Do not flip it mid-session.
    cash = {
        asItem = false,
        item = 'cash',
        account = 'cash',
    },
    -- Item receipts are owned by kora_inventory, never by the resource which
    -- grants an item.  Leave this disabled for a completely silent/headless
    -- inventory, or tune the single presentation policy here for every
    -- compatible AddItem/RemoveItem caller, kora_inventory shop purchase and
    -- (opt-in) item use.
    itemBoxes = {
        enabled = true,
        duration = 2600,
        showAdditions = true,
        showPurchases = true,
        showRemovals = true,
        -- A useable that consumes its item already draws a removal receipt
        -- through RemoveItem, so uses stay opt-in to avoid two receipts for
        -- one action. Enable this for useables that are not consumed.
        showUses = false,
    },
    -- Item decay / expiry. Items spoil in real time (os.time seconds) and, once
    -- fully decayed, are removed or converted into another item (sandwich ->
    -- garbage). The server checks lazily: when an inventory is viewed, an item is
    -- used or moved, and in a low-frequency sweep of ONLINE players' inventories;
    -- there are no per-item timers. Shipped OFF so a live server's food does not
    -- suddenly vanish; turn it on in /config.
    decay = {
        enabled = false,
        -- 'convert' turns a spoiled item into its `into` item (same slot and
        -- amount) and removes it when no `into` is set. 'remove' always removes.
        defaultAction = 'convert',
        -- Per item name: lifetime = seconds of real time; into = item to convert
        -- to (keeps the amount), nil or '' = remove. An entry here wins over a
        -- `decay = { lifetime = ..., into = ... }` field on the kora_core item
        -- definition. Set an entry to false to exempt an item.
        items = {
            sandwich = { lifetime = 172800, into = 'garbage' },
            burger = { lifetime = 172800, into = 'garbage' },
            water_bottle = { lifetime = 604800 },
        },
        -- Show an "Expires in 1h 20m" row in the item inspector.
        showInInspector = true,
        -- Show a thin freshness bar on the inventory slot.
        showOnSlot = true,
        -- The bar turns --warning below this fraction of life left (0..1) and
        -- --destructive below 10%.
        warnBelow = 0.25,
        -- Seconds between sweeps of online players' inventories so items spoil
        -- even if never opened. 0 = off (items then spoil only when viewed,
        -- used or moved). Minimum 30 when on.
        sweepSeconds = 300,
        -- Stacks of the same item with different ages: 'oldest' merges them and
        -- the whole stack spoils with its oldest member (the stamps are ignored
        -- by the stack check); 'separate' keeps differently aged items in
        -- separate stacks.
        mergePolicy = 'oldest',
        -- Inventory types where time does NOT count (true = frozen while the
        -- item sits there; the time spent is not counted when it comes out).
        -- Player inventories always count.
        pauseIn = {
            stash = false,
            trunk = false,
            glovebox = false,
            container = false,
            drop = false,
        },
    },
    persistence = {
        -- Secondary inventories only. Player items are kora_core-owned and are never
        -- read from or written to this storage layer.
        enabled = true,
        persistDrops = false,
        persistTemporary = false,
        flushInterval = 5000,
        migrationBatchSize = 100,
        legacyTables = { 'inventories', 'stashitems', 'trunkitems', 'gloveboxitems' },
    },
    -- Server-only vehicle storage policy. Clients may suggest a network id,
    -- never a plate, capacity, coordinate or arbitrary inventory key.
    vehicles = {
        distance = 3.0,
        requireSameBucket = true,
        plateMaxLength = 8,
        -- Inventory-key access to vehicle storage (client/vehicles.lua). While
        -- seated the key opens the glovebox; on foot at a vehicle's boot it opens
        -- the trunk. Set `enabled = false` to leave vehicle storage to other
        -- resources (exports.kora_inventory:openInventory('trunk', netId) keeps
        -- working either way).
        enabled = true,
        gloveboxEnabled = true,
        -- Server-side: the glovebox only opens (and stays usable) for a player
        -- seated in that vehicle. false restores the old distance-only rule.
        gloveboxRequireSeated = true,
        trunkEnabled = true,
        -- Cosmetic trunk cargo: items in a trunk are drawn as props inside the
        -- vehicle's boot for nearby players. The server only publishes which
        -- item names sit in which slots on a vehicle state bag; nothing here
        -- opens, moves or changes inventory. Off by default.
        --   drawDistance  metres within which clients build the props
        --   maxProps      props per trunk (1-24)
        --   fallbackModel prop for items with no model of their own
        --   models        item name -> prop model override
        --   bounds        vehicle spawn name -> { min = vec, max = vec } cargo
        --                 box (model space) to calibrate a custom model's boot,
        --                 keyed by vehicle spawn name. Restart after changing
        --                 models or bounds.
        trunkCargo = {
            enabled = false,
            drawDistance = 35.0,
            maxProps = 24,
            fallbackModel = 'prop_med_bag_01b',
            models = {
                water_bottle = 'prop_ld_flow_bottle',
                sandwich = 'prop_sandwich_01',
                phone = 'prop_npc_phone_02',
                bandage = 'prop_ld_health_pack',
                cash = 'prop_cash_pile_01',
            },
            bounds = {},
        },

        -- How close (metres) a player must stand to the boot position to open
        -- the trunk. The boot position is derived from the model dimensions.
        bootReach = 1.8,
        -- Server-side limit (metres) from the player to the vehicle origin when
        -- opening a trunk. Larger than `distance` because the boot sits at the
        -- far end of the vehicle, well away from its centre.
        trunkDistance = 7.0,
        -- Visible trunk animation for the inventory-key trunk path: the player
        -- turns to the boot, the boot (or bonnet for frontBootModels) door opens
        -- and an anim loops while the trunk panel is open. Everything is undone
        -- when the inventory closes (Escape, out of range, item use, death) or
        -- the resource stops; a door that was already open is left open.
        -- dict/clip pick the animation, flag is the TaskPlayAnim flag
        -- (49 = loop + upper body + keep moving), openDoor = false skips the
        -- door. Set enabled = false to turn the whole feature off.
        trunkAnimation = {
            enabled = true,
            dict = 'mini@repair',
            clip = 'fixing_a_ped',
            flag = 49,
            openDoor = true,
        },
        -- Trunk and hood toggles (client/vehicle_doors.lua). With kora_target
        -- running, aiming ALT at the trunk or hood of a vehicle lists Open/Close
        -- for that lid (hidden when the vehicle has no such lid), and the trunk
        -- also lists Trunk storage. The driver can use /trunk and /hood from the
        -- seat. Doors are opened with network control, so everyone sees them.
        -- The trunk is the rear lid, or the front lid for frontBootModels.
        --   enabled          master switch for everything below
        --   targetOptions    Open/Close trunk and hood in the ALT menu
        --   inventoryOption  Trunk storage in the ALT menu when aiming at the trunk
        --   commands         /trunk and /hood in the driver seat
        --   commandNames     rename the commands (false or '' for one disables it);
        --                    read once when the resource starts
        --   respectLocks     a locked vehicle cannot be opened from outside
        --                    (closing, and anything from inside, is always allowed)
        --   targetDistance   metres from the player to the aimed point
        --   partDepth        metres from the end of the vehicle that count as the
        --                    trunk or hood when aiming
        -- Text comes from locales/en.lua (vehicle_doors.*).
        doors = {
            enabled = true,
            targetOptions = true,
            inventoryOption = true,
            commands = true,
            commandNames = { trunk = 'trunk', hood = 'hood' },
            respectLocks = true,
            targetDistance = 3.0,
            partDepth = 1.3,
        },
        -- Refuse trunk access while the vehicle is locked (kora_vehiclekeys
        -- state bag or the native door lock status).
        respectLocks = true,
        -- When kora_lib cannot tell the vehicle class (unknown/addon model or
        -- lookup unavailable) use the `default` row of `classes` below. Set to
        -- false to refuse vehicle storage for such vehicles instead.
        unknownClassFallback = true,
        -- Models whose boot is at the FRONT (rear/mid-engine cars). Everything
        -- else uses the rear boot. Spawn names, case-insensitive.
        frontBootModels = {
            'adder', 'autarch', 'cyclone', 'deveste', 'emerus', 'entity2', 'entityxf',
            'furia', 'gp1', 'ignus', 'italigtb', 'italigtb2', 'krieger', 'le7b',
            'nero', 'nero2', 'osiris', 'penetrator', 'pfister811', 'prototipo', 'reaper',
            's80', 'sc1', 'sheava', 'taipan', 'tempesta', 'tezeract', 'thrax', 'tigon',
            'turismor', 'tyrant', 'vacca', 'vagner', 'visione', 'voltic', 'xa21', 'zentorno',
        },
        -- GTA vehicle classes that have no boot to stand at (8 motorcycles,
        -- 13 cycles, 21 trains). The inventory key ignores them on foot.
        bootSkipClasses = { 8, 13, 21 },
        -- Optional trusted server callbacks. Return false (or false, reason)
        -- to deny access to the server-resolved vehicle descriptor.
        ownerCheck = nil,
        accessCheck = nil,
        -- `false` disables that storage type for the GTA vehicle class.
        classes = {
            default = { trunk = { slots = 50, maxWeight = 60000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [0] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [1] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [2] = { trunk = { slots = 50, maxWeight = 60000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [3] = { trunk = { slots = 45, maxWeight = 50000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [4] = { trunk = { slots = 35, maxWeight = 35000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [5] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [6] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [7] = { trunk = { slots = 25, maxWeight = 25000 }, glovebox = { slots = 4, maxWeight = 5000 } },
            [8] = { trunk = false, glovebox = false }, -- motorcycles
            [9] = { trunk = { slots = 55, maxWeight = 70000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [10] = { trunk = { slots = 80, maxWeight = 120000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [11] = { trunk = { slots = 75, maxWeight = 100000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [12] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [13] = { trunk = false, glovebox = false }, -- cycles
            [14] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- boats
            [15] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- helicopters
            [16] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- planes
            [17] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [18] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [19] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [20] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [21] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- trains
        },
    },
    -- Item-bound containers and evidence are server-only domains. There is no
    -- client event that accepts a container/evidence identifier, owner, item
    -- record, or target item slot. The functions in server/containers.lua are
    -- intended for trusted server resources only.
    containers = {
        defaultSlots = 12,
        defaultMaxWeight = 30000,
        maxIdentifierLength = 96,
        -- Portable containers are opened by using the corresponding item in a
        -- player's own inventory. The first use binds a generated containerId
        -- to that exact unique item; subsequent opens prove present possession
        -- server-side. Keep `allowNested` false unless a resource has a clear
        -- policy for recursive-capacity and self-containment edge cases.
        items = {
            backpack = {
                label = 'Backpack',
                slots = 20,
                maxWeight = 60000,
                allowNested = false,
            },
        },
        evidence = {
            slots = 100,
            maxWeight = 150000,
            distance = 3.0,
            requireSameBucket = true,
            -- Default deny. This callback is trusted server code and receives
            -- (source, action, context). Return true to grant; false, reason
            -- to deny. It must enforce job/ACE/restraint/consent policy.
            --
            -- Supplied by kora_police (resources/[test]/kora_police) per its own
            -- design doc: "kora_police only supplies the access-policy callback
            -- and the UI wiring" for the evidence/confiscation system already
            -- built here. Config is a resource-local Lua global with no
            -- cross-resource setter for this one field (verified: there is no
            -- exports() registration for it, unlike e.g. RegisterInspectionAccess),
            -- so this is edited directly rather than injected at runtime.
            -- On-duty is required, not just job membership, so an officer who
            -- clocks off loses evidence access immediately.
            access = function(source, action, context)
                local job = exports.kora_core:getJob(source)
                if not job or job.name ~= 'police' or not job.onduty then
                    return false, 'not an on-duty police officer'
                end
                return true
            end,
        },
    },
    -- Recipes are registered only by server resources. kora_inventory has no
    -- craft net event: callers must validate their station/role server-side
    -- and invoke the headless CraftItem export with trusted context.
    crafting = {
        maxBatchAmount = 100,
    },
    -- Drag one item of the player's own inventory onto another to combine them
    -- (for example rolling paper + weed = joint). Recipes are order independent:
    -- a + b is the same as b + a. The server holds the only recipe registry
    -- (these entries plus those other resources add with the registerCombination
    -- export); the browser only learns each pair's names and label so it can
    -- ask "Roll a joint? Combine / Cancel" instead of swapping the two slots.
    -- Read when a combine is attempted, so edits apply without a restart.
    combine = {
        -- Master switch. Off: no popover, the combine intent is refused and
        -- dropping one item on another swaps or stacks them as before.
        enabled = true,
        -- Show the kora_lib progress bar for recipes with a time above 0. Off:
        -- every combine completes at once.
        progress = true,
        -- a, b:      the two item names (any order; they must be different
        --            slots, and may be the same item).
        -- result:    the item name produced, `amount` of it (default 1).
        -- consumeA/consumeB: how many of a / b are used up (default 1; 0 keeps
        --            that item, for example a tool).
        -- time:      progress bar milliseconds (0 = instant, default 0).
        -- label:     the question and the progress bar text.
        recipes = {
            {
                a = 'rolling_paper',
                b = 'weed',
                result = 'joint',
                amount = 1,
                consumeA = 1,
                consumeB = 1,
                time = 2500,
                label = 'Roll a joint',
            },
        },
    },
    weapons = {
        defaultDurability = 100,
        maxAmmo = 10000,
        -- Deprecated alias of Config.SerialPrefix; only read when that is left at
        -- its default and this is set to something other than 'QB'.
        -- Ammunition is not merely an integer.  Every loaded round is a
        -- discrete record on its weapon (`info.loadedBullets`), so loading a
        -- 12-round magazine creates exactly 12 traceable rounds.  The
        -- server is the only code that creates, loads, or consumes them.
        ballistics = {
            enabled = true,
            maxLoadedRounds = 240, -- hard metadata cap; keep this close to the weapons used on your server
            shotCooldown = 65, -- client/server floor between native shot reports
            casingOffset = 0.75, -- metres behind/alongside the shooter for the recovered casing marker
        },
        -- "Which ammo does this gun take?" Presentation only: the server adds
        -- `ammo` to weapon views and `ammoType`/`rounds`/`fits` to ammo views,
        -- computed from kora_core's definitions and the weapon's own metadata.
        ammoInfo = {
            enabled = true,
            where = 'both',        -- 'inspector' | 'menu' | 'both' (hint for the UI)
            showLoaded = true,     -- include the rounds currently loaded in the weapon
            showCompatible = true, -- ammo items list the weapons they fit
        },
        -- Wear is applied by the SERVER for every accepted round fired.
        -- `perShot` is durability percentage points (0.10 means 1 point per
        -- 10 shots); per-weapon multipliers make high-wear weapons degrade
        -- faster without changing the shared baseline. Set enabled = false
        -- to keep tracking shots/ammo but disable all firing wear.
        durability = {
            enabled = true,
            perShot = 0.10,
            defaultMultiplier = 1.0,
            multipliers = {
                -- weapon_pistol = 1.0,
                -- weapon_carbinerifle = 1.25,
            },
            excluded = {
                -- weapon_stungun = true,
            },
        },
        -- Explicit allow-lists. An absent weapon (and absent `default`) has
        -- no allowed components, preventing arbitrary client metadata.
        components = {},
        -- Weapon jams (server-authoritative; see server/weapon_upkeep.lua).
        -- When the SERVER accepts a shot it rolls a jam chance that rises from
        -- `baseChance` (weapon at 100% durability) to `lowDurabilityChance`
        -- (at or below `lowDurabilityBelow` percent). A jam is stored on the
        -- weapon (`info.jammed`), shots are refused while it is set, and the
        -- player clears it by holding the clear-jam key (default R): the
        -- server runs a `clearTime` progress bar on the weapon it knows is
        -- drawn. Melee, throwables, weapons that take no ammo and anything in
        -- `excluded` ([weapon_name] = true) never jam. Off by default.
        jams = {
            enabled = false,
            baseChance = 0.002,         -- per accepted shot at full durability (0.002 = 0.2%)
            lowDurabilityChance = 0.03, -- per accepted shot at/below `lowDurabilityBelow`
            lowDurabilityBelow = 30,    -- durability percent where the chance tops out
            clearTime = 1500,           -- ms of progress bar to clear a jam
            excluded = {
                -- weapon_revolver = true,
            },
        },
        -- Repair kits, cleaning and repair counters. All of them act on the
        -- weapon the SERVER knows the player has drawn; nothing about the
        -- weapon is ever taken from the client.
        repair = {
            -- false leaves every kit and the cleaning item to other resources.
            enabled = true,
            -- Durability never goes above this (hard ceiling 100).
            maxDurability = 100,
            -- Kit items. Only names listed here get a built-in use handler, so
            -- other resources' usables are never hijacked. `restore` is
            -- durability points, `time` is the progress bar in ms. Set a kit
            -- to false (or remove it) to hand the item to another resource
            -- (takes effect after a restart; an item another resource
            -- registers with its own handler always wins).
            kits = {
                repairkit = { restore = 25, time = 4000 },
                advancedrepairkit = { restore = 60, time = 6000 },
            },
            -- Cleaning item: clears a jam (when `clearsJam`) and restores a
            -- little durability. One item is consumed per use.
            cleaning = { item = 'cleaningkit', clearsJam = true, restore = 5, time = 3000 },
            -- Repair counters: pay `pricePerPoint` per missing durability point
            -- (rounded up) to restore the drawn weapon to maxDurability. The
            -- server checks the player is at the counter (distance and
            -- routing bucket) and charges `account` ('cash' or 'bank').
            -- Counter points live here only; the client uses the same list
            -- purely to draw the interaction.
            counters = {
                enabled = false,
                pricePerPoint = 15,
                account = 'cash',
                -- Example beside the Cypress Flats Ammu-Nation counter (the x/y/z
                -- in config/shops/ammunation.lua; shift it a step so it does not
                -- sit on top of the shop target):
                -- { coords = vec3(809.49, -2157.27, 29.62), distance = 2.5, bucket = 0, label = 'Weapon repairs' },
                locations = {},
            },
        },
    },
    -- Visible weapon carry. A weapon a player owns but is not currently
    -- holding is rendered on their body for every nearby client, and drawing
    -- one takes time and plays an animation instead of snapping into hand.
    --
    -- This is presentation and pacing only. It never adds, removes, moves or
    -- reveals an inventory item, the carried list is built by the server from
    -- kora_core-owned PlayerData (never submitted by a browser or a client), and
    -- a client may only confirm the draw/holster the server itself asked it
    -- for. Disabling it leaves the inventory model completely unchanged.
    weaponCarry = {
        enabled = true,
        -- Carry pistol-class weapons on the hip (two slots) instead of the back.
        pistolsOnHip = true,
        -- Holster a drawn weapon (back onto the body) and block aiming/firing while a kora_emotemenu emote is active.
        holsterOnEmote = true,
        -- Which of a player's weapons are rendered on their body:
        --   'all'    -- every carryable weapon in the inventory.
        --   'hotbar' -- only weapons in slots 1..hotbarSlots. A weapon stowed
        --              past that range is concealed, and drawing it costs
        --              `concealedDrawTime` extra below.
        visibility = 'hotbar',
        -- Equip/holster timing in milliseconds. 0 restores the previous
        -- instant toggle and skips the animation entirely.
        drawTime = 900,
        holsterTime = 700,
        -- Added to drawTime when the weapon was NOT openly carried -- it sits
        -- outside the hotbar range while visibility = 'hotbar'. Nobody saw it
        -- coming, so it takes longer to produce. Deliberately ignored in
        -- 'all' mode and while this system is disabled: there is no
        -- concealment to price when every weapon is visible, or none are.
        concealedDrawTime = 1800,
        -- Played for the duration of the draw/holster. `false` disables the
        -- animation while keeping the timing.
        --
        -- These two are the FALLBACK, used for anything the per-tier table
        -- below has no entry for.
        drawAnim = { dict = 'reaction@intimidation@cop@unarmed', clip = 'intro', flag = 49 },
        holsterAnim = { dict = 'reaction@intimidation@cop@unarmed', clip = 'outro', flag = 49 },

        -- Per-tier animations, keyed by the SAME tier a weapon gets from
        -- `tiers` below -- so where a weapon is carried and how it is produced
        -- are one decision, not two that can disagree. A rifle coming off the
        -- back and a pistol coming off the hip are different movements, and
        -- playing the hip draw for both was the single most visible tell that
        -- the animation was decorative.
        --
        -- A tier absent here falls back to drawAnim/holsterAnim above; set an
        -- entry to `false` to skip the animation for that tier while keeping
        -- its timing.
        drawAnims = {
            -- Long guns: both hands, reaching over the shoulder.
            back = { dict = 'anim@am_hold_up@male', clip = 'shoppay_idle_a', flag = 49 },
            -- Melee, worn on a sling at the hip.
            sling = { dict = 'melee@holster', clip = 'unholster', flag = 49 },
            -- Sidearm from the hip -- the original animation, which was
            -- correct all along for exactly this tier.
            hip = { dict = 'reaction@intimidation@cop@unarmed', clip = 'intro', flag = 49 },
        },
        holsterAnims = {
            back = { dict = 'anim@am_hold_up@male', clip = 'shoppay_idle_a', flag = 49 },
            sling = { dict = 'melee@holster', clip = 'holster', flag = 49 },
            hip = { dict = 'reaction@intimidation@cop@unarmed', clip = 'outro', flag = 49 },
        },
        -- Freeze/disable policy passed to kora_lib's progress bar while drawing.
        -- Combat is disabled so a draw cannot be used as an instant attack.
        disable = { move = false, combat = true, car = false },
        -- kora_core shared/weapons.lua `weapontype` -> attachment tier. A type
        -- that is absent here is never carried: Throwable and Equipment are
        -- left out on purpose (a grenade on the spine looks wrong and a
        -- parachute already has its own component).
        tiers = {
            Rifle = 'back',
            Shotgun = 'back',
            SMG = 'back',
            Sniper = 'back',
            LMG = 'back',
            Heavy = 'back',
            Melee = 'sling',
            -- Sidearms sit on the hip (see `pistolsOnHip`; false puts them
            -- back on the spine with the long guns).
            Pistol = 'hip',
        },
        -- Attachment positions per tier, taken in order. A weapon that finds
        -- no free position in its tier is simply not rendered, rather than
        -- stacked on top of one that already is.
        --
        -- Offsets are plain {x,y,z} tables rather than vec3: config.lua is a
        -- shared script the plain-Lua smoke tests dofile() outside FiveM,
        -- where vec3 does not exist. The client converts them.
        --
        -- These numbers are the Renewed-Weaponscarry slot table (bone 24817 =
        -- SKEL_Spine3) and are a tuned starting point, not a law -- adjust per
        -- weapon through `weapons` below when a model sits wrong.
        attachments = {
            back = {
                { bone = 24817, pos = { x = 0.04, y = -0.15, z = 0.12 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
                { bone = 24817, pos = { x = 0.04, y = -0.17, z = 0.02 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
                { bone = 24817, pos = { x = 0.04, y = -0.19, z = -0.08 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            sling = {
                { bone = 24817, pos = { x = -0.13, y = -0.16, z = -0.14 }, rot = { x = 5.0, y = 62.0, z = 0.0 } },
                { bone = 24817, pos = { x = -0.13, y = -0.15, z = 0.10 }, rot = { x = 5.0, y = 124.0, z = 0.0 } },
            },
            hip = {
                -- First-pass tuning from an in-game screenshot: the pistol stuck
                -- out sideways from the hip, so the lateral (z) offset is pulled
                -- in. Adjust in game; this has not been verified visually.
                { bone = 24817, pos = { x = -0.28, y = -0.14, z = 0.09 }, rot = { x = 0.0, y = 92.0, z = -13.0 } },
                { bone = 24817, pos = { x = -0.27, y = -0.14, z = 0.09 }, rot = { x = 0.0, y = 92.0, z = 13.0 } },
            },
        },
        -- Per-item overrides, keyed by item name. `tier = false` stops an
        -- item being carried at all; `bone`/`pos`/`rot` override that tier's
        -- next free position for this one item; `model` renders a plain prop
        -- instead of the weapon itself, which is also how a NON-weapon item
        -- (a wrapped brick, a duffel) can be carried -- give it an explicit
        -- `tier` and `model`, since only registry weapons are classified
        -- automatically by `tiers` above.
        weapons = {
            weapon_petrolcan = { tier = false },
            weapon_fireextinguisher = { tier = false },
        },
        -- Weapon component item name -> the GTA component this renders as, so
        -- an attached scope/suppressor shows on the carried weapon. Values are
        -- component names ('COMPONENT_AT_AR_SUPP_02') or hashes. Empty by
        -- default: kora_core's shared registry carries no component -> native
        -- mapping, and guessing one would attach the wrong part.
        components = {},
    },
}

if Config.kora_inventory.weaponCarry.pistolsOnHip == false then
    Config.kora_inventory.weaponCarry.tiers.Pistol = 'back'
end

-- Registers this resource-owned configuration with kora_lib without changing its public Config table.
if Kora and Kora.config and Kora.config.adopt then
    Config.kora_inventory.vehicles.classes = Kora.config.map(Config.kora_inventory.vehicles.classes, nil, {
        keyType = 'mixed',
        requiredKeys = { 'default' },
        scope = 'server',
        label = 'Vehicle storage by GTA class',
        description = 'Defines trusted trunk and glovebox capacities for each GTA vehicle class. Numeric keys are GTA class IDs and “default” is the required fallback. Set trunk or glovebox to false to disable that storage type; slot counts and maximum weights are enforced by the server after kora_inventory restarts.',
    })
    Config.kora_inventory.weapons.components = Kora.config.map(Config.kora_inventory.weapons.components,
        Kora.config.list({}, Kora.config.string('', { minLength = 1 })), {
            scope = 'server',
            label = 'Allowed weapon components',
            description = 'Maps each exact weapon item name to the component item names that may be stored in that weapon’s server-owned metadata. A weapon absent from this map, and with no “default” row, accepts no components. Changes apply after kora_inventory restarts.',
        })
    Config.kora_inventory.weaponCarry.components = Kora.config.map(Config.kora_inventory.weaponCarry.components,
        Kora.config.string('', { minLength = 1 }), {
            label = 'Visible carried-weapon components',
            description = 'Maps an inventory component item name to the exact GTA component model name rendered on a holstered weapon. Only entries in this allow-list are sent to clients, preventing item metadata from requesting arbitrary native components.',
        })
    Config.kora_inventory.slowRequestMs = Kora.config.number(Config.kora_inventory.slowRequestMs, {
        label = 'Log slow inventory requests (milliseconds)',
        description = 'Prints a line to the server console when answering one inventory request (move, purchase, drop, use) takes at least this long. A move normally takes a few milliseconds. 0 turns the line off. Applies from the next request.',
        min = 0,
        max = 10000,
        step = 50,
        scope = 'server',
        live = true,
    })
    Config.kora_inventory.sessionSliding = Kora.config.boolean(Config.kora_inventory.sessionSliding, {
        label = 'Renew an open inventory while it is used',
        description = 'When on, every move, purchase or drop a player makes keeps their open inventory (and a vending machine approval) alive, so it only closes after sitting idle for the session time. Turn it off to close every inventory a fixed time after it was opened, even in the middle of use. Applies from the next request.',
        scope = 'server',
        live = true,
    })
    Config.kora_inventory.vehicles.enabled = Kora.config.boolean(Config.kora_inventory.vehicles.enabled, {
        label = 'Open vehicle storage with the inventory key',
        description = 'When on, pressing the inventory key while seated in a vehicle opens its glovebox, and pressing it at the boot of a vehicle opens its trunk. Turn it off if another resource handles vehicle storage; exports can still open it. Applies on the next key press.',
        live = true,
    })
    Config.kora_inventory.vehicles.gloveboxEnabled = Kora.config.boolean(Config.kora_inventory.vehicles.gloveboxEnabled, {
        label = 'Glovebox from the inventory key',
        description = 'Allows the inventory key to open the glovebox while seated. Which vehicle classes have a glovebox and how big it is comes from the storage-by-class table. Applies on the next key press.',
        live = true,
    })
    Config.kora_inventory.vehicles.trunkEnabled = Kora.config.boolean(Config.kora_inventory.vehicles.trunkEnabled, {
        label = 'Trunk from the inventory key',
        description = 'Allows the inventory key to open the trunk when standing at the boot of a vehicle. Which vehicle classes have a trunk and how big it is comes from the storage-by-class table. Applies on the next key press.',
        live = true,
    })
    Config.kora_inventory.vehicles.bootReach = Kora.config.number(Config.kora_inventory.vehicles.bootReach, {
        label = 'Boot reach (metres)',
        description = 'How close a player must stand to the boot (rear, or front for rear-engine cars) to open the trunk with the inventory key. Raise it if players struggle to find the spot; very large values let them open trunks from the side of the car. Applies on the next key press.',
        min = 0.5,
        max = 5.0,
        step = 0.1,
        live = true,
    })
    Config.kora_inventory.vehicles.trunkDistance = Kora.config.number(Config.kora_inventory.vehicles.trunkDistance, {
        label = 'Trunk server distance (metres)',
        description = 'The furthest a player may be from the vehicle origin when the server accepts a trunk open. The boot is at the end of the vehicle, so this must exceed half the vehicle length plus the boot reach; long vans and trucks need a larger value. Applies on the next trunk open.',
        scope = 'server',
        min = 2.0,
        max = 20.0,
        step = 0.5,
        live = true,
    })
    Config.kora_inventory.vehicles.unknownClassFallback = Kora.config.boolean(Config.kora_inventory.vehicles.unknownClassFallback, {
        label = 'Default storage for unknown vehicle classes',
        description = 'When the vehicle class cannot be resolved, use the default row of the storage-by-class table. Disable to refuse trunk and glovebox access for such vehicles.',
        live = true,
    })
    local doorConfig = Config.kora_inventory.vehicles.doors or {}
    Config.kora_inventory.vehicles.doors = doorConfig
    doorConfig.enabled = Kora.config.boolean(doorConfig.enabled, {
        label = 'Trunk and hood toggles',
        description = 'Master switch for the ALT-menu Open/Close trunk and hood entries and the /trunk and /hood commands. Applies on the next use.',
        live = true,
    })
    doorConfig.targetOptions = Kora.config.boolean(doorConfig.targetOptions, {
        label = 'Trunk and hood in the ALT menu',
        description = 'Shows Open/Close trunk or hood in the target menu while aiming at that end of a vehicle that has that lid. Applies on the next aim.',
        live = true,
    })
    doorConfig.inventoryOption = Kora.config.boolean(doorConfig.inventoryOption, {
        label = 'Trunk storage in the ALT menu',
        description = 'Shows Trunk storage in the target menu while aiming at the trunk of a vehicle. It follows the trunk switches and lock rule of the inventory key. Applies on the next aim.',
        live = true,
    })
    doorConfig.commands = Kora.config.boolean(doorConfig.commands, {
        label = 'Trunk and hood commands',
        description = 'Lets the driver toggle the trunk and hood with /trunk and /hood. Command names come from the commandNames entries in config.lua and are read when the resource starts. Applies on the next use.',
        live = true,
    })
    doorConfig.respectLocks = Kora.config.boolean(doorConfig.respectLocks, {
        label = 'Locked vehicles keep trunk and hood shut',
        description = 'When on, the trunk and hood of a locked vehicle cannot be opened from outside. Closing them, and opening them from inside the vehicle, is always allowed. Applies on the next use.',
        live = true,
    })
    doorConfig.targetDistance = Kora.config.number(doorConfig.targetDistance, {
        label = 'Trunk and hood reach (metres)',
        description = 'How close the aimed point on the vehicle must be to the player for the ALT-menu trunk and hood entries to appear. Applies on the next aim.',
        min = 1.0,
        max = 10.0,
        step = 0.5,
        live = true,
    })
    doorConfig.partDepth = Kora.config.number(doorConfig.partDepth, {
        label = 'Trunk and hood zone depth (metres)',
        description = 'How far in from the front or rear end of a vehicle the aim point still counts as the hood or trunk. Raise it if players struggle to get the entry to appear. Applies on the next aim.',
        min = 0.5,
        max = 3.0,
        step = 0.1,
        live = true,
    })
    Config.kora_inventory.vehicles.respectLocks = Kora.config.boolean(Config.kora_inventory.vehicles.respectLocks, {
        label = 'Locked vehicles block the trunk',
        description = 'When on, the server refuses to open the trunk of a locked vehicle (kora_vehiclekeys lock state or the native door lock) and the player is told the vehicle is locked. Turn it off to let anyone open any trunk. The glovebox of the vehicle you are sitting in is never blocked. Applies on the next trunk open.',
        scope = 'server',
        live = true,
    })
    Config.kora_inventory.vehicles.frontBootModels = Kora.config.list(Config.kora_inventory.vehicles.frontBootModels,
        Kora.config.string('', { minLength = 1 }), {
            label = 'Front-boot vehicle models',
            description = 'Spawn names of rear- or mid-engine cars whose trunk is at the front (for example adder or zentorno). All other cars use the rear boot. Add streamed addon cars here. Applies on the next key press.',
            live = true,
        })
    Config.kora_inventory.vehicles.bootSkipClasses = Kora.config.list(Config.kora_inventory.vehicles.bootSkipClasses,
        Kora.config.integer(0, { min = 0, max = 30 }), {
            label = 'Vehicle classes without a boot',
            description = 'GTA vehicle class numbers that the inventory key ignores when standing next to them (default: motorcycles 8, cycles 13, trains 21). Applies on the next key press.',
            live = true,
        })
    Config.kora_inventory.ui.hotbarSeconds = Kora.config.number(Config.kora_inventory.ui.hotbarSeconds, {
        label = 'Hotbar display time (seconds)',
        description = 'How long the on-screen hotbar stays visible after a player presses the show-hotbar key before it disappears again. Set to 0 to disable the key.',
        min = 0,
        max = 30,
        step = 1,
        live = true,
    })
    Config.kora_inventory.ui.rightClickSplit = Kora.config.boolean(Config.kora_inventory.ui.rightClickSplit, {
        label = 'Right-click splits stacks',
        description = 'When on, right-clicking a stack of two or more items opens a dialog to choose how many to move into an empty slot. Turn it off to make right-click do nothing. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.kora_inventory.ui.optimisticMoves = Kora.config.boolean(Config.kora_inventory.ui.optimisticMoves, {
        label = 'Show inventory moves instantly',
        description = 'When on, moving, stacking, swapping or splitting items appears immediately and is undone if the server refuses the move or does not answer. Turn it off to show a move only after the server has confirmed it, which avoids a brief flash of a move that is then refused. The server checks every move either way. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.kora_inventory.ui.queueMoves = Kora.config.boolean(Config.kora_inventory.ui.queueMoves, {
        label = 'Queue inventory drags while a move is pending',
        description = 'When on (and instant moves are on), you can keep dragging items while an earlier move is still waiting for the server; the extra moves are sent one after another. Turn it off to block dragging until the server has answered. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.kora_inventory.ui.directTransport = Kora.config.boolean(Config.kora_inventory.ui.directTransport, {
        label = 'Send inventory requests directly to the server',
        description = 'When on, the inventory talks to the server over one direct network event instead of kora_lib callbacks, and the browser is never left waiting behind a busy cursor. The server checks every request the same way either way. Turn it off only to fall back to kora_lib callbacks. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.kora_inventory.ui.moveTimeoutMs = Kora.config.number(Config.kora_inventory.ui.moveTimeoutMs, {
        label = 'Inventory move timeout (milliseconds)',
        description = 'How long the inventory waits for the server to answer a move before undoing it, re-syncing and reporting that the server did not respond. Direct requests do not block while they wait, so a few seconds is safe; with direct requests turned off the cursor shows as busy during the wait, so keep it near 1500. Changes apply the next time a player opens their inventory.',
        min = 500,
        max = 60000,
        step = 100,
        live = true,
    })
    Config.kora_inventory.ui.scale = Kora.config.number(Config.kora_inventory.ui.scale, {
        label = 'Inventory UI scale',
        description = 'Scales the inventory text, slot sizes, item counts and weight labels. Leave at 1.0 for the original size; increase it if the inventory is too small on your screen. Changes apply the next time a player opens their inventory.',
        min = 0.5,
        max = 2.0,
        step = 0.05,
        live = true,
    })

    Config.kora_inventory.drops.groundOffset = Kora.config.number(Config.kora_inventory.drops.groundOffset, {
        label = 'Dropped bag height offset (metres)',
        description = 'Adds this many metres to the height of a dropped bag after it has been placed on the ground. Use a positive value if the bag sinks into the floor and a negative value if it floats. Only used while placing dropped bags on the ground is enabled.',
        min = -1.0,
        max = 1.0,
        step = 0.01,
        live = true,
    })

    Config.showTargetHints = Kora.config.optional(Config.showTargetHints, Kora.config.boolean(false), {
        label = 'Show shop counter icons',
        description = 'Controls the floating world icon over shop counters. Leave it unset to follow the target system’s global icon setting, or choose on or off to force it for kora_inventory shops. Applies the next time the shop targets are registered.',
        live = true,
    })

    -- Config = Kora.config.adopt(Config) now runs in config/adopt.lua, after the
    -- per-feature schema files in config/schema/*.lua have registered theirs.
end
