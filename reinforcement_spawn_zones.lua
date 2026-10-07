local SPAWN_ZONE_GROUP_DISTANCE = 50
local SPAWN_ZONE_TICK_INTERVAL_MS = 2000
local SPAWN_ZONE_CALLBACK_NAME = "anian_spawn_zones"

---@class SpawnZoneCandidate
---@field zone battle_spawn_zone
---@field x number
---@field z number

---@class UnitPosition
---@field x number
---@field z number

---@type table<battle_reinforcement_army, number>
local assigned_zone_by_army = {}


---@return SpawnZoneCandidate[]
local function collect_candidate_spawn_zones(ai_alliance)
    local reinforcements = bm:reinforcements()
    if not reinforcements then return {} end

    local usable_zones = {}
    local all_zones = {}
    for index = 1, reinforcements:spawn_zone_count() do
        local zone = reinforcements:spawn_zone(index)
        if zone then
            local zone_x, zone_z = vector_to_coordinates(zone:position())
            if zone_x and zone_z then
                local candidate = {zone = zone, x = zone_x, z = zone_z}
                all_zones[#all_zones + 1] = candidate
                if zone:can_be_used_by_alliance(ai_alliance) then
                    usable_zones[#usable_zones + 1] = candidate
                end
            end
        end
    end

    output_log_anian(LOGS, "all zones: " ..#all_zones .." usable zones: " ..#usable_zones)
    if #usable_zones == 0 then return all_zones end
    return usable_zones
end

---@param ai_alliance battle_alliance
---@return battle_reinforcement_army[]
local function collect_ai_reinforcement_armies(ai_alliance)
    local reinforcements = bm:reinforcements()
    if not reinforcements then return {} end

    local amount = reinforcements:reinforcement_army_count();
    output_log_anian(LOGS, "ai reinforcement armies amount: " ..amount)
    local reinforcement_armies = {}
    for army_index = 1, amount do
        local reinforcement_army = reinforcements:reinforcement_army(army_index)
        if ai_alliance == reinforcement_army:army():alliance() then
            reinforcement_armies[#reinforcement_armies + 1] = reinforcement_army
        end
    end
    return reinforcement_armies
end

---@return UnitPosition[]
local function collect_first_army_positions(ai_alliance)
    local army_list = ai_alliance:armies()
    if not army_list or army_list:count() == 0 then return {} end

    local army = army_list:item(1)
    if not army then return {} end

    local positions = {}
    -- local unit_list = army:units()
    -- if not unit_list then return positions end

    -- for unit_index = 1, unit_list:count() do
    --     local unit = unit_list:item(unit_index)
    --     if unit then
    --         local unit_x, unit_z = vector_to_coordinates(unit:position())
    --         if unit_x and unit_z then
    --             positions[#positions + 1] = {x = unit_x, z = unit_z}
    --         end
    --     end
    local vehicles_collection = bm:assault_equipment()
    -- end

    for i = 1, vehicles_collection:vehicle_count() do
    local equipment = vehicles_collection:vehicle_item(i)
        positions[#positions + 1] = {x = equipment:position():get_x(), z = equipment:position():get_z()}
    end
    return positions
end

---@param positions UnitPosition[]
---@return UnitPosition[][]
local function group_positions_by_distance(positions)
    local groups = {}
    local assigned = {}

    for _, position in ipairs(positions) do
        if not assigned[position] then
            local members = {position}
            assigned[position] = true

            local member_index = 1
            while member_index <= #members do
                local member = members[member_index]
                for _, candidate in ipairs(positions) do
                    if not assigned[candidate] and distance_between_points(member.x, member.z, candidate.x, candidate.z) < SPAWN_ZONE_GROUP_DISTANCE then
                        assigned[candidate] = true
                        members[#members + 1] = candidate
                    end
                end
                member_index = member_index + 1
            end
            groups[#groups + 1] = members
        end
    end
    return groups
end

---@param groups UnitPosition[][]
---@return number|nil, number|nil, number
local function centroid_of_largest_group(groups)
    local largest_group = nil
    for _, group in ipairs(groups) do
        if not largest_group or #group > #largest_group then
            largest_group = group
        end
    end
    if not largest_group then return nil, nil , 0 end

    local total_x, total_z = 0, 0
    for _, member in ipairs(largest_group) do
        total_x = total_x + member.x
        total_z = total_z + member.z
    end
    return total_x / #largest_group, total_z / #largest_group, #largest_group
end

---@param centroid_x number
---@param centroid_z number
---@param remaining_candidates SpawnZoneCandidate[] consumed as armies are matched
---@param reinforcement_armies battle_reinforcement_army[]
local function assign_nearest_spawn_zones(centroid_x, centroid_z, remaining_candidates, reinforcement_armies)
    for _, reinforcement_army in ipairs(reinforcement_armies) do
        if assigned_zone_by_army[reinforcement_army] == nil then
            local closest_index = nil
            local closest_distance = ANIAN_MAX_INT_VALUE
            for candidate_index, candidate in ipairs(remaining_candidates) do
                local candidate_distance = distance_between_points(centroid_x, centroid_z, candidate.x, candidate.z)
                if candidate_distance < closest_distance then
                    closest_distance = candidate_distance
                    closest_index = candidate_index
                end
            end
            if not closest_index then return end

            local closest_zone = table.remove(remaining_candidates, closest_index)
            reinforcement_army:assign_spawn_zone(closest_zone.zone)
            assigned_zone_by_army[reinforcement_army] = closest_zone.zone:unique_id()
            output_log_anian(LOGS, "assigned reinforcement army to spawn zone " .. tostring(closest_zone.zone:unique_id()) .. " at distance " .. tostring(math.floor(closest_distance)) .. " x: " .. tostring(closest_zone.zone:position():get_x()) .. " z: " .. tostring(closest_zone.zone:position():get_z()))
            closest_zone.zone:highlight()
        end
    end
end

local function assign_spawn_zones_tick()
    local ai_alliance = bm:get_non_player_alliance()
    if not ai_alliance then return end

    local reinforcement_armies = collect_ai_reinforcement_armies(ai_alliance)
    if #reinforcement_armies == 0 then return end

    local candidates = collect_candidate_spawn_zones(ai_alliance)
    if #candidates == 0 then
        output_log_anian(LOGS, "no spawn zones available for reinforcement assignment")
        return
    end

    local positions = collect_first_army_positions(ai_alliance)
    output_log_anian(LOGS, "printing unit positions")
    for i, object in ipairs(positions) do
        output_log_anian(LOGS, "x: " ..object.x .." z: "..object.z)
    end
    local centroid_x, centroid_z, most_siege_equipment = centroid_of_largest_group(group_positions_by_distance(positions))
    if not centroid_x or not centroid_z then
        output_log_anian(LOGS, "no positioned units in first army, skipping spawn zone assignment")
        return
    end

    output_log_anian(LOGS, "center of biggest army: " ..centroid_x .." " ..centroid_z)
    assign_nearest_spawn_zones(centroid_x, centroid_z, candidates, reinforcement_armies)
    bm:queue_advisor("enemy reinforcements will spawn next to army with: " ..most_siege_equipment .." siege equipments", 10, true, nil, nil, nil)
end

-- local function initialize()
--     output_log_anian(LOGS, "initialize reinforcement!!!")
--     local ok, err = pcall(function()
--         assigned_zone_by_army = {}
--         if not bm then return end
--         if bm:player_is_attacker() then return end
--         assign_spawn_zones_tick()
--         bm:repeat_callback(function()
--             local tick_ok, tick_err = pcall(assign_spawn_zones_tick)
--             if not tick_ok then output_log_anian(LOGS, "ERROR IN SPAWN ZONES TICK: " .. tostring(tick_err)) end
--         end, SPAWN_ZONE_TICK_INTERVAL_MS, SPAWN_ZONE_CALLBACK_NAME)
--     end)
--     if not ok then output_log_anian(LOGS, "ERROR IN SPAWN ZONES INITIALIZE: " .. tostring(err)) end
-- end

-- initialize()
bm:register_phase_change_callback(
    "Deployed",
    function()
        output_log_anian(LOGS, "deployed")
        assign_spawn_zones_tick()
    end
)
bm:register_phase_change_callback(
    "Deployment",
    function()
        output_log_anian(LOGS, "deployment")
        assign_spawn_zones_tick()
    end
)
-- bm:register_phase_change_callback(
--     "Startup",
--     function()
--         output_log_anian(LOGS, "startup")
--         assign_spawn_zones_tick()
--     end
-- )
-- bm:register_phase_change_callback(
--     "PrebattleWeather",
--     function()
--         output_log_anian(LOGS, "PrebattleWeather")
--         assign_spawn_zones_tick()
--     end
-- )
-- bm:register_phase_change_callback(
--     "PrebattleCinematic",
--     function()
--         output_log_anian(LOGS, "PrebattleCinematic")
--         assign_spawn_zones_tick()
--     end
-- )