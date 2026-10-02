LOGS = true
VERBOSE_LOGS = true

local LOG_PREFIX = "anian siege artillery ai: "

local function output_log(log_type, message)
    if not log_type then return end
    local full_message = LOG_PREFIX .. tostring(message)
    if bm and bm.out then
        pcall(function() bm:out(full_message) end)
    end
end

local AMMO_DEPLETED_THRESHOLD = 0.10
local NEARLY_DESTROYED_THRESHOLD = 0.05
local TICK_INTERVAL_MS = 2000
local ARTILLERY_GROUP_DISTANCE = 80
local RECALCULATE_GROUPS_NUM_TICKS = 5

local active_targets = {}
local artillery_groups = {}
local ticks_until_group_recalculation = 0
local script_unit_cache = {}

local function safe_call(object, method_name, ...)
    if not object then return nil, false end
    local method = object[method_name]
    if not method then return nil, false end
    local success, return_value = pcall(method, object, ...)
    if success then return return_value, true end
    return nil, false
end

local function unit_name(unit)
    if not unit then return "unknown" end
    local name = unit:name()
    if name and name ~= "" then return name end
    local unit_type = unit:type()
    if unit_type and unit_type ~= "" then return unit_type end
    local unique_id = unit:unique_ui_id()
    if unique_id then return "unit_" .. tostring(unique_id) end
    return "unknown_unit"
end

local function get_ammo_ratio(unit)
    local ammo_left = unit:ammo_left()
    local starting_ammo = unit:starting_ammo()
    if type(ammo_left) ~= "number" or type(starting_ammo) ~= "number" or starting_ammo <= 0 then
        return 0
    end
    return ammo_left / starting_ammo
end

local function can_attack_buildings(unit)
    return get_ammo_ratio(unit) > AMMO_DEPLETED_THRESHOLD
end

local function distance_between_points(first_x, first_z, second_x, second_z)
    local delta_x = second_x - first_x
    local delta_z = second_z - first_z
    return math.sqrt(delta_x * delta_x + delta_z * delta_z)
end

local function vector_to_coordinates(vector)
    if not vector then return nil, nil end
    local x_coordinate = vector:get_x()
    local z_coordinate = vector:get_z()
    return x_coordinate, z_coordinate
end

local function choose_next_target(unit_x, unit_z)
    -- local building_list = bm:buildings()
    local building_list = bm:get_fort_tower_buildings()
    -- output_log(VERBOSE_LOGS, "buildings list get: " ..tostring(not building_list))
    if not building_list then return nil end

    -- local building_count = building_list:count()
    local building_count = #building_list
    output_log(VERBOSE_LOGS, "building found: " ..tostring(building_count))
    if not building_count or building_count <= 0 then return nil end

    if type(unit_x) ~= "number" or type(unit_z) ~= "number" then return nil end

    local closest_building = nil
    local closest_distance = 999999999
    for index, building in pairs(building_list) do
        if string.find(tostring(building:name()), "wall_tower") then
            local is_wall = building:is_fort_wall()
            local is_tower = building:is_fort_tower()

            if is_wall or is_tower then
                if building:health() > 0 then
                    local central_position = building:central_position()
                    local building_x, building_z = vector_to_coordinates(central_position)
                    if building_x and building_z then
                        local distance = distance_between_points(unit_x, unit_z, building_x, building_z)
                        if distance < closest_distance then
                            closest_distance = distance
                            closest_building = building
                        end
                    end
                end
            end
        end
    end
    if closest_building then
        output_log(VERBOSE_LOGS, "returning building: " ..tostring(closest_building:name()))
    end
    return closest_building
end

local function get_ai_alliance()
    return bm:alliances():item(2)
end

local function issue_attack_building_order(script_unit_object, target_building)
    local unit_controller = script_unit_object.uc
    if not unit_controller then
        output_log(VERBOSE_LOGS, "no unitcontroller on " .. unit_name(script_unit_object.unit))
        return false
    end
    if type(unit_controller.attack_building) ~= "function" then
        output_log(VERBOSE_LOGS, "attack_building not available on unitcontroller")
        return false
    end

    unit_controller:take_control()
    local success = pcall(function() unit_controller:attack_building(target_building, 1, false) end)
    if success then
        output_log(VERBOSE_LOGS, "issued attack_building to " .. unit_name(script_unit_object.unit))
    else
        output_log(VERBOSE_LOGS, "attack_building failed for " .. unit_name(script_unit_object.unit))
    end
    return success
end

local function collect_ai_artillery_units()
    local artillery_units = {}
    local ai_alliance = get_ai_alliance()
    if not ai_alliance then return artillery_units end

    local army_list = safe_call(ai_alliance, "armies")
    if not army_list then return artillery_units end

    for army_index = 1, army_list:count() do
        local army = army_list:item(army_index)
        if army then
            local unit_list = safe_call(army, "units")
            if unit_list then
                for unit_index = 1, unit_list:count() do
                    local unit = unit_list:item(unit_index)
                    if unit and unit:is_artillery() and not unit:is_routing() then
                        artillery_units[#artillery_units + 1] = unit
                    end
                end
            end
        end
    end
    return artillery_units
end

local function release_script_unit_control(script_unit_object)
    if not active_targets[script_unit_object] then return end   -- only units we actually took control of
    pcall(function() script_unit_object:release_control() end)
    active_targets[script_unit_object] = nil
end

local function script_unit_for_unit(unit)
    local cached_script_unit = script_unit_cache[unit]
    if cached_script_unit then return cached_script_unit end

    local script_unit_object = bm:get_scriptunit_for_unit(unit)
        or script_unit:new_by_reference(unit:army(), unit:name())
    script_unit_cache[unit] = script_unit_object
    return script_unit_object
end

local function distance_between_units(first_script_unit, second_script_unit)
    local first_x, first_z = vector_to_coordinates(first_script_unit.unit:position())
    local second_x, second_z = vector_to_coordinates(second_script_unit.unit:position())
    if not first_x or not first_z or not second_x or not second_z then return math.huge end
    return distance_between_points(first_x, first_z, second_x, second_z)
end

local function average_group_position(group)
    local total_x, total_z, position_count = 0, 0, 0
    for _, script_unit_object in ipairs(group) do
        local unit_x, unit_z = vector_to_coordinates(script_unit_object.unit:position())
        if unit_x and unit_z then
            total_x = total_x + unit_x
            total_z = total_z + unit_z
            position_count = position_count + 1
        end
    end
    if position_count == 0 then return nil, nil end
    return total_x / position_count, total_z / position_count
end

local function collect_ready_artillery_units()
    local ready_script_units = {}
    for _, unit in ipairs(collect_ai_artillery_units()) do
        if can_attack_buildings(unit) then
            ready_script_units[#ready_script_units + 1] = script_unit_for_unit(unit)
        else
            release_script_unit_control(script_unit_for_unit(unit))
        end
    end
    return ready_script_units
end

local function build_artillery_groups(script_units)
    local groups = {}
    local assigned = {}

    for _, script_unit_object in ipairs(script_units) do
        if not assigned[script_unit_object] then
            local group = {script_unit_object}
            assigned[script_unit_object] = true

            local group_index = 1
            while group_index <= #group do
                local member = group[group_index]
                for _, candidate in ipairs(script_units) do
                    local distance = distance_between_units(member, candidate)
                    if not assigned[candidate] and distance < ARTILLERY_GROUP_DISTANCE then
                        output_log(VERBOSE_LOGS, "assigning: " ..member.unit:name() .." to group " ..tostring(#group + 1))
                        assigned[candidate] = true
                        group[#group + 1] = candidate
                    end
                end
                group_index = group_index + 1
            end

            groups[#groups + 1] = group
        end
    end

    return groups
end

local function prune_artillery_groups(groups, ready_set)
    local pruned_groups = {}
    for _, group in ipairs(groups) do
        local remaining_script_units = {}
        for _, script_unit_object in ipairs(group) do
            if ready_set[script_unit_object] then
                remaining_script_units[#remaining_script_units + 1] = script_unit_object
            end
        end
        if #remaining_script_units > 0 then
            pruned_groups[#pruned_groups + 1] = remaining_script_units
        end
    end
    return pruned_groups
end

local function tick()
    local ok, err = pcall(function()
        if not bm then return end

        local is_siege = bm:is_siege_battle()
        if not is_siege then return end

        local ready_script_units = collect_ready_artillery_units()
        output_log(VERBOSE_LOGS, "tick: " .. #ready_script_units .. " artillery units found")
        if #ready_script_units == 0 then
            artillery_groups = {}
            ticks_until_group_recalculation = 0
            return
        end

        if ticks_until_group_recalculation <= 0 then
            artillery_groups = build_artillery_groups(ready_script_units)
            ticks_until_group_recalculation = RECALCULATE_GROUPS_NUM_TICKS
        else
            local ready_set = {}
            for _, script_unit_object in ipairs(ready_script_units) do ready_set[script_unit_object] = true end
            output_log(VERBOSE_LOGS, "pruning artillery groups")
            artillery_groups = prune_artillery_groups(artillery_groups, ready_set)
            ticks_until_group_recalculation = ticks_until_group_recalculation - 1
        end

        for index, group in ipairs(artillery_groups) do
            output_log(VERBOSE_LOGS, "artillery group- " ..index .." amount: " ..tostring(#group))
            local group_x, group_z = average_group_position(group)
            local target_building = choose_next_target(group_x, group_z)
            if target_building then
                for _, script_unit_object in ipairs(group) do
                    local current_target = active_targets[script_unit_object]
                    -- if current_target ~= tostring(target_building) then
                    issue_attack_building_order(script_unit_object, target_building)
                    active_targets[script_unit_object] = tostring(target_building)
                    -- end
                end
                output_log(LOGS, "group :" ..tostring(index) .." attacking: " ..tostring(target_building:name()))
            else
                for _, script_unit_object in ipairs(group) do
                    release_script_unit_control(script_unit_object)
                    output_log(VERBOSE_LOGS, unit_name(script_unit_object.unit) .. " no valid target found")
                end
            end
        end
    end)
    if not ok then output_log(LOGS, "ERROR IN TICK: " .. tostring(err)) end
end

local function initialize()
    -- for some reason the logs are not showing when in this method
    if bm then
        local player_is_attacker = bm:player_is_attacker() 
        if player_is_attacker then
            -- output_log(LOGS, "not player attacker, returning")
            return
         end
        -- output_log(LOGS, "battle manager available, registering tick callback")
        bm:repeat_callback(function() tick() end, TICK_INTERVAL_MS)

        -- else
    --     output_log(LOGS, "battle manager not available, waiting for battle start")
    --     core:add_listener(
    --         "ArtillerySiegeAI",
    --         "BattleStarted",
    --         true,
    --         function()
    --             bm = get_bm()
    --             if bm then
    --                 output_log(LOGS, "battle started, registering tick callback")
    --                 bm:repeat_callback(function() tick() end, TICK_INTERVAL_MS)
    --             else
    --                 output_log(LOGS, "failed to get battle manager after battle start")
    --             end
    --         end,
    --         true
    --     )
    end
end

initialize()
