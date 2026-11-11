# Converted from the communitybot legacy tests by kora-qa-panel/scripts/convert-legacy.mjs.
# The """ block under each Scenario is the original test text, verbatim. Review before applying.
Feature: kora_inventory — game tests

  @kora_inventory @legacy:inv-open @target:3 @checklist @checklist:kora_inventory:open-inventory-tab @cat:economy
  Scenario: Open and close the inventory
    """
    1. Press TAB, then Escape. Run /inventory, then /closeInv, then /openInv.
    2. Open it with nothing else open.
    Expect: a compact centred grid of your items opens each time (41 slots) and closes with Escape or the close button. With no stash or shop open there is no empty second panel. The game does not keep running behind a stuck cursor after closing.
    Also checklist kora_inventory:open-inventory-tab (Open inventory (TAB / /inventory)): Press TAB or run /inventory: personal inventory (41 slots, 120kg) opens; blocked while downed, cuffed, in pause menu or mid-use.
    """
    When I press the "TAB" key
    Then the "player" inventory opens
    And I confirm: a compact centred grid of my items with 41 slots opens
    When I manually: press Escape
    Then I confirm: the inventory closes
    When I run the command "/inventory"
    Then I confirm: the compact 41-slot grid opens
    When I manually: close it with the close button
    And I run the command "/closeInv"
    And I run the command "/openInv"
    Then I confirm: the compact 41-slot grid opens again
    And I confirm: with no stash or shop open there is no empty second panel
    And I confirm: the game does not keep running behind a stuck cursor after closing

  @kora_inventory @legacy:inv-rebind-open @target:3
  Scenario: Open key can be rebound
    """
    1. In the game settings go to Key Bindings > FiveM and find "Open inventory".
    2. Rebind it to another key and press it.
    Expect: the new key opens the inventory and TAB no longer does. Resetting it brings TAB back.
    """
    When I manually: in the game settings go to Key Bindings > FiveM and find "Open inventory"
    And I manually: rebind it to another key and press it
    Then I confirm: the new key opens the inventory
    When I press the "TAB" key
    Then I confirm: TAB no longer opens the inventory
    When I manually: reset the "Open inventory" binding
    And I press the "TAB" key
    Then the "player" inventory opens

  @kora_inventory @legacy:inv-block-downed @target:3
  Scenario: Blocked while downed or dead
    """
    1. Get downed (laststand) or killed, then try TAB, the hotbar keys 1-5 and using an item.
    Expect: you cannot open the inventory or use anything and you get "You can't do that while downed." (not spammed, at most every few seconds). Opening it again works after you are revived.
    """
    Given I am dead
    When I press the "TAB" key
    And I manually: try the hotbar keys 1-5 and using an item
    Then I confirm: I cannot open the inventory or use anything
    And I should see a notification containing "You can't do that while downed."
    And I confirm: the notification is not spammed, at most once every few seconds
    When I manually: get revived and open the inventory again
    Then I confirm: the inventory opens after I am revived

  @kora_inventory @legacy:inv-block-cuffed @target:2
  Scenario: Blocked while cuffed, closes on cuff
    """
    Needs a police tester. 1. Open your inventory, then get cuffed by police.
    2. While cuffed try TAB and hotbar keys. Then get uncuffed.
    Expect: an open inventory closes the moment you are cuffed. While cuffed you cannot open it or use items ("You can't do that while restrained."). It works again after uncuffing.
    """
    Given my job is "police"
    When I open my inventory
    And I manually: ask a second player to cuff me
    Then I confirm: my open inventory closes the moment I am cuffed
    When I press the "TAB" key
    And I manually: while cuffed try the hotbar keys and using an item
    Then I confirm: I cannot open the inventory or use items
    And I should see a notification containing "You can't do that while restrained."
    When I manually: ask a second player to uncuff me
    And I press the "TAB" key
    Then the "player" inventory opens

  @kora_inventory @legacy:inv-block-busy @target:3
  Scenario: Blocked during a progress bar or item use
    """
    1. Start using an item with a progress bar (food, bandage), and try TAB and hotbar keys while it runs.
    2. Start any other progress bar (e.g. a lockpick or repair).
    Expect: you cannot open the inventory (an open one closes) or use hotbar items while the bar runs ("You can't do that while using an item."). It works again as soon as the bar ends or you cancel.
    """
    Given I have 1 "bandage"
    And I have 1 "lockpick"
    When I use a "bandage"
    Then a progress bar should run
    When I press the "TAB" key
    And I manually: while the progress bar runs, try the hotbar keys
    Then I confirm: I cannot open the inventory, an open one closes and hotbar items cannot be used
    And I should see a notification containing "You can't do that while using an item."
    When I manually: start any other progress bar, e.g. use a lockpick or repair, and try TAB and the hotbar keys
    Then I confirm: the inventory is blocked while the bar runs
    When I cancel the progress bar
    And I press the "TAB" key
    Then the "player" inventory opens

  @kora_inventory @legacy:inv-block-emote-maker @target:3
  Scenario: Blocked in the Emote Maker freecam
    """
    1. Open the emote menu's Emote Maker so the freecam is active, then press TAB and the hotbar keys.
    Expect: the inventory will not open and hotbar use is refused while the freecam is active, and an open inventory closes when it starts. Normal use returns afterwards.
    """
    When I manually: open the emote menu's Emote Maker so the freecam is active
    And I press the "TAB" key
    And I manually: press the hotbar keys
    Then I confirm: the inventory will not open and hotbar use is refused while the freecam is active
    When I manually: leave the Emote Maker, open my inventory, then start the Emote Maker freecam
    Then I confirm: the open inventory closes when the freecam starts
    When I manually: leave the Emote Maker
    And I press the "TAB" key
    Then the "player" inventory opens

  @kora_inventory @legacy:inv-capacity @target:3
  Scenario: Slots and weight limits
    """
    1. Note your weight shown in the inventory (max 120 kg, 41 slots).
    2. Fill your slots with different items, and separately load up on heavy items until you hit the weight limit.
    Expect: weight and slots are shown correctly. You cannot go over either limit: adds from shops, pick ups and gives are refused with a clear message and nothing is lost or half-added.
    """
    When I open my inventory
    Then I confirm: my weight is shown (max 120 kg) with 41 slots
    When I manually: fill all my slots with different items
    And I manually: separately load up on heavy items until I hit the weight limit
    Then I confirm: weight and slots are shown correctly
    And I confirm: I cannot go over either limit; adds from shops, pick ups and gives are refused with a clear message
    And I confirm: nothing is lost or half-added

  @kora_inventory @legacy:inv-drag-move @target:3
  Scenario: Drag to move and swap
    """
    1. Drag an item to an empty slot, then onto an occupied slot with a different item.
    2. Hold and release over invalid targets.
    Expect: it moves to the empty slot and swaps with the other item. A slot that cannot accept the item is shown as invalid. The slot never ends up with two items or an item in two places.
    """
    Given I have 1 "water"
    And I have 1 "bread"
    When I open my inventory
    And I manually: drag an item to an empty slot, then onto an occupied slot with a different item
    Then I confirm: the item moves to the empty slot and swaps with the other item
    When I manually: hold and release an item over invalid targets
    Then I confirm: a slot that cannot accept the item is shown as invalid
    And I confirm: no slot ends up with two items or an item in two places

  @kora_inventory @legacy:inv-drag-stack @target:3
  Scenario: Drag to stack items
    """
    1. Drag a stackable item (water, ammo) onto another stack of the same item.
    2. Try the same with a unique item (weapon) and a different item.
    Expect: same stackable items merge into one stack with the right total. Weapons and other unique items do not merge. Stacks never exceed limits and totals match before and after.
    """
    Given I have 2 "water"
    And I have 20 "pistol_ammo"
    And I have 1 "weapon_pistol"
    When I open my inventory
    And I manually: drag a stackable item (water, ammo) onto another stack of the same item
    Then I confirm: same stackable items merge into one stack with the right total
    When I manually: try the same with a unique item (weapon) and with a different item
    Then I confirm: weapons and other unique items do not merge
    And I confirm: stacks never exceed limits and totals match before and after

  @kora_inventory @legacy:inv-drag-optimistic @target:3
  Scenario: Moves feel instant and roll back on refusal
    """
    1. Drag several items around and watch each move.
    2. Try a move the server should refuse (e.g. into a full stash, or too heavy).
    Expect: a move shows at once (slightly dimmed/dashed) until the server confirms it. A refused or failed move is undone with a notice saying why. The item never jumps back to the old slot while waiting.
    """
    Given I have 3 "water"
    And I have 1 "bread"
    When I open my inventory
    And I manually: drag several items around and watch each move
    Then I confirm: each move shows at once (slightly dimmed/dashed) until the server confirms it
    And I confirm: the item never jumps back to the old slot while waiting
    When I manually: try a move the server should refuse, e.g. into a full stash or too heavy
    Then I confirm: the refused move is undone with a notice saying why

  @kora_inventory @legacy:inv-drag-rapid @target:3
  Scenario: Rapid dragging stays in order
    """
    1. Drag 5-6 items one after another as fast as you can, to different slots.
    2. Do it again between your inventory and a stash.
    Expect: every move is queued and applied in order, none lost, none duplicated, and the inventory never locks with a busy cursor. If one is refused only that move is undone and the rest still go through. Close and reopen: it matches.
    """
    Given I have 3 "water"
    And I have 3 "bread"
    And I have 3 "bandage"
    And I have 3 "sandwich"
    And I have 3 "soda"
    When I open my inventory
    And I manually: drag 5-6 items one after another as fast as I can to different slots
    And I manually: do it again between my inventory and a stash
    Then I confirm: every move is queued and applied in order, none lost, none duplicated
    And I confirm: the inventory never locks with a busy cursor
    And I confirm: if one is refused only that move is undone and the rest still go through
    When I manually: close and reopen the inventory
    Then I confirm: the inventory matches what I left

  @kora_inventory @legacy:inv-split @target:3
  Scenario: Split a stack (right click)
    """
    1. Right-click a stack of 2 or more and use Split with an amount.
    2. Open Split and cancel with Cancel, Escape and a click outside. Try amounts of 0, more than you have, and a negative number.
    Expect: the stack splits into two with the exact amounts. Cancel, Escape and clicking outside close the dialog without changes. Bad amounts are refused or limited. Right-clicking a single item does nothing special.
    """
    Given I have 5 "water"
    And I have 1 "bread"
    When I open my inventory
    And I manually: right-click the stack of water and use Split with an amount
    Then I confirm: the stack splits into two with the exact amounts
    When I manually: open Split and cancel with Cancel, Escape and a click outside
    Then I confirm: each of these closes the dialog without changes
    When I manually: try split amounts of 0, more than I have, and a negative number
    Then I confirm: bad amounts are refused or limited
    When I manually: right-click a single item
    Then I confirm: right-clicking a single item does nothing special

  @kora_inventory @legacy:inv-select-drawer @target:3
  Scenario: Select an item: drawer and filter
    """
    1. Click an item to select it. Close the drawer. Type in "Filter the selected item".
    Expect: a side drawer opens with the item's details and actions. The filter field narrows the details and metadata shown. Selecting another item or closing the drawer updates or hides it cleanly.
    """
    Given I have 1 "water"
    And I have 1 "bread"
    When I open my inventory
    And I manually: click an item to select it
    Then I confirm: a side drawer opens with the item's details and actions
    When I manually: type in "Filter the selected item"
    Then I confirm: the filter field narrows the details and metadata shown
    When I manually: select another item, then close the drawer
    Then I confirm: the drawer updates or hides cleanly

  @kora_inventory @legacy:inv-inspector @target:3
  Scenario: Item inspector: details and metadata
    """
    1. Inspect a weapon, a food item, and an item with extra info (e.g. a unique item).
    Expect: label, amount, weight, price (in shops) and the item's metadata: serial and durability on weapons, quality or other info elsewhere. Numbers show as a clean value (like 92.7 or 100) not long decimals.
    """
    Given I have 1 "weapon_pistol"
    And I have 1 "sandwich"
    And I have 1 "backpack"
    When I open my inventory
    And I manually: inspect the weapon, the food item and the backpack
    Then I confirm: the inspector shows label, amount, weight and the item's metadata
    And I confirm: the weapon shows serial and durability, other items show quality or other info
    And I confirm: numbers show as a clean value like 92.7 or 100, not long decimals

  @kora_inventory @legacy:inv-inspector-copy @target:3
  Scenario: Inspector: Copy item details
    """
    1. In the inspector press Copy, paste into a text editor.
    2. Try to select text elsewhere in the inventory with the mouse.
    Expect: a JSON with label, name, amount, slot, inventory and full metadata. You can select text inside the inspector only; the rest of the inventory text is not selectable.
    """
    Given I have 1 "weapon_pistol"
    When I open my inventory
    And I manually: inspect the weapon, press Copy and paste into a text editor
    Then I confirm: the pasted JSON has label, name, amount, slot, inventory and full metadata
    When I manually: try to select text elsewhere in the inventory with the mouse
    Then I confirm: I can select text inside the inspector only; the rest of the inventory text is not selectable

  @kora_inventory @legacy:inv-use-item @target:3
  Scenario: Use an item (Enter, button, double click)
    """
    1. Select a useable item (food, drink, bandage) and press Enter, the Use button, or activate it from its slot.
    2. Use one with a progress bar and cancel the bar halfway.
    Expect: the item's effect runs and one is consumed. A progress bar runs first where the item has one. A cancelled bar does not use or consume the item and nothing is applied.
    """
    Given I have 2 "sandwich"
    And I have 2 "water"
    And I have 2 "bandage"
    When I open my inventory
    And I manually: select a useable item and press Enter, use the Use button, or activate it from its slot
    Then I confirm: the item's effect runs and one is consumed
    And I confirm: a progress bar runs first where the item has one
    When I use a "sandwich"
    Then a progress bar should run
    When I cancel the progress bar
    Then I should have 2 "sandwich"
    And I confirm: nothing is applied from the cancelled use

  @kora_inventory @legacy:inv-use-lock @target:3 @checklist @checklist:kora_inventory:use-item @cat:economy
  Scenario: Slot locked while an item is in use
    """
    1. Start using an item with a long progress bar, then try to drag, drop or give that same slot.
    2. Cancel or finish it, and try again.
    Expect: the slot being used cannot be moved, dropped or given until the use ends (no keeping the item and its effect). It unlocks when the use finishes, is cancelled, errors, or after the safety timeout.
    Also checklist kora_inventory:use-item (Use an item): Use an item from the inventory (e.g. food, bandage); handler runs, progress bar blocks drop/move of that slot while busy.
    """
    Given I have 3 "sandwich"
    When I use a "sandwich"
    Then a progress bar should run
    When I manually: while the progress bar runs, try to drag, drop or give that same slot
    Then I confirm: the slot being used cannot be moved, dropped or given until the use ends
    When I cancel the progress bar
    And I manually: try to move the slot again
    Then I confirm: the slot unlocks after the use is cancelled
    When I use a "sandwich"
    And I manually: let the use finish, then try to move the slot
    Then I confirm: the slot unlocks when the use finishes

  @kora_inventory @legacy:inv-hotbar-keys @target:3 @checklist @checklist:kora_inventory:hotbar-keys @cat:economy
  Scenario: Hotbar keys 1-5
    """
    1. Put items in slots 1-5 and press keys 1 to 5.
    2. Press a key for an empty slot. Rebind one under Key Bindings > FiveM.
    Expect: each key uses the item in that slot (a weapon is equipped, food is used). An empty slot does nothing. Rebinding works and the keys are blocked in the downed, cuffed and busy cases.
    Also checklist kora_inventory:hotbar-keys (Hotbar keys 1-5): Press 1-5 to use the item in that slot (weapons equip); keys are rebindable under Key Bindings > FiveM.
    """
    Given I have 1 "weapon_pistol"
    And I have 2 "sandwich"
    And I have 2 "water"
    And I have 2 "bandage"
    And I have 2 "bread"
    When I manually: put items in slots 1-5 and press keys 1 to 5
    Then I confirm: each key uses the item in that slot (a weapon is equipped, food is used)
    When I manually: press a key for an empty slot
    Then I confirm: an empty slot does nothing
    When I manually: rebind one hotbar key under Key Bindings > FiveM and press it
    Then I confirm: rebinding works
    And I confirm: the keys are blocked in the downed, cuffed and busy cases

  @kora_inventory @legacy:inv-hotbar-show @target:3 @checklist @checklist:kora_inventory:hotbar-overlay @cat:economy
  Scenario: Show hotbar overlay (U)
    """
    1. Close the inventory and press U, both on foot and in a vehicle.
    2. Press U repeatedly.
    Expect: a short overlay of slots 1-5 with their items fades in, stays about 5 seconds and fades out. It sits clear of the HUD circles and minimap on foot and higher in a vehicle. Mashing U does not stack or flicker.
    Also checklist kora_inventory:hotbar-overlay (Show hotbar overlay (U)): Press U with the inventory closed: a short hotbar overlay of slots 1-5 shows then hides.
    """
    Given I have 1 "water"
    And I have 1 "bread"
    When I manually: close the inventory
    And I press the "U" key
    Then I confirm: a short overlay of slots 1-5 with their items fades in, stays about 5 seconds and fades out
    And I confirm: the overlay sits clear of the HUD circles and minimap
    When I manually: get in a vehicle
    And I press the "U" key
    Then I confirm: the overlay sits higher in a vehicle
    When I press the "U" key
    And I press the "U" key
    And I press the "U" key
    Then I confirm: mashing U does not stack or flicker the overlay

  @kora_inventory @legacy:inv-hotbar-outline @target:3
  Scenario: Hotbar slots are marked in the panel
    """
    1. Open the inventory and look at slots 1-5.
    Expect: slots 1-5 have an accent coloured outline (the theme colour) so the number keys are visible. The outline is only visual: the other slots behave the same.
    """
    When I open my inventory
    Then I confirm: slots 1-5 have an accent coloured outline in the theme colour
    And I confirm: the other slots behave the same as the hotbar slots

  @kora_inventory @legacy:inv-item-receipts @target:3
  Scenario: Item receipts (boxes)
    """
    1. Gain, lose and buy items (shop purchase, pick up, a job reward, using a food item).
    Expect: a short receipt box shows each addition, removal and purchase with the item's image and amount. A consumed item shows one removal box, not two. Receipts do not pile up or cover the screen.
    """
    Given I have 1 "bread"
    When I manually: buy an item from a shop
    And I manually: pick up an item from a drop bag
    And I manually: receive an item as a job reward
    And I use a "bread"
    Then I confirm: a short receipt box shows each addition, removal and purchase with the item's image and amount
    And I confirm: the consumed item shows one removal box, not two
    And I confirm: receipts do not pile up or cover the screen

  @kora_inventory @legacy:inv-item-images @target:3
  Scenario: Item images
    """
    1. Browse many different items, including odd ones.
    Expect: every item shows its artwork (bundled images first). An item without artwork shows a letter placeholder, never a broken image icon or a long wait.
    """
    When I open my inventory
    And I manually: browse many different items, including odd ones
    Then I confirm: every item shows its artwork
    And I confirm: an item without artwork shows a letter placeholder, never a broken image icon or a long wait

  @kora_inventory @legacy:inv-ui-layout @target:3
  Scenario: Move and resize the window (/ui)
    """
    1. Open the /ui editor and move, resize (75-125%) and pick the side for your inventory.
    2. Tick "use my position for stashes and trunks". Open a stash. Reconnect.
    Expect: your layout applies to the inventory and is kept after reconnecting. Stashes and trunks use the default centred layout unless you opted in. Size and side apply either way.
    """
    When I run the command "/ui"
    And I manually: move, resize (75-125%) and pick the side for my inventory
    And I manually: tick "use my position for stashes and trunks"
    And I manually: open a stash
    And I manually: reconnect to the server
    Then I confirm: my layout applies to the inventory and is kept after reconnecting
    And I confirm: stashes and trunks use the default centred layout unless I opted in
    And I confirm: size and side apply either way

  @kora_inventory @legacy:inv-ui-resolution @target:3 @manual
  Scenario: UI at different resolutions
    """
    1. Open the inventory, a stash and a shop at 1080p, 1440p/4K and a small or ultrawide window.
    Expect: slots, text, the drawer and the shortcut bar stay on screen, readable and clickable; nothing overlaps or is cut off.
    """
    When I manually: open the inventory, a stash and a shop at 1080p
    And I manually: repeat at 1440p/4K and at a small or ultrawide window
    Then I confirm: slots, text, the drawer and the shortcut bar stay on screen, readable and clickable
    And I confirm: nothing overlaps or is cut off

  @kora_inventory @legacy:inv-session-idle @target:3 @manual
  Scenario: Open inventory times out when idle
    """
    1. Open a stash or shop and leave it alone for about 2 minutes.
    2. Repeat but keep moving items.
    Expect: an idle inventory closes by itself after about 2 minutes and tells you. While you keep dragging, buying or dropping it stays open. Closing never loses or duplicates anything.
    """
    When I manually: open a stash or shop and leave it alone for about 2 minutes
    Then I confirm: the idle inventory closes by itself after about 2 minutes and tells me
    When I manually: open a stash or shop again and keep dragging, buying or dropping items for over 2 minutes
    Then I confirm: the inventory stays open while I keep acting
    And I confirm: closing never loses or duplicates anything

  @kora_inventory @legacy:drop-create @target:3
  Scenario: Drop to the ground (drag outside)
    """
    1. Select an item and drag it outside the inventory window until it says "Release to drop on the ground". Release.
    2. Try the same with an item that cannot be dropped.
    Expect: the item leaves your inventory and a bag appears on the floor at your feet (resting on the ground, not floating). Items that cannot be dropped say "This item cannot be dropped".
    """
    Given I have 1 "bread"
    When I open my inventory
    And I manually: drag the item outside the inventory window until it says "Release to drop on the ground", then release
    Then I should have no "bread"
    And I confirm: a bag appears on the floor at my feet, resting on the ground and not floating
    When I manually: try the same with an item that cannot be dropped
    Then I should see a notification containing "This item cannot be dropped"

  @kora_inventory @legacy:drop-pickup @target:3
  Scenario: Pick up from a drop bag
    """
    1. Walk up to a bag and use the "Pick up" target.
    2. Take some items, then close it. Take everything.
    Expect: the drop opens as a second inventory only when you are close. Items move into your inventory with receipts. When the bag is empty the bag prop disappears for everybody.
    """
    Given I have 1 "bread"
    When I manually: drop the item on the ground, then walk up to the bag and use the "Pick up" target
    Then the "drop" inventory opens
    And I confirm: the drop opens as a second inventory only when I am close
    When I manually: take some items, then close it, then reopen it and take everything
    Then I confirm: items move into my inventory with receipts
    And I confirm: when the bag is empty the bag prop disappears for everybody

  @kora_inventory @legacy:drop-merge @target:3
  Scenario: Nearby drops merge into one bag
    """
    1. Drop two items one after the other within a metre or so.
    2. Move 3+ metres away and drop a third.
    Expect: the second item goes into the first bag (within 1.5 m, if it has room) instead of making a new one. The third makes a separate bag. Opening a merged bag shows all its items.
    """
    Given I have 3 "bread"
    When I manually: drop one item, then drop a second item within a metre of the first
    Then I confirm: the second item goes into the first bag instead of making a new one
    When I manually: move 3+ metres away and drop a third item
    Then I confirm: the third item makes a separate bag
    When I manually: open the merged bag
    Then I confirm: the merged bag shows all its items

  @kora_inventory @legacy:drop-others @target:2
  Scenario: Other players see and use drops
    """
    Two testers. 1. One drops an item.
    2. The other walks up, sees the bag, picks it up, and the dropper checks the bag is gone.
    Expect: both see the bag appear and disappear at the right time. Only one of them can take each item: no duplicate when both try at once. The other player's pick up needs them to be close.
    """
    Given I have 1 "bread"
    When I manually: drop an item
    And I manually: ask a second player to walk up to the bag, check they see it and pick it up
    Then I confirm: both of us see the bag appear and disappear at the right time
    And I confirm: the bag is gone for me after the other player picks it up
    When I manually: ask both players to try taking the same item at once
    Then I confirm: only one of us can take each item, with no duplicate
    And I confirm: the other player's pick up needs them to be close

  @kora_inventory @legacy:drop-range @target:3
  Scenario: Drop range and streaming
    """
    1. Drop items, walk 100+ metres away and come back.
    2. Try to open a drop from the edge of range.
    Expect: bags are still there when you return and reappear as you stream in. A drop will not open from further than the pick up range (about 1.5-2 m). The prompt never appears where the server would refuse.
    """
    Given I have 1 "bread"
    When I manually: drop items, walk 100+ metres away and come back
    Then I confirm: the bags are still there when I return and reappear as I stream in
    When I manually: try to open a drop from the edge of range
    Then I confirm: a drop does not open from further than the pick up range (about 1.5-2 m)
    And I confirm: the prompt never appears where the server would refuse

  @kora_inventory @legacy:drop-full-inventory @target:3
  Scenario: Pick up with a full inventory
    """
    1. Fill your inventory (slots or weight), then try to take items from a bag.
    Expect: items that do not fit are refused with a message; they stay in the bag, nothing disappears. Items that do fit are taken.
    """
    Given I have 50 "water"
    When I manually: fill my inventory further (slots or weight) until nothing more fits
    And I manually: try to take items from a drop bag
    Then I confirm: items that do not fit are refused with a message and stay in the bag
    And I confirm: nothing disappears
    And I confirm: items that do fit are taken

  @kora_inventory @legacy:drop-restart @target:1 @manual
  Scenario: Drops after a server restart
    """
    Admin only. 1. Drop an item and note where. Restart the server (not just the resource).
    Expect: by default drops are not saved, so the bag is gone after a restart. Say in Feedback if that surprises you or if anything odd remains (floating bag, ghost target).
    """
    When I manually: drop an item and note where
    And I manually: ask an admin to restart the server (not just the resource)
    Then I confirm: by default the bag is gone after the restart
    And I confirm: nothing odd remains (no floating bag, no ghost target)

  @kora_inventory @legacy:give-selected @target:2 @checklist @checklist:kora_inventory:give-item @cat:economy
  Scenario: Give an item to a nearby player
    """
    Two testers close together. 1. Select an item, then aim at the other player with the target eye (ALT) and choose "Give selected item".
    Expect: the item moves to the other player. Both see a notification ("You gave 1x ..." and "You received 1x ...") and a receipt. Your inventory panel closes after a successful give.
    Also checklist kora_inventory:give-item (Give item to nearby player): Use the give action in the NUI, aim kora_target at the other player ped and confirm item transfers with receipts on both sides.
    """
    Given I have 1 "bread"
    When I open my inventory
    And I manually: select the item, aim at the other player with the target eye (ALT) and choose "Give selected item"
    Then I should have no "bread"
    And I should see a notification containing "You gave 1x"
    And I confirm: the other player received the item
    And I confirm: the other player sees a notification "You received 1x"
    And I confirm: both of us see a receipt
    And I confirm: my inventory panel closes after the give

  @kora_inventory @legacy:give-amount @target:2
  Scenario: Give a stack: amounts
    """
    Two testers. 1. Give part of a stack, then all of it.
    2. Give with a bigger amount than you have, zero and a negative number if the UI lets you.
    Expect: exactly the amount given moves (both totals add up). Invalid amounts are refused. Nothing is created or lost.
    """
    Given I have 5 "bread"
    When I manually: give part of the stack to the other player
    Then I confirm: exactly the amount given moved and both totals add up
    When I manually: give the rest of the stack
    Then I should have no "bread"
    When I manually: try to give a bigger amount than I have, zero and a negative number if the UI lets me
    Then I confirm: invalid amounts are refused
    And I confirm: nothing is created or lost

  @kora_inventory @legacy:give-refused @target:2
  Scenario: Give refused cases
    """
    Two testers. 1. Try giving to someone who is full, too far away (over 3 m), in a vehicle, or while you are downed or cuffed.
    Expect: each case is refused with a message and nothing moves. A player far away does not appear as a give target.
    """
    Given I have 1 "bread"
    When I manually: try giving an item to a player who has a full inventory
    And I manually: try giving to a player more than 3 m away
    And I manually: try giving while the other player is in a vehicle
    And I manually: try giving while I am downed or cuffed
    Then I confirm: each case is refused with a message and nothing moves
    And I confirm: a player far away does not appear as a give target

  @kora_inventory @legacy:give-target-ui @target:3
  Scenario: Give target picks the right player
    """
    1. With several players or NPCs nearby select an item and open the give target.
    Expect: only real nearby players can be chosen (not NPCs), the one you aim at is the one who receives it. If there is nobody nearby you get a clear message instead of nothing.
    """
    Given I have 1 "bread"
    When I open my inventory
    And I manually: select an item and open the give target with several players or NPCs nearby
    Then I confirm: only real nearby players can be chosen, not NPCs
    And I confirm: the player I aim at is the one who receives the item
    When I manually: repeat with nobody nearby
    Then I confirm: I get a clear message instead of nothing

  @kora_inventory @legacy:veh-glovebox @target:3
  Scenario: Glovebox from the driver or passenger seat
    """
    1. Seat yourself in a vehicle and press TAB.
    2. Put items in, exit, re-enter and check them. Try from a seat of a bike or helicopter.
    Expect: the glovebox opens only while you are seated in that vehicle and keeps its items. Vehicle types without a glovebox (bikes, boats, planes) say there is no storage. Leaving the vehicle closes it.
    """
    Given I am in the driver seat of a "test_car"
    When I press the "TAB" key
    Then the "glovebox" inventory opens
    When I manually: put items in the glovebox, exit, re-enter and open it again
    Then I confirm: the glovebox keeps its items
    And I confirm: the glovebox only opens while I am seated in that vehicle
    When I manually: get out of the vehicle and check the glovebox closes
    Then I confirm: leaving the vehicle closes the glovebox
    When I manually: try TAB from a seat of a bike or helicopter
    Then I should see a notification containing "This vehicle has no storage you can open."

  @kora_inventory @legacy:veh-trunk @target:3
  Scenario: Trunk from outside (TAB at the boot)
    """
    1. Stand at the back of a car (boot) and press TAB.
    2. Put in items, close the inventory.
    Expect: you turn to the boot, the lid opens and a working animation plays while the trunk panel is open. Items you put in stay. Closing the inventory (Escape, walking away, using an item, dying) closes the lid, unless it was open already.
    """
    Given a "test_car" is spawned in front of me with keys
    When I manually: stand at the back of the car (boot)
    And I press the "TAB" key
    Then the "trunk" inventory opens
    And I confirm: I turn to the boot, the lid opens and a working animation plays while the trunk panel is open
    When I manually: put items in the trunk and close the inventory
    Then I confirm: the items I put in stay
    And I confirm: closing the inventory (Escape, walking away, using an item, dying) closes the lid, unless it was open already

  @kora_inventory @legacy:veh-front-boot @target:3 @manual
  Scenario: Rear-engine cars use the front boot
    """
    1. Try a rear or mid-engine car (Adder, Zentorno, Vacca, Osiris, Nero).
    2. Try the same at the back.
    Expect: the trunk opens at the front (the bonnet lid opens) and not at the back. Standing at the back of these cars does nothing. Normal cars still use the rear.
    """
    When I manually: find a rear or mid-engine car (Adder, Zentorno, Vacca, Osiris or Nero) and stand at its front
    And I manually: aim the target eye (ALT) at the front and open the trunk
    And I manually: stand at the back of the car and try the same
    Then I confirm: the trunk opens at the front (the bonnet lid opens) and not at the back
    And I confirm: standing at the back of these cars does nothing
    And I confirm: normal cars still use the rear for the trunk

  @kora_inventory @legacy:veh-no-storage @target:3 @manual
  Scenario: Vehicles with no trunk
    """
    1. Try TAB at a motorcycle, a bicycle and a train, then at a boat or aircraft.
    Expect: bikes and cycles have no trunk or glovebox and nothing opens at them. Boats and aircraft have a trunk but no glovebox. You always get a clear message, never a silent failure or an empty broken panel.
    """
    When I manually: press TAB at a motorcycle, a bicycle and a train
    And I manually: press TAB at a boat and at an aircraft
    Then I confirm: bikes and cycles have no trunk or glovebox and nothing opens at them
    And I confirm: boats and aircraft have a trunk but no glovebox
    And I confirm: I always get a clear message, never a silent failure or an empty broken panel

  @kora_inventory @legacy:veh-class-sizes @target:3 @manual
  Scenario: Storage size by vehicle class
    """
    1. Open the trunk and glovebox of: a compact, a sedan, a van, an SUV, a truck and a sports car. Note slots and the weight limit.
    Expect: sizes differ by class as configured (for example compacts 30 slots / 30 kg, vans 100 slots / 150 kg, glovebox 4-12 slots). Your numbers should look consistent; report any vehicle with odd or default sizes.
    """
    When I manually: open the trunk and glovebox of a compact, a sedan, a van, an SUV, a truck and a sports car and note the slots and weight limit
    Then I confirm: sizes differ by class as configured (e.g. compacts 30 slots / 30 kg, vans 100 slots / 150 kg, glovebox 4-12 slots)
    And I confirm: the numbers look consistent and no vehicle has odd or default sizes

  @kora_inventory @legacy:veh-locked @target:3
  Scenario: Locked vehicles refuse storage
    """
    1. Lock a vehicle and try TAB at the boot and the trunk option in the ALT menu.
    2. Unlock and try again.
    Expect: a locked vehicle refuses the trunk from outside with a message ("This vehicle is locked."). Unlocked works. Closing a trunk or opening storage from inside is always allowed.
    """
    Given a "test_car" is spawned in front of me with keys
    And the vehicle is locked
    When I press the "TAB" key
    And I select the "Trunk storage" target option
    Then I should see a notification containing "This vehicle is locked."
    And I confirm: the trunk does not open from outside while locked
    When I unlock the vehicle
    And I press the "TAB" key
    And I select the "Trunk storage" target option
    Then the "trunk" inventory opens
    And I confirm: closing a trunk or opening storage from inside is always allowed, even when locked

  @kora_inventory @legacy:veh-persist @target:3
  Scenario: Vehicle storage is kept
    """
    1. Put items in a trunk and glovebox, park the vehicle (garage) and take it out again, then reconnect.
    Expect: the items are still in the same vehicle and not in any other. They survive despawn, re-spawn and a reconnect. No duplicate items appear.
    """
    Given a "test_car" is spawned in front of me with keys
    When I manually: put items in the trunk and glovebox
    And I manually: park the vehicle in a garage and take it out again
    And I manually: reconnect to the server
    Then I confirm: the items are still in the same vehicle's trunk and glovebox and not in any other vehicle
    And I confirm: no duplicate items appear after despawn, re-spawn or reconnect

  @kora_inventory @legacy:veh-distance @target:3
  Scenario: Trunk range and walking away
    """
    1. Open a trunk then walk away from the car, and try opening one from too far.
    Expect: the trunk closes when you move out of range and will not open from too far (the boot position matters, not the middle of the car). Large vehicles still open at their boot.
    """
    Given a "test_car" is spawned in front of me with keys
    When I manually: open the trunk then walk away from the car
    Then I confirm: the trunk closes when I move out of range
    When I manually: try to open the trunk from too far away
    Then I confirm: the trunk will not open from too far (the boot position matters, not the middle of the car)
    And I confirm: large vehicles still open at their boot

  @kora_inventory @legacy:veh-trunk-command @target:3
  Scenario: /trunk and /hood from the driver seat
    """
    1. In the driver seat run /trunk and /hood twice each.
    2. Try as a passenger, and in a vehicle with no trunk (e.g. a bike).
    Expect: lids open and close and others can see them. Passengers get "You must be in the driver seat." and vehicles without a lid say so ("This vehicle has no trunk.").
    """
    Given I am in the driver seat of a "test_car"
    When I run the command "/trunk"
    And I run the command "/trunk"
    And I run the command "/hood"
    And I run the command "/hood"
    Then I confirm: the lids open and close and other players can see them
    When I manually: ask a second player to sit in the driver seat and try /trunk and /hood as a passenger myself
    Then I should see a notification containing "You must be in the driver seat."
    When I manually: get on a bike and run /trunk
    Then I should see a notification containing "This vehicle has no trunk."

  @kora_inventory @legacy:veh-alt-menu @target:3
  Scenario: ALT menu on the trunk and hood
    """
    1. Aim the target eye (ALT) at the trunk, then at the hood, of a car.
    2. Try a locked car.
    Expect: Open/Close for the lid and "Trunk storage" for the trunk, hidden when the vehicle has no such lid. A locked car cannot be opened from outside but can be closed. Other players see the lid move.
    """
    Given a "test_car" is spawned in front of me with keys
    When I manually: aim the target eye (ALT) at the trunk of the car
    And I manually: aim the target eye (ALT) at the hood of the car
    Then I confirm: the menu offers Open/Close for the lid and "Trunk storage" for the trunk
    And I confirm: options are hidden when the vehicle has no such lid
    When I lock the vehicle
    And I manually: aim the target eye (ALT) at the trunk of the locked car
    Then I confirm: a locked car cannot be opened from outside but can be closed
    And I confirm: other players see the lid move

  @kora_inventory @legacy:shop-clerk-peds @target:3
  Scenario: Shop clerks appear and serve
    """
    1. Walk toward a 24/7 and a Rob's Liquor store from a distance.
    2. Aim at the clerk with the target eye (ALT).
    Expect: a clerk ped standing behind the counter (clipboard animation) appears within about 40 m and goes away when you leave. ALT on the clerk offers the shop. The clerk cannot be killed, moved or pushed.
    """
    Given I am at "at_24_7_store"
    When I manually: walk toward the 24/7 store from a distance
    Then I confirm: a clerk ped stands behind the counter (clipboard animation) within about 40 m
    When I manually: aim at the clerk with the target eye (ALT)
    Then I confirm: ALT on the clerk offers the shop
    And I confirm: the clerk cannot be killed, moved or pushed
    When I go to "robs_liquor"
    And I manually: walk toward Rob's Liquor from a distance and aim at the clerk with ALT
    Then I confirm: the clerk appears behind the counter and offers the shop
    When I manually: walk away from the store
    Then I confirm: the clerk goes away when I leave

  @kora_inventory @legacy:shop-247-buy @target:3 @checklist @checklist:kora_inventory:shop-247 @cat:economy
  Scenario: 24/7: buy items
    """
    1. Open a 24/7 shop, select an item, set the quantity with the slider and press Buy.
    Expect: the button shows "Buy N · $total", cash is charged exactly, the items arrive with a receipt and a "You bought ..." notice. Prices: water 8, soda 10, coffee 7, chocolate bar 14, sandwich 18, bread 9.
    Also checklist kora_inventory:shop-247 (24/7 convenience shop): Visit a 24/7 clerk (or counter target): open shop, buy food/drink with cash, finite stock decreases.
    """
    Given my cash balance is 500
    And I am at "at_24_7_store"
    When I manually: open the 24/7 shop, select an item, set the quantity with the slider and press Buy
    Then I confirm: the button shows "Buy N · $total"
    And I confirm: cash is charged exactly
    And I confirm: the items arrive with a receipt
    And I should see a notification containing "You bought"
    And I confirm: prices are water 8, soda 10, coffee 7, chocolate bar 14, sandwich 18, bread 9

  @kora_inventory @legacy:shop-247-stock @target:3
  Scenario: 24/7: finite stock
    """
    1. Buy several of one item and watch the stock number.
    2. Buy until it is sold out, and look again later.
    Expect: stock goes down by the amount you bought, a sold out item cannot be bought, and nobody can buy more than is left (the quantity slider limits to what is left).
    """
    Given my cash balance is 2000
    And I am at "at_24_7_store"
    When I manually: open the shop, buy several of one item and watch the stock number
    Then I confirm: stock goes down by the amount I bought
    When I manually: buy until the item is sold out and look again later
    Then I confirm: a sold out item cannot be bought
    And I confirm: nobody can buy more than is left (the quantity slider limits to what is left)

  @kora_inventory @legacy:shop-funds-capacity @target:3
  Scenario: Shop: not enough cash or room
    """
    1. Try to buy with too little cash.
    2. Fill your inventory and try to buy.
    Expect: both purchases are refused with a clear message and no money is taken and no item is given (never one without the other). A free item says you got it for free.
    """
    Given my cash balance is 0
    And I am at "at_24_7_store"
    When I manually: open the shop and try to buy an item with too little cash
    Then I confirm: the purchase is refused with a clear message and no item is given
    And my cash balance should have changed by 0
    When I manually: fill my inventory and try to buy
    Then I confirm: the purchase is refused with a clear message and no money is taken and no item is given
    And I confirm: a free item says I got it for free

  @kora_inventory @legacy:shop-liquor @target:3 @checklist @checklist:kora_inventory:shop-liquor @cat:economy
  Scenario: Liquor store
    """
    1. Visit a Rob's Liquor and look at the stock, then buy a beer, whiskey and a snack.
    Expect: beer 12, whiskey 45 plus water, soda, chocolate bar, sandwich and bread. Charged correctly. Clerks, markers and blips behave like the 24/7.
    Also checklist kora_inventory:shop-liquor (Liquor store shop): Visit Rob's Liquor clerk: buy beer, whiskey, snacks; stock and prices as configured.
    """
    Given my cash balance is 500
    And I am at "robs_liquor"
    When I manually: open the shop and look at the stock
    Then I confirm: stock is beer 12, whiskey 45 plus water, soda, chocolate bar, sandwich and bread
    When I manually: buy a beer, a whiskey and a snack
    Then I confirm: I am charged the correct prices
    And I confirm: clerks, markers and blips behave like the 24/7

  @kora_inventory @legacy:shop-vending @target:3 @checklist @checklist:kora_inventory:shop-vending @cat:economy @manual
  Scenario: Vending machines
    """
    1. Walk up to different vending machines (soda, water, coffee) and target them.
    2. Buy water and soda, leave and return later.
    Expect: a 2-item shop: water 4, soda 5. The machine can be used where it stands anywhere on the map. Walking away closes it; buying again after a pause works.
    Also checklist kora_inventory:shop-vending (Vending machines): Target a vending machine model: buy water/soda; purchase approval follows session rules.
    """
    When I manually: walk up to vending machines (soda, water, coffee) and target them
    Then I confirm: a 2-item shop opens: water 4, soda 5
    When I manually: buy water and soda, then leave and return later
    Then I confirm: the machine can be used where it stands anywhere on the map
    And I confirm: walking away closes it
    And I confirm: buying again after a pause works

  @kora_inventory @legacy:shop-markers-blips @target:3
  Scenario: Shop markers and map blips
    """
    1. Approach counters that have no clerk, and look at the map for shops.
    Expect: a small chevron marker shows within about 10 m at counters without a clerk (not at clerk counters). Ammu-Nation shows a map blip. Nothing is drawn far away, and the marker colour is the theme colour.
    """
    Given I am at "ammu_nation"
    When I manually: approach shop counters that have no clerk and look at the map for shops
    Then I confirm: a small chevron marker shows within about 10 m at counters without a clerk (not at clerk counters)
    And I confirm: Ammu-Nation shows a map blip
    And I confirm: nothing is drawn far away
    And I confirm: the marker colour is the theme colour

  @kora_inventory @legacy:shop-ammunation-buy @target:3
  Scenario: Ammu-Nation: weapons and serial numbers
    """
    1. Open Ammu-Nation and buy a pistol and a melee weapon. Inspect them.
    2. Buy two of the same weapon.
    Expect: you pay the listed price (pistol 7,500, knife 250, bat 500...). Each weapon is its own item with a unique KORA-WEAPON...-time-number serial. Two of one weapon never share a serial.
    """
    Given my cash balance is 10000
    And I am at "ammu_nation"
    When I manually: open Ammu-Nation, buy a pistol and a melee weapon and inspect them
    Then I confirm: I pay the listed price (pistol 7,500, knife 250, bat 500...)
    And I confirm: each weapon has its own unique KORA-WEAPON...-time-number serial
    When I manually: buy two of the same weapon and inspect them
    Then I confirm: two of one weapon never share a serial

  @kora_inventory @legacy:shop-ammunation-ammo @target:3
  Scenario: Ammu-Nation: ammo packs
    """
    1. Buy ammo packs (pistol, SMG, shotgun, rifle).
    2. Load them into a matching weapon.
    Expect: real ammo items in your inventory (pistol_ammo and so on), priced as listed. Using one on a matching weapon loads rounds. A wrong ammo type does not load.
    """
    Given my cash balance is 5000
    And I am at "ammu_nation"
    And I have a "weapon_pistol" equipped
    When I manually: buy ammo packs (pistol, SMG, shotgun, rifle)
    Then I should have at least 1 "pistol_ammo"
    And I should have at least 1 "smg_ammo"
    And I should have at least 1 "shotgun_ammo"
    And I should have at least 1 "rifle_ammo"
    And I confirm: ammo prices are as listed
    When I use a "pistol_ammo"
    Then I confirm: using ammo on a matching weapon loads rounds
    When I manually: try to use a wrong ammo type on the equipped weapon
    Then I confirm: a wrong ammo type does not load

  @kora_inventory @legacy:shop-ammunation-restock @target:2
  Scenario: Ammu-Nation: shared stock and restock
    """
    Two testers. 1. Both buy from a low stock item (e.g. a sniper rifle, 4 in stock) until it runs out.
    2. Wait about 30 minutes.
    Expect: stock is shared, no one can buy more than exists even when both click at once. After the restock interval stock is topped back up to its original amount, never lowered.
    """
    Given my cash balance is 50000
    And I am at "ammu_nation"
    When I manually: ask a second player to join and both buy from a low stock item (e.g. a sniper rifle, 4 in stock) until it runs out, clicking at the same time
    Then I confirm: stock is shared and no one can buy more than exists even when both click at once
    When I wait 120 seconds
    And I manually: wait until about 30 minutes in total have passed
    Then I confirm: after the restock interval stock is topped back up to its original amount, never lowered

  @kora_inventory @legacy:shop-location-checks @target:3
  Scenario: Shop access needs you at the counter
    """
    1. Open a shop, then walk away from the counter.
    2. Try opening Ammu-Nation or a store counter from outside the shop door.
    Expect: the shop closes when you walk off and cannot be opened from outside the counter range. Buying never works from a distance.
    """
    Given I am at "ammu_nation"
    When I manually: open a shop, then walk away from the counter
    Then I confirm: the shop closes when I walk off
    When I manually: try opening Ammu-Nation or a store counter from outside the shop door
    Then I confirm: the shop cannot be opened from outside the counter range
    And I confirm: buying never works from a distance

  @kora_inventory @legacy:shop-purchase-spam @target:3
  Scenario: Shop: spam clicking and double buy
    """
    1. Click Buy rapidly on one item, and press it twice in a row with a different quantity.
    2. Check your cash and items afterwards.
    Expect: every accepted click is charged once and delivers once. A refused purchase is undone with a notice. Your cash change always equals the price of what you received.
    """
    Given my cash balance is 1000
    And I am at "at_24_7_store"
    When I manually: open the shop at the counter
    And I manually: click Buy rapidly on one item
    And I manually: press Buy twice in a row with a different quantity
    Then I confirm: every accepted click is charged once and delivers once
    And I confirm: a refused purchase is undone with a notice
    And I confirm: my cash change equals the price of the items I received

  @kora_inventory @legacy:weapon-carry-visible @target:3
  Scenario: Weapons are visible on your body
    """
    1. Put a rifle, a pistol and a melee weapon in your hotbar (slots 1-5) and look at yourself (and have a friend look).
    Expect: rifles, shotguns and SMGs on your back, pistols on your hip (two slots), melee on a sling. Throwables, a parachute and some items (petrol can, extinguisher) are not shown. Nothing is stacked on top of another.
    """
    Given I have 1 "weapon_carbinerifle"
    And I have 1 "weapon_pistol"
    And I have 1 "weapon_bat"
    When I open my inventory
    And I manually: put the rifle, the pistol and the bat in hotbar slots 1-5
    And I manually: look at myself and ask a friend to look as well
    Then I confirm: the rifle is on my back, the pistol on my hip (two slots) and the melee weapon on a sling
    And I confirm: throwables, a parachute, petrol can and extinguisher are not shown
    And I confirm: nothing is stacked on top of another

  @kora_inventory @legacy:weapon-carry-hotbar-only @target:3
  Scenario: Only hotbar weapons are shown
    """
    1. Keep a weapon in slots 6+ and another in 1-5.
    2. Move them around and watch your body.
    Expect: a weapon outside slots 1-5 is not drawn on you (it is concealed), and drawing it takes noticeably longer. Moving it into the hotbar makes it appear.
    """
    Given I have 1 "weapon_pistol"
    And I have 1 "weapon_carbinerifle"
    When I open my inventory
    And I manually: keep one weapon in slots 6+ and the other in slots 1-5
    And I manually: move the weapons around and watch my body
    Then I confirm: a weapon outside slots 1-5 is not drawn on me and drawing it takes noticeably longer
    And I confirm: moving it into the hotbar makes it appear

  @kora_inventory @legacy:weapon-draw-holster @target:3
  Scenario: Draw and holster timing and animation
    """
    1. Draw and holster a pistol, a rifle and a melee weapon with the hotbar keys.
    2. Try to shoot while the draw is happening.
    Expect: a draw takes about 1 second with an animation that fits the weapon (hip, over the shoulder, sling), holster slightly faster. You cannot fire or attack during the draw. Walking and driving are not blocked.
    """
    Given I have 1 "weapon_pistol"
    And I have 1 "weapon_carbinerifle"
    And I have 1 "weapon_bat"
    When I manually: draw and holster the pistol, the rifle and the bat with the hotbar keys
    And I manually: try to shoot while the draw is happening
    Then I confirm: a draw takes about 1 second with an animation fitting the weapon (hip, over the shoulder, sling)
    And I confirm: holstering is slightly faster than drawing
    And I confirm: I cannot fire or attack during the draw
    And I confirm: walking and driving are not blocked

  @kora_inventory @legacy:weapon-equip-toggle @target:3
  Scenario: Equip, switch and unequip
    """
    1. Press a hotbar key for a weapon, press it again, then press another weapon's key.
    2. Drop, sell or give the equipped weapon.
    Expect: the first press equips, the same key holsters, another key switches. Removing the equipped weapon from your inventory takes it out of your hands at once.
    """
    Given I have 1 "weapon_pistol"
    And I have 1 "weapon_carbinerifle"
    When I manually: press the hotbar key of the pistol
    Then I should have a "weapon_pistol" equipped
    When I manually: press the same hotbar key again
    Then I confirm: the pistol is holstered
    When I manually: press the hotbar key of the pistol, then the key of the rifle
    Then I should have a "weapon_carbinerifle" equipped
    When I manually: drop, sell or give the equipped weapon
    Then I confirm: the weapon is taken out of my hands at once

  @kora_inventory @legacy:weapon-serial @target:3
  Scenario: Weapon serial and unique items
    """
    1. Get several weapons, inspect each, then check grenades and molotovs.
    Expect: every weapon has a unique serial starting KORA-. Grenades and molotovs stack in one slot with no serial. Moving or giving a weapon keeps its serial and durability.
    """
    Given I have 1 "weapon_pistol"
    And I have 1 "weapon_carbinerifle"
    And I have 1 "weapon_smg"
    And I have 3 "weapon_grenade"
    And I have 3 "weapon_molotov"
    When I open my inventory
    And I manually: inspect each weapon
    Then I confirm: every weapon has a unique serial starting KORA-
    When I manually: check the grenades and molotovs
    Then I confirm: grenades and molotovs stack in one slot with no serial
    When I manually: move a weapon and give it to another player
    Then I confirm: moving or giving a weapon keeps its serial and durability

  @kora_inventory @legacy:weapon-ammo-load @target:3
  Scenario: Loading ammo into a weapon
    """
    1. Load ammo into a weapon from a pack, check the inspector, load again.
    2. Try loading too much and the wrong ammo.
    Expect: the loaded rounds and total update in the inspector, the pack shrinks by what was used, and a full weapon or a wrong ammo type refuses with a message and loses nothing.
    """
    Given I have 1 "weapon_pistol"
    And I have 50 "pistol_ammo"
    And I have 10 "rifle_ammo"
    When I open my inventory
    And I manually: load ammo into the pistol from the pack and open the inspector
    Then I confirm: the loaded rounds and total update in the inspector
    And my "pistol_ammo" count should have changed by -1
    When I manually: load ammo into the pistol again
    And I manually: try to load too much ammo and then rifle ammo into the pistol
    Then I confirm: a full weapon or a wrong ammo type refuses with a message and nothing is lost

  @kora_inventory @legacy:weapon-fire-ammo @target:3
  Scenario: Firing uses real rounds
    """
    1. Load a known number of rounds, fire some, check the inspector and the in-game ammo count.
    2. Fire until empty, and reload.
    Expect: each shot uses exactly one round and the displayed and stored counts agree. An empty weapon cannot fire. Casings drop behind or beside you where the shot happened.
    """
    Given I have a "weapon_pistol" equipped with 30 ammo
    When I manually: fire some rounds and check the inspector and the in-game ammo count
    Then I confirm: each shot uses exactly one round
    And I confirm: the displayed and stored counts agree
    When I manually: fire until empty and try to fire again, then reload
    Then I confirm: an empty weapon cannot fire
    And I confirm: casings drop behind or beside me where the shot happened

  @kora_inventory @legacy:weapon-fire-durability @target:3
  Scenario: Weapon durability wears down
    """
    1. Note a weapon's durability, fire 50 and then 100 rounds.
    2. Check automatic weapons vs pistols, and run the weapon to very low durability.
    Expect: durability drops in small steps (about 1 point per 10 shots) and the inspector matches. Say what happens at very low or zero durability (still fires, jams, refuses): we need to know.
    """
    Given I have a "weapon_pistol" equipped with 50 ammo
    And I have 50 "pistol_ammo"
    And I have 1 "weapon_smg"
    When I open my inventory
    And I manually: note the weapon's durability in the inspector
    And I manually: fire 50 rounds, then 100 rounds, and check the inspector
    And I manually: compare an automatic weapon with a pistol
    And I manually: run the weapon down to very low or zero durability
    Then I confirm: durability drops in small steps (about 1 point per 10 shots) and the inspector matches
    And I confirm: I have noted what happens at very low or zero durability (still fires, jams or refuses)

  @kora_inventory @legacy:weapon-shot-rate @target:3
  Scenario: Fast fire is counted correctly
    """
    1. Fire an automatic weapon in full auto, then spam a pistol as fast as you can.
    Expect: rounds used equal shots fired, with no free shots, no extra rounds lost and no desync or kick. The server follows your real shot rate.
    """
    Given I have 1 "weapon_smg"
    And I have 50 "smg_ammo"
    And I have 1 "weapon_pistol"
    And I have 50 "pistol_ammo"
    When I manually: equip the SMG and fire it in full auto until the magazine is empty
    And I manually: equip the pistol and spam the fire button as fast as I can
    Then I confirm: the rounds used equal the shots fired
    And I confirm: there are no free shots and no extra rounds lost
    And I confirm: there is no desync and I am not kicked, the server follows my real shot rate

  @kora_inventory @legacy:weapon-carry-sync @target:2
  Scenario: Other players see what you carry
    """
    Two testers. 1. One moves a weapon in and out of the hotbar, buys one, drops one, dies and respawns.
    2. The other watches.
    Expect: the weapons on the body update within a moment of each change for the watcher too. Nothing shows that the player no longer owns, and nothing is hidden that they do.
    """
    Given I have 1 "weapon_pistol"
    When I manually: ask a second player to watch me
    And I manually: move a weapon in and out of the hotbar, buy one, drop one, die and respawn
    Then I confirm: the other player sees the weapons on my body update within a moment of each change
    And I confirm: the other player sees nothing I no longer own and nothing hidden that I do own

  @kora_inventory @legacy:weapon-carry-emote @target:3
  Scenario: Holster during emotes
    """
    1. Draw a weapon, then start an emote from the emote menu. Try to aim and fire during it.
    Expect: the weapon is holstered on the body when the emote starts and you cannot aim or fire while the emote is active. Aiming works again afterwards.
    """
    Given I have 1 "weapon_pistol"
    When I manually: draw the weapon with its hotbar key
    And I run the command "/e"
    And I manually: start an emote from the emote menu
    And I manually: try to aim and fire during the emote
    Then I confirm: the weapon is holstered on my body when the emote starts
    And I confirm: I cannot aim or fire while the emote is active
    When I manually: stop the emote and try to aim
    Then I confirm: aiming works again

  @kora_inventory @legacy:backpack-open @target:3 @checklist @checklist:kora_inventory:backpack-container @cat:economy
  Scenario: Backpack opens its own container
    """
    1. Use a backpack item and put items in it.
    2. Close it, use it again, and move the backpack to another slot.
    Expect: a separate 20-slot, 60 kg container opens and keeps what you put in. Moving the backpack keeps its contents. You cannot put a backpack inside a backpack.
    Also checklist kora_inventory:backpack-container (Backpack portable container): Use a backpack item: it opens its own 20-slot container bound to that item; nested backpacks refused.
    """
    Given I have 1 "backpack"
    And I have 3 "water"
    When I use a "backpack"
    And I manually: put items in the backpack
    And I manually: close the backpack and use it again
    And I manually: move the backpack to another slot
    And I manually: try to put a backpack inside the backpack
    Then I confirm: a separate 20-slot, 60 kg container opens and keeps what I put in
    And I confirm: moving the backpack keeps its contents
    And I confirm: I cannot put a backpack inside a backpack

  @kora_inventory @legacy:backpack-ownership @target:2
  Scenario: Backpack contents travel with the item
    """
    Two testers. 1. Fill a backpack, give it to the other tester or drop and pick it up.
    2. Have two backpacks with different contents.
    Expect: the contents stay with that exact backpack item when given, dropped or picked up. Two backpacks never share contents. A backpack you do not hold cannot be opened.
    """
    Given I have 2 "backpack"
    And I have 3 "water"
    And I have 3 "bread"
    When I use a "backpack"
    And I manually: fill one backpack with water and the other with bread
    And I manually: give a backpack to a second player, or drop it and pick it up
    And I manually: try to open a backpack I do not hold
    Then I confirm: the contents stay with that exact backpack when given, dropped or picked up
    And I confirm: two backpacks never share contents
    And I confirm: a backpack I do not hold cannot be opened

  @kora_inventory @legacy:parachute-use @target:3 @checklist @checklist:kora_inventory:parachute-item @cat:economy
  Scenario: Parachute item
    """
    1. Use a parachute item and let the bar finish.
    2. Use another while wearing one, cancel a bar, then jump and deploy.
    Expect: a 2.5 second progress bar then the parachute is equipped, one item consumed and the pack shows on your back (freemode). With one already equipped: "You already have a parachute equipped." and the item is kept. A cancelled bar keeps the item. Your old bag comes back after the parachute is gone.
    Also checklist kora_inventory:parachute-item (Parachute item): Use a parachute item: progress bar then parachute equipped and pack shown on back; refused if already equipped.
    """
    Given I have 2 "parachute"
    When I use a "parachute"
    Then a progress bar should run
    When I wait 3 seconds
    Then my "parachute" count should have changed by -1
    And I confirm: the progress bar took about 2.5 seconds, the parachute is equipped and the pack shows on my back
    When I use a "parachute"
    Then I should see a notification containing "You already have a parachute equipped."
    And I should have 1 "parachute"
    When I manually: get rid of the equipped parachute, use a parachute item and cancel the progress bar
    Then I confirm: the item is kept after cancelling
    When I manually: jump from a height and deploy the parachute
    Then I confirm: my old bag comes back after the parachute is gone

  @kora_inventory @legacy:stash-private @target:3 @manual
  Scenario: Private stashes
    """
    1. Open a personal stash (house, locker, personal storage), put items in, close it.
    2. Reconnect and have someone else open the same stash location.
    Expect: you see your own contents and the other player sees only their own (a per-person copy). Contents survive reconnects and a server restart.
    """
    When I manually: open a personal stash (house, locker or personal storage), put items in and close it
    And I manually: reconnect and ask a second player to open the same stash location
    Then I confirm: I see my own contents
    And I confirm: the other player sees only their own contents
    And I confirm: contents survive reconnects and a server restart

  @kora_inventory @legacy:stash-shared @target:2 @needs:players:2 @manual
  Scenario: Shared and job stashes
    """
    Needs two testers (one with the job). 1. Open a shared or boss stash with and without the required job or group.
    Expect: allowed players see the same contents and changes show for both. Anyone without access is refused with a message. Contents persist across restarts.
    """
    When I manually: ask a second player to join, one of us having the required job
    And I manually: open a shared or boss stash with and without the required job or group
    Then I confirm: allowed players see the same contents and changes show for both
    And I confirm: anyone without access is refused with a message
    And I confirm: contents persist across restarts

  @kora_inventory @legacy:stash-distance @target:3 @manual
  Scenario: Stashes need you close
    """
    1. Open a stash then walk away from it, and try to open one from too far.
    Expect: it closes when you walk out of range and cannot be opened from a distance. Nothing is lost when it closes.
    """
    When I manually: open a stash and walk away from it
    Then I confirm: the stash closes when I walk out of range
    And I confirm: nothing is lost when it closes
    When I manually: try to open a stash from too far
    Then I confirm: it cannot be opened from a distance

  @kora_inventory @legacy:stash-transfer-safety @target:3
  Scenario: Stash transfers lose nothing
    """
    1. Move many items back and forth between your inventory and a stash, including heavy and full cases.
    2. Close, reopen, reconnect and compare.
    Expect: totals match what you moved. A full stash refuses cleanly. Nothing duplicates or vanishes anywhere, including after a reconnect.
    """
    Given I have 50 "water"
    And I have 50 "bread"
    When I manually: move many items back and forth between my inventory and a stash, including heavy and full cases
    And I manually: close, reopen and reconnect, then compare totals
    Then I confirm: totals match what I moved
    And I confirm: a full stash refuses cleanly
    And I confirm: nothing duplicates or vanishes anywhere, including after a reconnect

  @kora_inventory @legacy:evidence-police @target:2 @checklist @checklist:kora_inventory:evidence-stash @cat:economy
  Scenario: Police evidence storage
    """
    Needs a police tester. 1. On duty, open the evidence storage and seize an item from a player near you.
    2. Release it. Then go off duty and try again, and try as a non-police player.
    Expect: access only while on duty; off duty or other jobs are denied with a reason. Seize and release move the exact item with its metadata. The player must be close.
    Also checklist kora_inventory:evidence-stash (Police evidence/confiscation storage): As on-duty police open evidence storage; non-police or off-duty are denied.
    """
    Given my job is "police"
    And I am on duty
    When I manually: open the police evidence storage and seize an item from a nearby player
    And I manually: release the seized item
    Then I confirm: the seized and released item keeps its exact metadata
    When I manually: stand far from the other player and try to seize an item
    Then I confirm: seizing is refused because the player is not close
    When I manually: go off duty and try to open the evidence storage
    Then I confirm: access is denied with a reason
    When I manually: as a non-police player, try to open the evidence storage
    Then I confirm: access is denied with a reason

  @kora_inventory @legacy:inspect-other-player @target:2 @manual
  Scenario: Opening another player's inventory
    """
    Two testers (one police if the server allows it). 1. Try to open another player's inventory.
    Expect: it is denied by default and only works through a flow the server allows (for example police). Standing next to someone is never enough. The player being searched keeps their items unless something is taken.
    """
    When I manually: ask a second player to stand next to me
    And I manually: try to open the other player's inventory
    Then I confirm: opening is denied unless a server-allowed flow such as police is used
    And I confirm: standing next to the player is not enough to open their inventory
    And I confirm: the other player keeps all their items unless something is taken

  @kora_inventory @legacy:persist-items @target:3 @manual
  Scenario: Items survive disconnect and restart
    """
    1. Note your whole inventory and stash contents. Disconnect and reconnect, then repeat after a server restart.
    Expect: slots, amounts and metadata (serials, durability, loaded rounds) are all exactly the same.
    """
    When I manually: note my whole inventory and stash contents including metadata
    And I manually: disconnect and reconnect
    Then I confirm: my slots, amounts and metadata (serials, durability, loaded rounds) are exactly the same
    When I manually: ask a Mod to restart the server, then reconnect
    Then I confirm: my slots, amounts and metadata (serials, durability, loaded rounds) are exactly the same as before

  @kora_inventory @legacy:exploit-disconnect @target:3 @manual
  Scenario: Disconnect mid action
    """
    1. Start a drag, a shop purchase, a drop, or a give and quit the game at that moment (several tries).
    2. Reconnect and check inventory, cash, and the other player or the drop.
    Expect: every action either happened completely or not at all. No item exists twice (in your inventory and the drop or other player) and none is lost.
    """
    When I manually: start a drag, a shop purchase, a drop, or a give and quit the game at that moment
    And I manually: reconnect and check my inventory, cash, and the other player or the drop
    Then I confirm: every action either happened completely or not at all
    And I confirm: no item exists twice and none is lost

  @kora_inventory @legacy:exploit-two-actions @target:2 @manual
  Scenario: Two actions on one item
    """
    Two testers. 1. Try to give or drop the same item at the same moment you move it, or have both testers take the same item from a drop or stash at once.
    Expect: only one action wins; the other is refused. The item is never duplicated.
    """
    When I manually: ask a second player to help
    And I manually: try to give or drop the same item at the same moment I move it
    And I manually: have both testers take the same item from a drop or stash at once
    Then I confirm: only one action wins and the other is refused
    And I confirm: the item is never duplicated

  @kora_inventory @legacy:exploit-hotbar-use @target:3
  Scenario: Spamming use and hotbar keys
    """
    1. Spam a hotbar key for a food item, and spam Enter on a selected useable.
    Expect: one item is consumed per real use, never more effects than items. A stack of 1 gives one effect, not several.
    """
    Given I have 1 "sandwich"
    When I open my inventory
    And I manually: spam the hotbar key of the slot holding the sandwich
    And I manually: select a useable item and spam Enter
    Then my "sandwich" count should have changed by -1
    And I confirm: one item is consumed per real use and a stack of 1 gives only one effect

  @kora_inventory @legacy:compat-exports @target:1 @needs:admin @manual
  Scenario: Developer: qb and ox export compatibility
    """
    Developer. 1. From another resource call addItem, removeItem, hasItem, getItemCount, canCarry, registerShop, registerStash, createUseable with qb and ox style names.
    Expect: they work with the same results as the qb-inventory / ox_inventory they replace (no real copy of those running at the same time). Refused calls return false instead of erroring.
    """
    When I manually: from another resource call addItem, removeItem, hasItem, getItemCount, canCarry, registerShop, registerStash and createUseable with qb and ox style names
    Then I confirm: they work with the same results as qb-inventory / ox_inventory
    And I confirm: refused calls return false instead of erroring
    When the F8 console should show no errors

  @kora_inventory @legacy:compat-hooks @target:1 @needs:admin @manual
  Scenario: Developer: hooks and events
    """
    Developer. 1. Register hooks for swapItems, buyItem, createItem, usingItem and craft, then move, buy and use items.
    Expect: hooks receive the documented payloads and can cancel by returning false. Cancelling a buy takes no money. createItem can change metadata but cannot be cancelled.
    """
    When I manually: register hooks for swapItems, buyItem, createItem, usingItem and craft
    And I manually: move, buy and use items
    Then I confirm: hooks receive the documented payloads and can cancel by returning false
    And I confirm: cancelling a buy takes no money
    And I confirm: createItem can change metadata but cannot be cancelled

  @kora_inventory @legacy:craft-api @target:1 @needs:admin @manual
  Scenario: Developer: crafting recipes
    """
    Developer. 1. Register a recipe with RegisterCraftRecipe and call CraftItem with a trusted context, a batch amount, and without the ingredients or room.
    Expect: ingredients are removed and output given in one step. Missing ingredients or no room refuses with nothing changed. A batch is all or nothing and limited to the configured maximum (100).
    """
    When I manually: register a recipe with RegisterCraftRecipe and call CraftItem with a trusted context
    And I manually: call CraftItem with a batch amount
    And I manually: call CraftItem without the ingredients or without room
    Then I confirm: ingredients are removed and output is given in one step
    And I confirm: missing ingredients or no room refuses with nothing changed
    And I confirm: a batch is all or nothing and limited to the configured maximum (100)

  @kora_inventory @legacy:qbinventory-migrate @target:1 @needs:admin @checklist @checklist:kora_inventory:qbinventory-migrate @cat:economy @manual
  Scenario: Admin: /korainventory-migrate
    """
    Admin only, with old qb-inventory data. 1. In the server console run korainventory-migrate dry-run, run, verify and retry.
    Expect: dry-run changes nothing, run copies eligible data once (re-running adds nothing), verify reports state, retry only revisits failed rows. Old rows are never deleted and bad rows go to the quarantine table.
    Note: /korainventory-migrate was called /qbinventory-migrate.
    Also checklist kora_inventory:qbinventory-migrate (Console /korainventory-migrate): Server console: korainventory-migrate dry-run / run / verify / retry for legacy inventory import. Note: /korainventory-migrate was called /qbinventory-migrate.
    """
    When I manually: in the server console run korainventory-migrate dry-run
    Then I confirm: dry-run changes nothing
    When I manually: run korainventory-migrate run, then run it again
    Then I confirm: eligible data is copied once and re-running adds nothing
    When I manually: run korainventory-migrate verify
    Then I confirm: verify reports the migration state
    When I manually: run korainventory-migrate retry
    Then I confirm: retry only revisits failed rows
    And I confirm: old rows are never deleted and bad rows go to the quarantine table
