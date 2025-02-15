--=======================================================================================================
-- SCRIPT
--
-- Purpose:     Mow/Bale contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    15.02.2025  initial port from FS22
--=======================================================================================================
MowbaleMission = {
	NAME = "mowbaleMission",
	REWARD_PER_HA = 3000,
	REIMBURSEMENT_PER_HA = 2020, 
	debug = true,
}
function debugPrint(text, ...)
	if MowbaleMission.debug == true then
		Logging.info(text,...)
	end
end

local MowbaleMission_mt = Class(MowbaleMission, HarvestMission)
InitObjectClass(MowbaleMission, "MowbaleMission")
function MowbaleMission.registerSavegameXMLPaths(schema, key)
	HarvestMission:superClass().registerSavegameXMLPaths(schema, key)
	local mkey = string.format("%s.mowbale", key)
	schema:register(XMLValueType.STRING, mkey .. "#fillType", "Name of the fill type")
	schema:register(XMLValueType.FLOAT, mkey .. "#expectedLiters", "Expected liters")
	schema:register(XMLValueType.FLOAT, mkey .. "#depositedLiters", "Deposited liters")
	schema:register(XMLValueType.STRING, mkey .. "#sellingStationPlaceableUniqueId", "Unique id of the selling point")
	schema:register(XMLValueType.INT, mkey .. "#unloadingStationIndex", "Index of the unloading station")
end

function MowbaleMission.new(isServer, isClient, customMt)
	-- assume Hay variant as default
	local description = g_i18n:getText("contract_field_mowbale_hay")
	debugPrint("** MowbaleMission.new **")
	local self = AbstractFieldMission.new(isServer, isClient, 
		g_i18n:getText("contract_field_mowbale_title"),
		description, MowbaleMission_mt)

	self.workAreaTypes = {
		[WorkAreaType.CUTTER] = true,
		[WorkAreaType.COMBINECHOPPER] = true,
		[WorkAreaType.COMBINESWATH] = true,
		[WorkAreaType.FRUITPREPARER] = true,
		[WorkAreaType.MOWER] = true,
		[WorkAreaType.BALER] = true,
		[WorkAreaType.TEDDER] = true,
		[WorkAreaType.WINDROWER] = true,
		[WorkAreaType.AUXILIARY] = true,
		[WorkAreaType.FORAGEWAGON] = true 
	}
	self.fillTypeIndex = FillType.DRYGRASS_WINDROW 
	self.fruitTypeIndex = FruitType.GRASS
	self.pendingSellingStationId = nil
	self.sellingStation = nil
	self.depositedLiters = 0
	self.expectedLiters = 0
	self.reimbursementPerHa = 0
	self.lastSellChange = -1
	return self
end
function MowbaleMission:init(field, sellStation)
	local ok = HarvestMission:superClass().init(self, field)
	self:setSellingStation(sellStation)
	return ok
end
function MowbaleMission:onSavegameLoaded()
	if self.field == nil then
		Logging.error("Field is not set for mowbale mission")
		g_missionManager:markMissionForDeletion(self)
		return
	end
	if self.field:getFieldState().fruitTypeIndex ~= self.fruitTypeIndex then
		local v16 = g_fruitTypeManager:getFruitTypeByIndex(self.fruitTypeIndex)
		if v16 == nil then
			Logging.error("FruitType \'%s\' is not defined for mowbale mission", self.fruitTypeIndex)
		else
			Logging.error("FruitType \'%s\' is not present on field \'%s\' for mowbale mission", v16.name, self.field:getName())
		end
		g_missionManager:markMissionForDeletion(self)
		return
	end
	MowbaleMission:superClass().onSavegameLoaded(self)
end
-- MowbaleMission:init(field, ftIndex, sellStation) from HarvestMission:init()

function MowbaleMission:writeStream(streamId, connection)
	-- add expectedLiters, etc in BetterContracts
	MowbaleMission:superClass().writeStream(self, streamId, connection)
end
function MowbaleMission:saveToXMLFile(xmlFile, key)
	local hKey = string.format("%s.mowbale", key)
	xmlFile:setValue(hKey .. "#fillType", 
		g_fillTypeManager.fillTypes[self.fillTypeIndex].name)
	xmlFile:setValue(hKey .. "#expectedLiters", self.expectedLiters)
	xmlFile:setValue(hKey .. "#depositedLiters", self.depositedLiters)
	local placeable = self.sellingStation.owningPlaceable
	if placeable == nil then
		local v34 = self.sellingStation.getName and self.sellingStation:getName() or "unknown"
		Logging.xmlWarning(xmlFile, "Unable to retrieve placeable of sellingStation \'%s\' for saving mowbale mission \'%s\' ", v34, key)
		return
	else
		local index = g_currentMission.storageSystem:getPlaceableUnloadingStationIndex(placeable, self.sellingStation)
		if index == nil then
			local v36 = self.sellingStation.getName and self.sellingStation:getName() or (placeable.getName and placeable:getName() or "unknown")
			Logging.xmlWarning(xmlFile, "Unable to retrieve unloading station index of sellingStation \'%s\' for saving mowbale mission \'%s\' ", v36, key)
		else
			xmlFile:setValue(hKey .. "#sellingStationPlaceableUniqueId", placeable:getUniqueId())
			xmlFile:setValue(hKey .. "#unloadingStationIndex", index)
			HarvestMission:superClass().saveToXMLFile(self, xmlFile, key)
		end
	end
end
function MowbaleMission:loadFromXMLFile(xmlFile, key)
	if not HarvestMission:superClass().loadFromXMLFile(self, xmlFile, key) then
		return false
	end
	local hKey = string.format("%s.mowbale", key)
	local name = xmlFile:getValue(hKey.."#fillType")
	local ft = g_fillTypeManager:getFillTypeIndexByName(name)
	if ft == nil then 
		Logging.xmlError(xmlFile, "FillType \'%s\' not defined", name)
		return false
	end
	self.fillTypeIndex = ft
	if ft == FillType.SILAGE then  
		self.description = g_i18n:getText("contract_field_mowbale_silage")
	end
	self.fruitTypeIndex = FruitType.GRASS
	self.expectedLiters = xmlFile:getValue(hKey .. "#expectedLiters", self.expectedLiters)
	self.depositedLiters = xmlFile:getValue(hKey .. "#depositedLiters", self.depositedLiters)
	local v43 = xmlFile:getValue(hKey .. "#sellingStationPlaceableUniqueId")
	if v43 == nil then
		Logging.xmlError(xmlFile, "No sellingStationPlaceable uniqueId given for mowbale mission at \'%s\'", hKey)
		return false
	end
	local index = xmlFile:getValue(hKey .. "#unloadingStationIndex")
	if index == nil then
		Logging.xmlError(xmlFile, "No unloading station index given for mowbale mission at \'%s\'", hKey)
		return false
	end
	self.sellingStationPlaceableUniqueId = v43
	self.unloadingStationIndex = index
	return true
end
function MowbaleMission:createModifier()
	local ft = g_fruitTypeManager:getFruitTypeByIndex(self.fruitTypeIndex)
	if ft ~= nil and ft.terrainDataPlaneId ~= nil then
		self.completionModifier = DensityMapModifier.new(ft.terrainDataPlaneId, ft.startStateChannel, ft.numStateChannels, g_terrainNode)
		self.completionFilter = DensityMapFilter.new(self.completionModifier)
		self.completionFilter:setValueCompareParams(DensityValueCompareType.EQUAL, ft.cutState)
	end
end
-- MowbaleMission:getFieldFinishTask() -- set whole field cut
function MowbaleMission:getVehicleVariant()
	local ft = self.fillTypeIndex
	return ft == FillType.SILAGE and "SILAGE" or 
		ft == FillType.DRYGRASS_WINDROW and "HAY"
end
function MowbaleMission:getStealingCosts()
	return 0
end
function MowbaleMission:roundToWholeBales(liters)
	local baleSizes = g_baleManager:getPossibleCapacitiesForFillType(self.fillTypeIndex)
	local minBales = math.huge
	local minBaleIndex = 1

	for i = 1, #baleSizes do
		local bales = math.floor(liters * 0.95 / baleSizes[i])
		if bales < minBales then
			minBales = bales
			minBaleIndex = i
		end
	end
	return math.max(minBales * baleSizes[minBaleIndex], liters - 10000)
end
function MowbaleMission:finishedPreparing()
	HarvestMission:superClass().finishedPreparing(self)
	self.expectedLiters = self:roundToWholeBales(self:getMaxCutLiters())
end
function MowbaleMission:getPartitionCompletion(index)
	if self.completionModifier == nil then
		return 0, 0, 0
	end
	return HarvestMission:superClass().getPartitionCompletion(self,index)
end
function MowbaleMission.getRewardPerHa(_)
	return g_missionManager:getMissionTypeDataByName(MowbaleMission.NAME).rewardPerHa
end
function MowbaleMission.getMissionTypeName(_)
	return MowbaleMission.NAME
end
function MowbaleMission:validate()
	if MowbaleMission:superClass().validate(self) then
		return (self:getIsFinished() or MowbaleMission.isAvailableForField(self.field, self)) and true or false
	else
		return false
	end
end
function MowbaleMission.tryGenerateMission()
	local mowType = g_missionManager:getMissionTypeDataByName(MowbaleMission.NAME)	
	mowType.fruitTypeIndices[FruitType.GRASS] = true
	if MowbaleMission.canRun() then
		local field = g_fieldManager:getFieldForMission()
		if field == nil then
			return
		end
		if field.currentMission ~= nil then
			return
		end
		if not MowbaleMission.isAvailableForField(field, nil) then
			return
		end

		local ft = math.random()<0.5 and FillType.SILAGE or FillType.DRYGRASS_WINDROW
		local station, _ = HarvestMission.getSellingStationWithHighestPrice(ft)
		if not HarvestMission.isAvailableForSellingStation(station) then
			return
		end
		local mission = MowbaleMission.new(true, g_client ~= nil)
		if ft == FillType.SILAGE then  
			mission.description = g_i18n:getText("contract_field_mowbale_silage")
			mission.fillTypeIndex = ft
		end
		if mission:init(field, station) then
			mission:setDefaultEndDate()
			return mission
		end
		mission:delete()
	end
	return nil
end
function MowbaleMission.isAvailableForField(field, mission)
	-- mission nil: original call when generating missions
	-- else: 2nd call when upadting existing missions
	if mission == nil then
		local fieldState = field:getFieldState()
		if not fieldState.isValid then
			return false
		end
		local fruitIndex = fieldState.fruitTypeIndex
		if fruitIndex ~= FruitType.GRASS then
			return false
		end
		local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
		if not fruitDesc:getIsHarvestable(fieldState.growthState) then
			return false
		end
	end
	return true
end
function MowbaleMission.canRun()
	local type = g_missionManager:getMissionTypeDataByName(MowbaleMission.NAME)
	if type.numInstances >= type.maxNumInstances then
		return false
	else
		return not g_currentMission.growthSystem:getIsGrowingInProgress()
	end
end
-----------------------------------------------------------------------------
Mowbale = {}
local Mowbale_mt = Class(Mowbale)

function Mowbale:new(default)
	local self = {}
	setmetatable(self, Mowbale_mt)
	self.isServer = g_server ~= nil 
	self.isClient = g_dedicatedServerInfo == nil

	------------ allow mission bales ----------------------------------------
	Bale.loadBaleAttributesFromXML = Utils.overwrittenFunction(
	Bale.loadBaleAttributesFromXML, 
	function (self, superf, xmlFile)
		local ret = superf(self, xmlFile)
		local x,_,z = getWorldTranslation(self.nodeId)
		local m = g_missionManager:getMissionAtWorldPosition(x,z)
		if m ~= nil and m.type.name == "mowbaleMission" then
			debugPrint("** setting mission bale for object %d", self.nodeId)
			self:setIsMissionBale(true)
		end
	return ret
	end)
	g_missionManager:registerMissionType(MowbaleMission, MowbaleMission.NAME, 4)
	
	-- rewardPerHa for other mission types are loaded from map
	local mowType = g_missionManager:getMissionTypeDataByName(MowbaleMission.NAME)
	mowType.rewardPerHa = MowbaleMission.REWARD_PER_HA
	mowType.fruitTypeIndices = {}
	mowType.failureCostFactor = 0.1
	mowType.failureCostOfTotal = 0.95
	addConsoleCommand("mbMission", "Force generating a mowbale mission for given field", "consoleGenMission", self, "fieldId")
	return self 
end
function Mowbale:consoleGenMission(fieldNo)
	-- generate mowbale mission on given field
	return g_missionManager:consoleGenerateMission(fieldNo, "mowbaleMission")
end

g_mowbaleMissions = Mowbale:new()
