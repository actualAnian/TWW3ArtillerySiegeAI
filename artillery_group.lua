local TICKS_BEFORE_ARTILLERY_GROUP_CHECK = 10
local TICKS_BEFORE_TARGET_SELECTION = 5

---@class ArtilleryGroup
---@field script_units script_unit[]
---@field target battle_building|nil group has no target until one is assigned or after ClearTarget
---@field ticks_since_target_change number
ArtilleryGroup = {}
ArtilleryGroup.__index = ArtilleryGroup

---@param script_units script_unit[]
---@return ArtilleryGroup
function ArtilleryGroup:new(script_units)
    local group = setmetatable({}, ArtilleryGroup)
    group.script_units = script_units
    group.ticks_since_target_change = 0
    return group
end

---@return number
function ArtilleryGroup:UnitCount()
    return #self.script_units
end

---@return number, number
function ArtilleryGroup:AveragePosition()
    local total_x, total_z, position_count = 0, 0, 0
    for _, script_unit_object in ipairs(self.script_units) do
        local unit_x, unit_z = vector_to_coordinates(script_unit_object.unit:position())
        if unit_x and unit_z then
            total_x = total_x + unit_x
            total_z = total_z + unit_z
            position_count = position_count + 1
        end
    end
    if position_count == 0 then return 0, 0 end
    return total_x / position_count, total_z / position_count
end

---@param script_unit_object script_unit
---@return boolean
function ArtilleryGroup:ContainsUnit(script_unit_object)
    for _, member in ipairs(self.script_units) do
        if member == script_unit_object then return true end
    end
    return false
end

---@return boolean
function ArtilleryGroup:IsAnyGroupUnitIdle()
    for _, script_unit_object in ipairs(self.script_units) do
        if script_unit_object.unit:is_idle() then return true end
    end
    return false
end

---@return boolean
function ArtilleryGroup:AreAllUnitsIdle()
    for _, script_unit_object in ipairs(self.script_units) do
        if not script_unit_object.unit:is_idle() then return false end
    end
    return true
end

function ArtilleryGroup:LogIdleUnits()
    for _, script_unit_object in ipairs(self.script_units) do
        if script_unit_object.unit:is_idle() then
            output_log_anian(VERBOSE_LOGS, "after new tick: " .. script_unit_object.unit:name() .. " is idle!!!")
        end
    end
end

---@param target battle_building
function ArtilleryGroup:SetTarget(target)
    if self.target == target then return end
    self.target = target
    self.ticks_since_target_change = 0
end
function ArtilleryGroup:GiveAttackOrderToUnits()
    if not self.target then output_log_anian(VERBOSE_LOGS, "ArtilleryGroup:GiveAttackOrderToUnits can not set attack order, target is null") return end
    for _, script_unit_object in ipairs(self.script_units) do
        local unit_controller = script_unit_object.uc
        unit_controller:attack_building(self.target, 1, false)
    end
end

function ArtilleryGroup:ClearTarget()
    self.target = nil
    self.ticks_since_target_change = 0
end

---@param previous ArtilleryGroup
function ArtilleryGroup:InheritStateFrom(previous)
    self.target = previous.target
    self.ticks_since_target_change = previous.ticks_since_target_change
end

function ArtilleryGroup:CheckIfGroupIdle()
    if not self.target then return end
        self.ticks_since_target_change = self.ticks_since_target_change + 1
        if self.ticks_since_target_change >= TICKS_BEFORE_ARTILLERY_GROUP_CHECK then
        if self:AreAllUnitsIdle() then
            mark_untargetable(self.target)
        end
    end
end


function ArtilleryGroup:HandleTargetSelection()
    self.ticks_since_target_change = self.ticks_since_target_change + 1
    if self.ticks_since_target_change >= TICKS_BEFORE_ARTILLERY_GROUP_CHECK then
        if self:AreAllUnitsIdle() then
            mark_untargetable(self.target)
        end
    end
    if not self.target
        or self.ticks_since_target_change >= TICKS_BEFORE_TARGET_SELECTION
        or self.target and self.target:health() <=0
        then
        local group_x, group_z = self:AveragePosition()
            local target_building = choose_next_target(group_x, group_z)
            if target_building then
                self:SetTarget(target_building)
                output_log_anian(LOGS, "group " ..tostring(self.__index) .." attacking: " ..tostring(target_building:name() .."with health: " ..tostring(target_building:health())))
            else
                self:ClearTarget()
                for _, script_unit_object in ipairs(self.script_units) do
                    anian_release_script_unit_control(script_unit_object)
                    output_log_anian(VERBOSE_LOGS, script_unit_object.unit:name() .. " no valid target found")
                end
            end
    end
    self:GiveAttackOrderToUnits()
end