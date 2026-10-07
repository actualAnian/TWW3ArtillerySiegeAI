local TICKS_BEFORE_ARTILLERY_GROUP_CHECK = 30

---@class ArtilleryGroup
---@field artillery_units ArtilleryUnit[]
---@field target battle_building|nil group has no target until one is assigned or after ClearTarget
---@field ticks_since_target_change number
ArtilleryGroup = {}
ArtilleryGroup.__index = ArtilleryGroup

---@param artillery_units ArtilleryUnit[]
---@return ArtilleryGroup
function ArtilleryGroup:new(artillery_units)
    local group = setmetatable({}, ArtilleryGroup)
    group.artillery_units = artillery_units
    group.ticks_since_target_change = 0
    return group
end

---@return number
function ArtilleryGroup:UnitCount()
    return #self.artillery_units
end

---@return number, number
function ArtilleryGroup:AveragePosition()
    local total_x, total_z, position_count = 0, 0, 0
    for _, artillery_unit in ipairs(self.artillery_units) do
        local unit_x, unit_z = artillery_unit:Position()
        if unit_x and unit_z then
            total_x = total_x + unit_x
            total_z = total_z + unit_z
            position_count = position_count + 1
        end
    end
    if position_count == 0 then return 0, 0 end
    return total_x / position_count, total_z / position_count
end

---@param artillery_unit ArtilleryUnit
---@return boolean
function ArtilleryGroup:ContainsUnit(artillery_unit)
    for _, member in ipairs(self.artillery_units) do
        if member == artillery_unit then return true end
    end
    return false
end

---@return boolean
function ArtilleryGroup:IsAnyGroupUnitIdle()
    for _, artillery_unit in ipairs(self.artillery_units) do
        if artillery_unit:IsIdle() then return true end
    end
    return false
end

---@return boolean
function ArtilleryGroup:AreAllUnitsIdle()
    for _, artillery_unit in ipairs(self.artillery_units) do
        if not artillery_unit:IsIdle() then return false end
    end
    return true
end

---@return boolean
function ArtilleryGroup:AreAllUnitsReady()
    for _, artillery_unit in ipairs(self.artillery_units) do
        if not artillery_unit:IsReady() then return false end
    end
    return true
end

---@return boolean
function ArtilleryGroup:IsAnyUnitRepositioning()
    for _, artillery_unit in ipairs(self.artillery_units) do
        if artillery_unit:IsRepositioning() then return true end
    end
    return false
end

function ArtilleryGroup:CheckAndStartUnitReposition()
    for _, artillery_unit in ipairs(self.artillery_units) do
        artillery_unit:CheckAndStartUnitReposition(self.target)
    end
end

function ArtilleryGroup:ResetRepositioning()
    for _, artillery_unit in ipairs(self.artillery_units) do
        artillery_unit:ResetRepositioning()
    end
end

---@param target battle_building
function ArtilleryGroup:SetTarget(target)
    if self.target == target then return end
    self.target = target
    self.ticks_since_target_change = 0
    for _, artillery_unit in ipairs(self.artillery_units) do
        artillery_unit:SetTarget(target)
    end
    self:ResetRepositioning()
end

function ArtilleryGroup:GiveAttackOrderToNonRepositioningUnits()
    for _, artillery_unit in ipairs(self.artillery_units) do
        if artillery_unit:IsReady() then
            artillery_unit:Attack()
        end
    end
end

function ArtilleryGroup:ClearTarget()
    self.target = nil
    self.ticks_since_target_change = 0
        for _, artillery_unit in ipairs(self.artillery_units) do
            artillery_unit:ClearTarget()
        end
    self:ResetRepositioning()
end

---@param previous ArtilleryGroup
function ArtilleryGroup:InheritStateFrom(previous)
    self.target = previous.target
    self.ticks_since_target_change = previous.ticks_since_target_change
end

---@param target battle_building -- giving target as a parameter to show this method will only run when target is set
function ArtilleryGroup:TargetSetTick(target)
    if self.ticks_since_target_change == 1 then
        self:CheckAndStartUnitReposition()
    end
    if self:IsAnyUnitRepositioning() then return end
    if self.ticks_since_target_change >= TICKS_BEFORE_ARTILLERY_GROUP_CHECK then
        if target:health() == 1 then
            output_log_anian(LOGS, "not shooting target")
            -- if giving orders to target an unbreakable building, the order to attack building is consumed and lost. then if the vanilla ai sees an enemy unit it will target it, instead of the building. so unit won't be idle, yet the target building will be untargetable
            if self:AreAllUnitsIdle() or self:AreAllUnitsReady() then
                mark_untargetable(target)
            end
        end

    end
end

function ArtilleryGroup:ChooseNextTarget()
    self:ClearTarget()
    local group_x, group_z = self:AveragePosition()
        local target_building = choose_next_target(group_x, group_z)
        if target_building then
            self:SetTarget(target_building)
            output_log_anian(LOGS, "group " ..tostring(self.__index) .." attacking: " ..tostring(target_building:name() .."with health: " ..tostring(target_building:health())))
        end
end
function ArtilleryGroup:HandleTargetSelection()
    self.ticks_since_target_change = self.ticks_since_target_change + 1
    if self.target then
        self:TargetSetTick(self.target)
    end
    if not self.target
        or self.target and self.target:health() <=0
        then
            self:ChooseNextTarget()
    end
    if not self.target then
        for _, artillery_unit in ipairs(self.artillery_units) do
            anian_release_script_unit_control(artillery_unit.script_unit)
            output_log_anian(VERBOSE_LOGS, artillery_unit:Name() .. " no valid target, ending script control")
        end
        return
    end
    self:GiveAttackOrderToNonRepositioningUnits()
end
