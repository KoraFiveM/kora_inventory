-- Pinned upstream public export contract snapshots. Update only with an
-- intentional compatibility-version bump, never opportunistically.
return {
    koraInventory = {
        commit = '5edddc339c87b9099c8f4f6f493f61d0916716ec',
        server = { 'AddHook', 'AddItem', 'AddListener', 'AddToStash', 'CanAddItem', 'ClearInventory', 'ClearStash', 'CloseInventory', 'CreateInventory', 'CreateShop', 'GetFirstSlotByItem', 'GetFreeWeight', 'GetInventory', 'GetItemByName', 'GetItemBySlot', 'GetItemCount', 'GetItemsByName', 'GetSlots', 'GetSlotsByItem', 'GetTotalWeight', 'HasItem', 'LoadInventory', 'OpenInventory', 'OpenInventoryById', 'OpenShop', 'RemoveFromStash', 'RemoveHook', 'RemoveInventory', 'RemoveItem', 'RemoveListener', 'SaveInventory', 'SetInventory', 'SetItemData', 'UseItem' },
        client = { 'HasItem' },
    },
    oxInventory = {
        commit = 'ce8ad4c624cacebf0b2434a3aa27b363fb4c4b06',
        server = { 'AddItem', 'CanCarryAmount', 'CanCarryItem', 'CanCarryWeight', 'CanSwapItem', 'ClearInventory', 'ConfiscateInventory', 'ConvertInventory', 'ConvertItems', 'CreateDropFromPlayer', 'CreateTemporaryStash', 'CustomDrop', 'GetContainerFromSlot', 'GetCurrentWeapon', 'GetEmptySlot', 'GetInventory', 'GetInventoryItems', 'GetItem', 'GetItemCount', 'GetItemSlots', 'GetSlot', 'GetSlotForItem', 'GetSlotIdWithItem', 'GetSlotIdsWithItem', 'GetSlotWithItem', 'GetSlotsWithItem', 'InspectInventory', 'Inventory', 'ItemList', 'Items', 'RegisterShop', 'RegisterStash', 'RemoveInventory', 'RemoveItem', 'ReturnInventory', 'Search', 'SetDurability', 'SetItem', 'SetMaxWeight', 'SetMetadata', 'SetSlotCount', 'SwapSlots', 'UpdateVehicle', 'addCash', 'forceOpenInventory', 'getBank', 'getCards', 'getCash', 'giveCard', 'registerHook', 'removeCash', 'removeHooks', 'setPlayerInventory', 'useItem' },
        client = { 'CancelProgress', 'GetItemCount', 'GetPlayerItems', 'GetPlayerMaxWeight', 'GetPlayerWeight', 'GetSlotIdWithItem', 'GetSlotWithItem', 'GetSlotsWithItem', 'ItemList', 'Items', 'Keyboard', 'Progress', 'ProgressActive', 'Search', 'closeInventory', 'displayMetadata', 'getCurrentWeapon', 'giveItemToTarget', 'notify', 'openInventory', 'openNearbyInventory', 'setGetPlayerNameMethod', 'setStashTarget', 'suppressItemNotifications', 'useItem', 'useSlot', 'weaponWheel' },
    },
}
