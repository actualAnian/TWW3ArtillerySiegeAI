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

local active_targets = {}

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

local function should_attack_buildings(unit)
    output_log(VERBOSE_LOGS, "checking if should attack building")
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

local function choose_next_target(unit_position)
    -- local building_list = bm:buildings()
    local building_list = bm:get_fort_tower_buildings()

    output_log(VERBOSE_LOGS, "buildings list get: " ..tostring(not building_list))
    if not building_list then return nil end

    -- local building_count = building_list:count()
    local building_count = #building_list
    output_log(VERBOSE_LOGS, "building found: " ..tostring(building_count))
    if not building_count or building_count <= 0 then return nil end

    local unit_x, unit_z = vector_to_coordinates(unit_position)
    if not unit_x or not unit_z then return nil end

    local closest_building = nil
    local closest_distance =999999999
    -- local ok, err = pcall(function()
    --     for index, building in pairs(building_list) do
    --         output_log(LOGS, "index: " .. tostring(index))
    --         output_log(LOGS, "building: " .. tostring(building:name()))
    --     end
    -- end)
    -- output_log(LOGS, "pairs finished: " .. tostring(ok))
    -- output_log(LOGS, "error: " .. tostring(err))
local ok, err = pcall(function()
    for index, building in pairs(building_list) do
    -- for building_index = 1, building_count do
        -- local building = building_list:item(building_index)
        -- local building = building_list[building_index]

        if string.find(tostring(building:name()), "wall_tower") then
            local is_wall = building:is_fort_wall()
            local is_tower = building:is_fort_tower()

            if is_wall or is_tower then
                local health = building:health()
                output_log(VERBOSE_LOGS, "health: " ..tostring(health))
                if type(health) == "number" and health > NEARLY_DESTROYED_THRESHOLD then
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
end)
output_log(LOGS, "pairs finished: " .. tostring(ok))
output_log(LOGS, "error: " .. tostring(err))
    if closest_building then
        output_log(VERBOSE_LOGS, "returning building: " ..tostring(closest_building:name()))
    end
    output_log(VERBOSE_LOGS, "returning from choose target method")
    return closest_building
end

local function get_ai_alliance()
    return bm:alliances():item(2)
    -- local alliance_list = bm:alliances()
    -- local player_alliance_index = bm:local_alliance()
    -- local alliance_count = alliance_list:count()
    -- output_log(VERBOSE_LOGS, "player alliance: " ..tostring(player_alliance_index))

    -- for alliance_index = 1, alliance_count do
    --     local alliance = alliance_list:item(alliance_index)
    --     if alliance then
    --         local alliance_index_value = safe_call(alliance, "index")
    --         if alliance_index_value ~= player_alliance_index then
    --             output_log(VERBOSE_LOGS, "ai alliance: " ..tostring(alliance_index_value))
    --             return alliance
    --         end
    --     end
    -- end
    -- return nil
end

local function find_unit_controller(unit)
    local army = unit:army()
    if not army then return nil end

    local unit_controllers = safe_call(army, "unit_controllers")
    if not unit_controllers then return nil end

    local controller_count = unit_controllers:count()
    if not controller_count then return nil end

    for controller_index = 1, controller_count do
        local unit_controller = unit_controllers:item(controller_index)
        if unit_controller then
            local controlled_units = safe_call(unit_controller, "units")
            if controlled_units then
                for controlled_unit_index = 1, controlled_units:count() do
                    if controlled_units:item(controlled_unit_index) == unit then
                        return unit_controller
                    end
                end
            end
        end
    end

    return nil
end

local function create_unit_controller_for_unit(unit)
    local army = unit:army()
    if not army then return nil end

    local new_unit_controller = safe_call(army, "create_unit_controller")
    if not new_unit_controller then return nil end

    safe_call(new_unit_controller, "add_units", unit)
    return new_unit_controller
end

local function issue_attack_building_order(unit, target_building)
    local unit_controller = find_unit_controller(unit)
    if not unit_controller then
        unit_controller = create_unit_controller_for_unit(unit)
    end
    if not unit_controller then
        output_log(VERBOSE_LOGS, "failed to get/create unitcontroller for " .. unit_name(unit))
        return false
    end

    if type(unit_controller.attack_building) ~= "function" then
        output_log(VERBOSE_LOGS, "attack_building not available on unitcontroller")
        return false
    end

    local success = pcall(function() unit_controller:attack_building(target_building, 1, false) end)
    if success then
        output_log(VERBOSE_LOGS, "issued attack_building to " .. unit_name(unit))
    else
        output_log(VERBOSE_LOGS, "attack_building failed for " .. unit_name(unit))
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
                    output_log(VERBOSE_LOGS, "found unit with name:" ..tostring(unit:unique_ui_id()))
                    if unit and unit:is_artillery() and not unit:is_routing() and not unit:is_script_controlled() then
                    output_log(VERBOSE_LOGS, "artillery:" ..tostring(unit:unique_ui_id()))
                        artillery_units[#artillery_units + 1] = unit
                    end
                end
            end
        end
    end
    return artillery_units
end

local function tick()
    local ok, err = pcall(function()
        output_log(VERBOSE_LOGS, "tick start")
        if not bm then return end

        local is_siege = bm:is_siege_battle()
        if not is_siege then return end


        local artillery_units = collect_ai_artillery_units()
        output_log(VERBOSE_LOGS, "tick: " .. #artillery_units .. " artillery units found")
        if #artillery_units == 0 then return end


        for _, unit in ipairs(artillery_units) do
            if should_attack_buildings(unit) then
                local unit_position = unit:position()
                local target_building = choose_next_target(unit_position)
                if target_building then
                    local current_target = active_targets[tostring(unit)]
                    if current_target ~= tostring(target_building) then
                        output_log(VERBOSE_LOGS, unit_name(unit) .. " -> attacking building")
                        issue_attack_building_order(unit, target_building)
                        active_targets[tostring(unit)] = tostring(target_building)
                    end
                else
                    output_log(VERBOSE_LOGS, unit_name(unit) .. " no valid target found")
                end
            else
                output_log(VERBOSE_LOGS, unit_name(unit) .. " ammo depleted, skipping")
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
