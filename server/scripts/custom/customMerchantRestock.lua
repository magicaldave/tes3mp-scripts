--[[
	Lear's Custom Merchant Restock Script:
		version 1.00 (for TES3MP 0.8 & 0.8.1)

	DESCRIPTION:
		This simple script will ensure your designated merchants always have their gold restocked.
		Simply add the refId of the merchant you want to always restock gold into the `restockingGoldMerchants` table below.

	INSTALLATION:
		1) Place this file as `customMerchantRestock.lua` inside your TES3MP servers `server\scripts\custom` folder.
		2) Open your `customScripts.lua` file in a text editor.
				(It can be found in `server\scripts` folder.)
		3) Add the below line to your `customScripts.lua` file:
				require("custom.customMerchantRestock")
		4) BE SURE THERE IS NO `--` SYMBOLS TO THE LEFT OF IT, ELSE IT WILL NOT WORK.
		5) Save `customScripts.lua` and restart your server.


	VERSION HISTORY:
		1.00 (5/30/2022)		- Initial public release.

		05/16/2023          - modified by skoomabreath for item restocking
		07/16/2023          - modified by magicaldave (S3ctor) & NuclearWaste to include all restocking merchants' inventories https://github.com/magicaldave/motherJungle/releases/tag/merchantIndexGrabber
    07/17/2023          - S3 fork, rewritten to use external databases for optimization and additional mod support. :flex:
--]]


customMerchantRestock = {}
-- Item restocking for containers that are not the npc's inventory is not implemented
-- items will only show up in the barter window for sale if its an item type the merchant deals in?
-- they will also equip gear you put in their inventory if its better than what they are currently wearing?
-- Add the uniqueIndex of the merchant and table of items you want to restock in the format shown below
-- Fuck that fella we got rust around these parts

local merchantData = jsonInterface.load("custom/merchantIndexDatabase.json")
local merchantRestockLog = false

local initialMerchantGoldTracking = {} -- Used below for tracking merchant uniqueIndexes and their goldPools.

local function fixGoldPool(pid, cellDescription, object)
  local refId = object.refId
  local uniqueIndex = object.uniqueIndex
  local expectedGoldPool

  if merchantData[refId] then
    expectedGoldPool = merchantData[refId].gold_pool
  else
    expectedGoldPool = initialMerchantGoldTracking[uniqueIndex]
  end

	if not expectedGoldPool then return end

		local cell = LoadedCells[cellDescription]
		local objectData = cell.data.objectData

		if not objectData[uniqueIndex] or not objectData[uniqueIndex].refId then return end

    local currentGoldPool = objectData[uniqueIndex].goldPool

    if not currentGoldPool or currentGoldPool >= expectedGoldPool then return end

    tes3mp.ClearObjectList()
    tes3mp.SetObjectListPid(pid)
    tes3mp.SetObjectListCell(cellDescription)

    local lastGoldRestockHour = objectData[uniqueIndex].lastGoldRestockHour
    local lastGoldRestockDay = objectData[uniqueIndex].lastGoldRestockDay

    if not lastGoldRestockHour or not lastGoldRestockDay then
      objectData[uniqueIndex].lastGoldRestockHour = 0
      objectData[uniqueIndex].lastGoldRestockDay = 0
    end

    objectData[uniqueIndex].goldPool = expectedGoldPool

    packetBuilder.AddObjectMiscellaneous(uniqueIndex, objectData[uniqueIndex])

    tes3mp.SendObjectMiscellaneous()

end

local function restockItems(pid, cellDescription, merchant, receivedObject)

  if not receivedObject.uniqueIndex
    or not merchant then
    if merchantRestockLog then
    tes3mp.LogAppend(enumerations.log.WARN, "Received nil object indices, something went very sideways") end return end

  local cell = LoadedCells[cellDescription]
  local objectData = cell.data.objectData
  local reloadInventory = false
  local currentInventory = objectData[receivedObject.uniqueIndex].inventory

  local expectedInventory = merchantData[receivedObject.refId].items

  for _, object in pairs(currentInventory) do
    if merchant.items[object.refId] and object.count < merchant.items[object.refId] then
      object.count = merchant.items[object.refId]
      if not reloadInventory then reloadInventory = true end
    end
  end

  for name, count in pairs(expectedInventory) do
    if not tableHelper.containsValue(currentInventory, name, true) then
      -- I'm concerned this might hose enchanted/magical item sales, but I'm willing to scream test it.
      inventoryHelper.addItem(currentInventory, name, count, -1, -1, "")
      if not reloadInventory then reloadInventory = true end
    end
  end

  if reloadInventory then
    --load container data for all pids in the cell
    for i = 0, #Players do
      if Players[i] ~= nil and Players[i]:IsLoggedIn() then
        if Players[i].data.location.cell == cellDescription then
          cell:LoadContainers(i, cell.data.objectData, {receivedObject.uniqueIndex})
        end
      end
    end
  end
end

local function OnObjectDialogueChoice(eventStatus, pid, cellDescription, objects)
  if not Players[pid] or not Players[pid]:IsLoggedIn() then return end

  for uniqueIndex, object in pairs(objects) do

    if object.dialogueChoiceType ~= enumerations.dialogueChoice.BARTER then return end

    local target = object.refId
    local merchant = merchantData[target]

    if not merchant then
      if merchantRestockLog
      then tes3mp.LogAppend(enumerations.log.INFO, "Tried to reset " .. target .. ", who is not present in the dataset. Please report this in the tes3mp discord!") end
      fixGoldPool(pid, cellDescription, object) return end

    if merchant.restocks_items then
      if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, target .. " restocks items, invoking restockItems") end
      restockItems(pid, cellDescription, merchant, object)
    end

    if merchant.restocks_gold then
      if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, target .. " restocks gold, invoking fixGoldPool") end
      fixGoldPool(pid, cellDescription, object)
    end

    if merchant.restocks_containers then
      local cellData = LoadedCells[cellDescription].data.objectData
      for index, object in pairs(cellData) do
        if merchantData[object.refId] then
          if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, "Trying to reload container data for " .. index) end
          restockItems(pid, cellDescription, merchant, {uniqueIndex = index, refId = object.refId})
        end
      end
    end
  end
end

local function OnObjectMiscellaneous(eventStatus, pid, cellDescription, objects)
  if not Players[pid] or not Players[pid]:IsLoggedIn() then return end

  for uniqueIndex, object in pairs(objects) do
    if not object.goldPool or object.goldPool < 0 then
      if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, "This object's goldpool is nil or invalid") end return end

    local merchant = merchantData[object.refId]

    if not initialMerchantGoldTracking[uniqueIndex] then

      if merchant then
        initialMerchantGoldTracking[uniqueIndex] = merchantData[object.refId].gold_pool
      else
        initialMerchantGoldTracking[uniqueIndex] = object.goldPool
      end

      if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, "Captured initial gold count for merchant " .. object.refId) end

    else

      if not merchant or merchant.restocks_gold then
        if merchantRestockLog then tes3mp.LogAppend(enumerations.log.WARN, "This merchant restocks gold, invoking fixGoldPool") end
        fixGoldPool(pid, cellDescription, object)
      end
    end
  end
end

customEventHooks.registerValidator("OnObjectDialogueChoice", OnObjectDialogueChoice)
customEventHooks.registerValidator("OnObjectMiscellaneous", OnObjectMiscellaneous)

return customMerchantRestock
