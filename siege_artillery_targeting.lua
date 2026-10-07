-- SCORING
local DISTANCE_SCORE_SCALE = 100
local MAX_DISTANCE = 1000
local HEALTH_SCORE_SCALE = 10
local FRIENDLY_ON_WALL_SCORE = -100000
local ENEMY_ON_WALL_SCORE = 10
local IS_TOWER_BONUS = 4
local TOWER_BELONGING_TO_ENEMY_BONUS = 5
-- END SCORING

local UNIT_ON_WALL_DISTANCE = 10
local float_epsilon = 0.0001

---@class UntargetableEntry
---@field x number
---@field z number

---@class ScoredBuilding
---@field building battle_building
---@field score number

---@param distance number
---@return number
function fromDistance(distance)
    return DISTANCE_SCORE_SCALE - DISTANCE_SCORE_SCALE *  math.min(MAX_DISTANCE, distance) / MAX_DISTANCE
end

---@param health number
---@return number
function fromHealth(health)
    return HEALTH_SCORE_SCALE - HEALTH_SCORE_SCALE * health
end

---@param building battle_building
---@return number
function fromTowerBelongingToPlayer(building)
    if building:alliance_owner_id() == bm:get_player_alliance_num() then return TOWER_BELONGING_TO_ENEMY_BONUS end
    return 0
end

---@param x number
---@param z number
---@return boolean
function is_untargetable(x, z)
    for _, entry in ipairs(siege_state.untargetable) do
        local matches_x = math.abs(entry.x - x) <= float_epsilon
        local matches_z = math.abs(entry.z - z) <= float_epsilon
        if matches_x and matches_z then return true end
    end
    return false
end

---@param building battle_building
function mark_untargetable(building)
    local building_x, building_z = vector_to_coordinates(building:central_position())
    if not building_x or not building_z then return end
    if is_untargetable(building_x, building_z) then return end
    siege_state.untargetable[#siege_state.untargetable + 1] = { x = building_x, z = building_z }
    output_log_anian(VERBOSE_LOGS, "marking untargetable: " .. tostring(building:name()))
end

---@param alliance battle_alliance|nil guards alliances missing on some battle types
---@return battle_unit[]
function get_alliance_units(alliance)
    local units = {}
    if not alliance then return units end

    local army_list = alliance:armies()
    for army_index = 1, army_list:count() do
        local unit_list = army_list:item(army_index):units()
        for unit_index = 1, unit_list:count() do
            units[#units + 1] = unit_list:item(unit_index)
        end
    end
    return units
end

---@param wall battle_building
---@param alliance battle_alliance|nil guards alliances missing on some battle types
---@return boolean
function has_unit_on_top(wall, alliance)
    local wall_position = wall:central_position()
    if not wall_position then return false end
    local wall_x, wall_z = wall_position:get_x(), wall_position:get_z()
    local units_on_wall = 0
    for _, unit in pairs(get_alliance_units(alliance)) do
        if unit:is_on_top_of_platform() then
            local unit_position = unit:position()
            if unit_position then
                local unit_x, unit_z = unit_position:get_x(), unit_position:get_z()
                local is_on_wall = distance_between_points(wall_x, wall_z, unit_x, unit_z) <= UNIT_ON_WALL_DISTANCE
                if is_on_wall then
                    units_on_wall = units_on_wall + 1
                end
            end
        end
    end
    local has_units_on_wall = units_on_wall > 0
    return has_units_on_wall
end

---@param wall battle_building
---@return number
local function on_wall_score(wall)
    if has_unit_on_top(wall, bm:get_non_player_alliance()) then return FRIENDLY_ON_WALL_SCORE end
    if has_unit_on_top(wall, bm:get_player_alliance()) then return ENEMY_ON_WALL_SCORE end
    return 0
end

---@param scored_buildings ScoredBuilding[]
---@param unit_x number
---@param unit_z number
function score_fort_towers(scored_buildings, unit_x, unit_z)
    local building_list = bm:get_fort_tower_buildings()
    if not building_list then return end

    local building_count = #building_list
    if building_count <= 0 then return end

    local ai_alliance_id = bm:get_non_player_alliance_num()

    for _, building in pairs(building_list) do
        if building:category() == "fort_tower"
            and building:health() > 0
            and building:alliance_owner_id() ~= ai_alliance_id then
            local building_x, building_z = vector_to_coordinates(building:central_position())
            if is_untargetable(building_x, building_z) then
                -- output_log_anian(VERBOSE_LOGS, "skipping untargetable: " .. tostring(building:name()))
            elseif building_x and building_z then
                local distance = distance_between_points(unit_x, unit_z, building_x, building_z)
                scored_buildings[#scored_buildings + 1] = {
                    building = building,
                    score = fromDistance(distance) + fromHealth(building:health()) + IS_TOWER_BONUS + fromTowerBelongingToPlayer(building),
                }
                local position = building:position()
                -- output_log_anian(VERBOSE_LOGS, "scoring: " .. tostring(building:name()) .. " at: " ..tostring(position:get_x() .." + " ..tostring(position:get_y())))
                -- output_log_anian(VERBOSE_LOGS, "score- from distance: " .. tostring(fromDistance(distance)) .. " from health: " ..tostring(fromHealth(building:health())))
            end
        end
    end
end

---@return battle_vector[]
local function collect_wall_positions()
    local positions = {}
    local building_list = bm:get_fort_wall_buildings()
    if not building_list then return positions end

    for _, building in pairs(building_list) do
        if building:health() > 0 then
            local position = building:central_position()
            if position then positions[#positions + 1] = position end
        end
    end
    return positions
end

---@return battle_vector[]
function get_wall_positions()
    if not siege_state.wall_positions then
        siege_state.wall_positions = collect_wall_positions()
    end
    return siege_state.wall_positions
end

---@param scored_buildings ScoredBuilding[]
---@param unit_x number
---@param unit_z number
function score_fort_walls(scored_buildings, unit_x, unit_z)
    local building_list = bm:get_fort_wall_buildings()
    if not building_list then return end

    local building_count = #building_list
    if building_count <= 0 then return end

    local ai_alliance_id = bm:get_non_player_alliance_num()

    for _, building in pairs(building_list) do
        if building:category() == "fort_wall"
            and string.find(building:name(), "straight")
            and building:health() > 0
            and building:alliance_owner_id() ~= ai_alliance_id then
            local building_x, building_z = vector_to_coordinates(building:central_position())
            if building_x and building_z and is_untargetable(building_x, building_z) then
                output_log_anian(VERBOSE_LOGS, "skipping untargetable: " .. tostring(building:name()))
            elseif building_x and building_z then
                local distance = distance_between_points(unit_x, unit_z, building_x, building_z)
                local units_score = on_wall_score(building)

                scored_buildings[#scored_buildings + 1] = {
                    building = building,
                    score = fromDistance(distance) + fromHealth(building:health()) + units_score,
                }
                local position = building:position()
                -- output_log_anian(VERBOSE_LOGS, "scoring wall: " .. tostring(building:name()) .. " at posX: " .. tostring(position:get_x()) .. " posZ: " .. tostring(position:get_z()))
                -- output_log_anian(VERBOSE_LOGS, "score- from distance: " .. tostring(fromDistance(distance)) .. " from health: " .. tostring(fromHealth(building:health())) .. " from units: " .. tostring(units_score))
            end
        end
    end
end

---@param unit_x number
---@param unit_z number
---@return battle_building|nil no scorable building left
function choose_next_target(unit_x, unit_z)
    local scored_buildings = {}
    score_fort_towers(scored_buildings, unit_x, unit_z)
    score_fort_walls(scored_buildings, unit_x, unit_z)

    local best_building, best_score = nil, nil
    for _, scored_building in ipairs(scored_buildings) do
        if not best_score or scored_building.score > best_score then
            best_building = scored_building.building
            best_score = scored_building.score
        end
    end

    if best_building then
        output_log_anian(LOGS, "returning building: " .. tostring(best_building:name()) .. " score: " .. tostring(best_score))
    end
    return best_building
end
