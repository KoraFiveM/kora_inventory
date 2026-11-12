# Converted from the communitybot legacy tests by kora-qa-panel/scripts/convert-legacy.mjs.
# The """ block under each Scenario is the original test text, verbatim. Review before applying.
Feature: kora_inventory — Economy

  @kora_inventory @checklist @checklist:kora_inventory:move-stack-items @cat:economy
  Scenario: Drag, split and stack items
    """
    Checklist test: In the NUI drag items between slots, split stacks and merge; weight/slot limits are enforced.
    """
    Given I have 5 "water"
    And I have 3 "bread"
    When I open my inventory
    And I manually: drag items between slots, split a stack and merge stacks
    Then I confirm: items move, split and merge correctly
    And I confirm: weight and slot limits are enforced

  @kora_inventory @checklist @checklist:kora_inventory:item-inspector @cat:economy
  Scenario: Item inspector and copy
    """
    Checklist test: Open an item inspector in the NUI: shows metadata, serial, durability; Copy button copies item JSON.
    """
    Given I have 1 "weapon_pistol"
    When I open my inventory
    And I manually: open the item inspector on the pistol
    Then I confirm: the inspector shows metadata, serial and durability
    When I manually: click the Copy button in the inspector header
    Then I confirm: the item JSON is copied to the clipboard

  @kora_inventory @checklist @checklist:kora_inventory:drop-items @cat:economy
  Scenario: Drop items to ground bag
    """
    Checklist test: Drop an item: a bag prop appears; walk up and use the Pick up target to open it; nearby drops merge within 1.5m.
    """
    Given I have 2 "water"
    When I open my inventory
    And I manually: drag a water outside the inventory to drop it
    Then I confirm: a bag prop appears on the ground
    When I manually: walk up to the bag and use the Pick up target option
    Then the "drop" inventory opens
    When I manually: drop another item within 1.5m of the bag
    Then I confirm: nearby drops merge into one bag

  @kora_inventory @checklist @checklist:kora_inventory:vehicle-trunk-glovebox @cat:economy
  Scenario: Vehicle trunk and glovebox
    """
    Checklist test: Seated press TAB for glovebox; on foot at the vehicle boot press TAB for trunk (with animation); locked vehicles refuse.
    """
    Given I am in the driver seat of a "test_car"
    When I press the "TAB" key
    Then the "glovebox" inventory opens
    When I get out of the vehicle
    And I manually: stand at the vehicle boot
    And I press the "TAB" key
    Then the "trunk" inventory opens
    And I confirm: the trunk opens with an animation
    When I lock the vehicle
    And I press the "TAB" key
    Then I should see a notification containing "This vehicle is locked."

  @kora_inventory @checklist @checklist:kora_inventory:trunk-hood-commands @cat:economy
  Scenario: /trunk and /hood and ALT door options
    """
    Checklist test: Driver seat run /trunk or /hood to toggle lids; ALT-aim at trunk/hood shows Open/Close and Trunk storage.
    """
    Given I am in the driver seat of a "test_car"
    When I run the command "/trunk"
    Then I confirm: the trunk lid toggles open and closed
    When I run the command "/hood"
    Then I confirm: the hood toggles open and closed
    When I get out of the vehicle
    And I manually: aim at the trunk or hood while holding ALT
    Then I confirm: the ALT menu shows Open/Close and Trunk storage options

  @kora_inventory @checklist @checklist:kora_inventory:shop-ammunation @cat:economy
  Scenario: Ammu-Nation shop
    """
    Checklist test: Visit Ammu-Nation shopkeeper: buy weapons/ammo with the right license/rules; weapon gets a KORA-... serial.
    """
    Given my cash balance is at least 5000
    And I am at "ammu_nation"
    When I manually: approach the Ammu-Nation shopkeeper and open the shop
    And I manually: buy a weapon and ammo
    Then I confirm: purchases follow the license rules
    And I confirm: the bought weapon has a serial starting with KORA-

  @kora_inventory @checklist @checklist:kora_inventory:shop-hints-blips @cat:economy
  Scenario: Shop markers and clerk peds
    """
    Checklist test: Approach shops: chevron marker and clerk ped (clipboard scenario) spawn within 40m; shop blips on the map.
    """
    Given I am at "at_24_7_store"
    When I manually: walk away more than 40 metres and approach the shop again
    Then I confirm: a chevron marker appears at the shop
    And I confirm: a clerk ped playing the clipboard scenario spawns within 40 metres
    And I confirm: shop blips appear on the map

  @kora_inventory @checklist @checklist:kora_inventory:weapon-carry @cat:economy
  Scenario: Visible weapon carry and draw/holster
    """
    Checklist test: Own a weapon in hotbar: it shows on your body; equipping plays a draw animation (longer if not in hotbar).
    """
    Given I have 1 "weapon_pistol"
    When I open my inventory
    And I manually: make sure the pistol is in a hotbar slot (1-5) and close the inventory
    Then I confirm: the pistol is visible on my body
    When I press the "1" key
    Then I confirm: a draw animation plays
    When I manually: move the pistol out of the hotbar and equip it again
    Then I confirm: the draw animation is longer than from the hotbar

  @kora_inventory @checklist @checklist:kora_inventory:weapon-durability-ammo @cat:economy
  Scenario: Weapon ballistics and durability
    """
    Checklist test: Fire a weapon: loaded rounds are tracked per bullet, durability drops per shot, casings drop behind the shooter.
    """
    Given I have a "weapon_pistol" equipped with 30 ammo
    When I manually: fire the weapon several times
    Then I confirm: the loaded rounds are tracked per bullet
    And I confirm: the weapon durability drops with each shot
    And I confirm: casings drop behind me

  @kora_inventory @checklist @checklist:kora_inventory:downed-cuffed-block @cat:economy
  Scenario: Inventory blocked while downed or cuffed
    """
    Checklist test: When dead/laststand or cuffed, inventory cannot be opened and hotbar/use is refused; open inventory closes on cuff.
    """
    Given I have 1 "bandage"
    And I am dead
    When I open my inventory
    Then I confirm: the inventory does not open
    When I press the "1" key
    And I use a "bandage"
    Then I should have 1 "bandage"
    And I confirm: the use is refused
    When I manually: get revived, get cuffed by a second player and then try to open the inventory
    Then I confirm: the inventory cannot be opened and hotbar/use is refused
    When I manually: get uncuffed, open the inventory and ask a second player to cuff me
    Then I confirm: my open inventory closes when I am cuffed

  @kora_inventory @checklist @checklist:kora_inventory:stash-open @cat:economy @manual
  Scenario: Registered stashes (private/shared)
    """
    Checklist test: Open a stash from another resource (houses, boss stash, EMS stash): contents persist across restart; per-citizen stashes are private.
    """
    When I manually: open a stash from another resource (house, boss or EMS stash) and put an item in it
    And I manually: ask an admin to restart the resource and the server, then reopen the stash
    Then I confirm: the contents persisted
    When I manually: ask a second player with a different character to open the same per-citizen stash
    Then I confirm: the other player sees their own private contents, not mine
