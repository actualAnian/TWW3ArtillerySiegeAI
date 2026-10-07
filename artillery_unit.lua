local FOREST_GROUND_TYPE = "forest"
local LINE_SAMPLE_STEP_M = 10
local FOREST_CLEAR_DISTANCE_M = 200
local TERRAIN_CLEARANCE_M = 2
local ARTILLERY_HALF_WIDTH_M = 3
local WALL_CLEAR_DISTANCE_M = 300
local UNIT_CLEAR_DISTANCE_M = 5
local REPOSITION_MAX_DISTANCE_M = 60
local REPOSITION_RING_STEP_M = 10
local REPOSITION_BEARING_COUNT = 16
local REPOSITION_MAX_ATTEMPTS = 3
local REPOSITION_ARRIVAL_DISTANCE_M = 2
local REPOSITION_TIMEOUT_TICKS = 30

---@param from_x number
---@param from_z number
---@param to_x number
---@param to_z number
---@return number side_x
---@return number side_z
local function side_line_offset(from_x, from_z, to_x, to_z)
    local distance = distance_between_points(from_x, from_z, to_x, to_z)
    if distance <= 0 then
        return 0, 0
    end
    return (from_z - to_z) / distance * ARTILLERY_HALF_WIDTH_M,
           (to_x - from_x) / distance * ARTILLERY_HALF_WIDTH_M
end

---@param from_x number
---@param from_z number
---@param to_x number
---@param to_z number
---@return boolean
local function line_has_forest(from_x, from_z, to_x, to_z)
    local distance = distance_between_points(from_x, from_z, to_x, to_z)
    if distance <= 0 then
        return bm:ground_type(battle_vector:new(from_x, 0, from_z)) == FOREST_GROUND_TYPE
    end

    local sample_count = math.floor(math.min(distance, FOREST_CLEAR_DISTANCE_M) / LINE_SAMPLE_STEP_M)
    for sample_index = 0, sample_count do
        local ratio = sample_index * LINE_SAMPLE_STEP_M / distance
        local sample_x = from_x + (to_x - from_x) * ratio
        local sample_z = from_z + (to_z - from_z) * ratio
        if bm:ground_type(battle_vector:new(sample_x, 0, sample_z)) == FOREST_GROUND_TYPE then
            return true
        end
    end
    return false
end

---@param from_x number
---@param from_z number
---@param to_x number
---@param to_z number
---@return boolean
local function has_forest_on_line(from_x, from_z, to_x, to_z)
    local side_x, side_z = side_line_offset(from_x, from_z, to_x, to_z)
    return line_has_forest(from_x, from_z, to_x, to_z)
        or line_has_forest(from_x + side_x, from_z + side_z, to_x, to_z)
        or line_has_forest(from_x - side_x, from_z - side_z, to_x, to_z)
end

---@param from_x number
---@param from_z number
---@param from_y number
---@param to_x number
---@param to_z number
---@param to_y number
---@return boolean
local function line_has_higher_terrain(from_x, from_z, from_y, to_x, to_z, to_y)
    local distance = distance_between_points(from_x, from_z, to_x, to_z)
    local sample_count = math.max(1, math.floor(distance / LINE_SAMPLE_STEP_M))
    for sample_index = 0, sample_count do
        local ratio = sample_index / sample_count
        local sample_x = from_x + (to_x - from_x) * ratio
        local sample_z = from_z + (to_z - from_z) * ratio
        local line_y = from_y + (to_y - from_y) * ratio
        if bm:get_terrain_height(sample_x, sample_z) > line_y + TERRAIN_CLEARANCE_M then
            return true
        end
    end
    return false
end

---@param from_x number
---@param from_z number
---@param from_y number
---@param to_x number
---@param to_z number
---@param to_y number
---@return boolean
local function has_higher_terrain_on_line(from_x, from_z, from_y, to_x, to_z, to_y)
    local side_x, side_z = side_line_offset(from_x, from_z, to_x, to_z)
    if not line_has_higher_terrain(from_x, from_z, from_y, to_x, to_z, to_y)
        and not line_has_higher_terrain(from_x + side_x, from_z + side_z, from_y, to_x, to_z, to_y)
        and not line_has_higher_terrain(from_x - side_x, from_z - side_z, from_y, to_x, to_z, to_y) then
        return false
    end
    output_log_anian(VERBOSE_LOGS, " can not shoot, terrain too high, unit at: " ..from_x .." " ..from_z)
    return true
end

---@param unit_position battle_vector
---@param target_position battle_vector
---@return boolean
local function line_is_clear(unit_position, target_position)
    local unit_x, unit_z = vector_to_coordinates(unit_position)
    local target_x, target_z = vector_to_coordinates(target_position)
    if has_forest_on_line(unit_x, unit_z, target_x, target_z) then 
        output_log_anian(VERBOSE_LOGS, "can not shoot, unit is in forest, unit at: " ..unit_x .." " ..unit_z)
        return false
    end
    return not has_higher_terrain_on_line(unit_position:get_x(), unit_position:get_z(), unit_position:get_y(), target_position:get_x(), target_position:get_z(), target_position:get_y())
end

---@param excluded_unit battle_unit
---@return battle_vector[]
local function collect_friendly_unit_positions(excluded_unit)
    local positions = {}
    for _, friendly_unit in ipairs(get_alliance_units(bm:get_non_player_alliance())) do
        if friendly_unit ~= excluded_unit and friendly_unit:number_of_men_alive() > 0 then
            local position = friendly_unit:position()
            if position then positions[#positions + 1] = position end
        end
    end
    return positions
end

---@class RepositionConditionContext
---@field wall_positions battle_vector[]
---@field friendly_unit_positions battle_vector[]

---@param x number
---@param z number
---@param condition_context RepositionConditionContext
---@return boolean
local function is_far_from_walls(x, z, condition_context)
    for _, wall_position in ipairs(condition_context.wall_positions) do
        if distance_between_points(x, z, wall_position:get_x(), wall_position:get_z()) <= WALL_CLEAR_DISTANCE_M then
            return false
        end
    end
    return true
end

---@param x number
---@param z number
---@param condition_context RepositionConditionContext
---@return boolean
local function is_far_from_friendly_unit(x, z, condition_context)
    for _, unit_position in ipairs(condition_context.friendly_unit_positions) do
        if distance_between_points(x, z, unit_position:get_x(), unit_position:get_z()) <= UNIT_CLEAR_DISTANCE_M then
            return false
        end
    end
    return true
end

local reposition_conditions = { is_far_from_walls, is_far_from_friendly_unit }

---@param unit battle_unit
---@param x number
---@param z number
---@param to_x number
---@param to_z number
---@param to_y number
---@return boolean
local function is_valid_firing_position(unit, x, z, to_x, to_z, to_y)
    if not unit:can_reach_position(battle_vector:new(x, 0, z)) then return false end
    local y = bm:get_terrain_height(x, z)
    return not has_forest_on_line(x, z, to_x, to_z)
        and not has_higher_terrain_on_line(x, z, y, to_x, to_z, to_y)
end

---@param unit battle_unit
---@param from_x number
---@param from_z number
---@param to_x number
---@param to_z number
---@param to_y number
---@return number|nil, number|nil first position passing every condition, otherwise the first position passing the earliest condition that any position passes
local function find_clear_line_position(unit, from_x, from_z, to_x, to_z, to_y)
    local condition_context = {
        wall_positions = get_wall_positions(),
        friendly_unit_positions = collect_friendly_unit_positions(unit),
    }
    local first_position_by_condition = {}

    for ring = REPOSITION_RING_STEP_M, REPOSITION_MAX_DISTANCE_M, REPOSITION_RING_STEP_M do
        for bearing_index = 0, REPOSITION_BEARING_COUNT - 1 do
            local angle = 2 * math.pi * bearing_index / REPOSITION_BEARING_COUNT
            local candidate_x = from_x + math.cos(angle) * ring
            local candidate_z = from_z + math.sin(angle) * ring
            if is_valid_firing_position(unit, candidate_x, candidate_z, to_x, to_z, to_y) then
                local passes_all_conditions = true
                for condition_index, condition in ipairs(reposition_conditions) do
                    if condition(candidate_x, candidate_z, condition_context) then
                        if not first_position_by_condition[condition_index] then
                            first_position_by_condition[condition_index] = { x = candidate_x, z = candidate_z }
                        end
                    else
                        passes_all_conditions = false
                    end
                end
                if passes_all_conditions then return candidate_x, candidate_z end
            end
        end
    end

    for condition_index = 1, #reposition_conditions do
        local fallback_position = first_position_by_condition[condition_index]
        if fallback_position then return fallback_position.x, fallback_position.z end
    end
    return nil
end

---@class ArtilleryUnit
---@field script_unit script_unit
---@field unit battle_unit
---@field destination {x: number, z: number, started_tick: number}|nil
---@field attempts number
---@field target battle_building
---@field is_attacking boolean
ArtilleryUnit = {}
ArtilleryUnit.__index = ArtilleryUnit

---@param script_unit_object script_unit
---@return ArtilleryUnit
function ArtilleryUnit:new(script_unit_object)
    local artillery_unit = setmetatable({}, ArtilleryUnit)
    artillery_unit.script_unit = script_unit_object
    artillery_unit.unit = script_unit_object.unit
    artillery_unit.destination = nil
    artillery_unit.attempts = 0
    return artillery_unit
end

---@return number, number
function ArtilleryUnit:Position()
    return vector_to_coordinates(self.unit:position())
end

---@return boolean
function ArtilleryUnit:IsIdle()
    return self.unit:is_idle()
end

---@return string
function ArtilleryUnit:Name()
    return self.unit:name()
end

---@return boolean
function ArtilleryUnit:IsRepositioning()
    return not self:CheckIfRepositioningComplete() and self:IsInTargetRange()
end

---@return boolean
function ArtilleryUnit:IsInTargetRange()
    local unit_x, unit_z = self:Position()
    local target_x, target_z = vector_to_coordinates(self.target:central_position())
    if not unit_x or not target_x then return false end
    return distance_between_points(unit_x, unit_z, target_x, target_z) <= self.unit:missile_range()
end

---@return boolean
function ArtilleryUnit:IsReady()
    if not self.target then return true end
    if self:IsRepositioning() then  return false end
    return self.attempts < REPOSITION_MAX_ATTEMPTS
end

---@param target battle_building
---@return boolean
function ArtilleryUnit:CheckAndStartUnitReposition(target)
    output_log_anian(VERBOSE_LOGS, self:Name() .. " start reposition")
    local unit_position = self.unit:position()
    local target_position = target:central_position()
    local unit_x, unit_z = vector_to_coordinates(unit_position)
    local target_x, target_z = vector_to_coordinates(target_position)
    if not unit_x or not target_x then return false end
    if line_is_clear(unit_position, target_position) then return false end

    self.attempts = self.attempts + 1
    local spot_x, spot_z = find_clear_line_position(self.unit, unit_x, unit_z, target_x, target_z, target_position:get_y())
    if not spot_x then
        output_log_anian(VERBOSE_LOGS, self:Name() .. " can not find a clear firing position")
        return false
    end

    output_log_anian(VERBOSE_LOGS, "repositioning to: " ..spot_x .." " ..spot_z)
    self.destination = { x = spot_x, z = spot_z, started_tick = siege_state.passed_ticks }
    self.script_unit.uc:goto_location(battle_vector:new(spot_x, 0, spot_z), false)
    return true
end

---@return boolean true once the gun reached the position it was repositioning to
function ArtilleryUnit:CheckIfRepositioningComplete()
    local destination = self.destination
    if not destination then return true end

    if siege_state.passed_ticks - destination.started_tick >= REPOSITION_TIMEOUT_TICKS then
        self.destination = nil
        output_log_anian(VERBOSE_LOGS, self:Name() .. " repositioning timed out")
        return false
    end

    local unit_x, unit_z = self:Position()
    if not unit_x then return false end
    if distance_between_points(unit_x, unit_z, destination.x, destination.z) <= REPOSITION_ARRIVAL_DISTANCE_M then
        self.destination = nil
        output_log_anian(VERBOSE_LOGS, self:Name() .. "repositioning completed, reached its firing position")
        return true
    end
    return false
end

function ArtilleryUnit:Attack()
    output_log_anian(LOGS, "order to attack given")
    self.script_unit.uc:attack_building(self.target, 1, false)
    is_attacking = true
end

---@param target battle_building
function ArtilleryUnit:SetTarget(target)
    self.target = target
end

function ArtilleryUnit:ClearTarget()
    self.target = nil
end

function ArtilleryUnit:ResetRepositioning()
    self.destination = nil
    self.attempts = 0
end
