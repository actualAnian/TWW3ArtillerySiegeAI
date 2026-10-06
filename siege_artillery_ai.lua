LOGS = true
VERBOSE_LOGS = true

local LOG_PREFIX = "anian siege artillery ai: "
local LOG_FILE_NAME = "siege_artillery_ai.log"

---@type file*|nil
local log_file = nil
local log_open_attempted = false

---@return string
local function log_timestamp()
    if not os or not os.date then return "" end
    return "[" .. os.date("%H:%M:%S") .. "] "
end

local function close_log_file()
    if not log_file then return end
    pcall(function() log_file:close() end)
    log_file = nil
end

local function open_log_file()
    if log_open_attempted then return end
    log_open_attempted = true
    if not io or not io.open then return end
    local opened = pcall(function()
        log_file = io.open(LOG_FILE_NAME, "w")
    end)
    if not opened then log_file = nil end
end

---@param full_message string
local function write_to_script_log(full_message)
    if not bm or not bm.out then return end
    pcall(function() bm:out(full_message) end)
end

---@param full_message string
local function write_log_line(full_message)
    open_log_file()
    if not log_file then
        write_to_script_log(full_message)
        return
    end
    local line = log_timestamp() .. full_message .. "\n"
    local written, write_result = pcall(function() return log_file:write(line) end)
    if not written or not write_result then
        close_log_file()
        write_to_script_log(full_message)
        return
    end
    pcall(function() log_file:flush() end)
end

---@param log_type boolean
---@param message string
function output_log_anian(log_type, message)
    if not log_type then return end
    write_log_line(LOG_PREFIX .. tostring(message))
end

local AMMO_DEPLETED_THRESHOLD = 0.10
local TICK_INTERVAL_MS = 2000
local ARTILLERY_GROUP_DISTANCE = 80


---@class SiegeState
---@field artillery_groups ArtilleryGroup[]
---@field script_unit_cache table<battle_unit, script_unit>
---@field untargetable UntargetableEntry[]
---@field passed_ticks number
---@return SiegeState
local function new_siege_state()
    return {
        artillery_groups = {},
        script_unit_cache = {},
        untargetable = {},
        passed_ticks = 0
    }
end

---@type SiegeState
siege_state = new_siege_state()

---@return SiegeState
function reset_siege_state()
    siege_state = new_siege_state()
end

---@param unit battle_unit
---@return number
local function get_ammo_ratio(unit)
    local ammo_left = unit:ammo_left()
    local starting_ammo = unit:starting_ammo()
    if type(ammo_left) ~= "number" or type(starting_ammo) ~= "number" or starting_ammo <= 0 then
        return 0
    end
    return ammo_left / starting_ammo
end

---@param unit battle_unit
---@return boolean
local function can_attack_buildings(unit)
    return get_ammo_ratio(unit) > AMMO_DEPLETED_THRESHOLD
end

---@param first_x number
---@param first_z number
---@param second_x number
---@param second_z number
---@return number
function distance_between_points(first_x, first_z, second_x, second_z)
    local delta_x = second_x - first_x
    local delta_z = second_z - first_z
    return math.sqrt(delta_x * delta_x + delta_z * delta_z)
end

---@param vector battle_vector|nil guards buildings without a position
---@return number|nil, number|nil
function vector_to_coordinates(vector)
    if not vector then return nil, nil end
    local x_coordinate = vector:get_x()
    local z_coordinate = vector:get_z()
    return x_coordinate, z_coordinate
end



---@return battle_unit[]
local function collect_ai_artillery_units()
    local artillery_units = {}
    local ai_alliance = bm:get_non_player_alliance()
    if not ai_alliance then return artillery_units end

    local army_list = ai_alliance:armies()
    if not army_list then return artillery_units end

    for army_index = 1, army_list:count() do
        local army = army_list:item(army_index)
        if army then
            local unit_list = army:units()
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

---@param script_unit_object script_unit
function anian_release_script_unit_control(script_unit_object)
    output_log_anian(VERBOSE_LOGS, "releasing control of unit: " ..script_unit_object.unit:name())
    script_unit_object:release_control()
    siege_state.script_unit_cache[script_unit_object.unit] = nil
end

---@param unit battle_unit
---@return script_unit
local function script_unit_for_unit(unit)
    local cached_script_unit = siege_state.script_unit_cache[unit]
    if cached_script_unit then return cached_script_unit end

    local script_unit_object = bm:get_scriptunit_for_unit(unit)
        or script_unit:new_by_reference(unit:army(), unit:name())
    siege_state.script_unit_cache[unit] = script_unit_object    
    script_unit_object:take_control()
    return script_unit_object
end

---@param first_script_unit script_unit
---@param second_script_unit script_unit
---@return number
local function distance_between_units(first_script_unit, second_script_unit)
    local first_x, first_z = vector_to_coordinates(first_script_unit.unit:position())
    local second_x, second_z = vector_to_coordinates(second_script_unit.unit:position())
    if not first_x or not first_z or not second_x or not second_z then return math.huge end
    return distance_between_points(first_x, first_z, second_x, second_z)
end

---@return script_unit[]
local function collect_ready_artillery_units()
    local ready_script_units = {}
    for _, unit in ipairs(collect_ai_artillery_units()) do
        if can_attack_buildings(unit) then
            ready_script_units[#ready_script_units + 1] = script_unit_for_unit(unit)
        else
            anian_release_script_unit_control(script_unit_for_unit(unit))
        end
    end
    return ready_script_units
end

---@param members script_unit[]
---@param previous_groups ArtilleryGroup[]
---@return ArtilleryGroup|nil no previous group shares a member
local function find_previous_group(members, previous_groups)
    for _, previous in ipairs(previous_groups) do
        for _, member in ipairs(members) do
            if previous:ContainsUnit(member) then return previous end
        end
    end
    return nil
end

---@param script_units script_unit[]
---@param previous_groups ArtilleryGroup[]
---@return ArtilleryGroup[]
local function build_artillery_groups(script_units, previous_groups)
    local groups = {}
    local assigned = {}

    for _, script_unit_object in ipairs(script_units) do
        if not assigned[script_unit_object] then
            local members = {script_unit_object}
            assigned[script_unit_object] = true

            local group_index = 1
            while group_index <= #members do
                local member = members[group_index]
                for _, candidate in ipairs(script_units) do
                    local distance = distance_between_units(member, candidate)
                    if not assigned[candidate] and distance < ARTILLERY_GROUP_DISTANCE then
                        output_log_anian(VERBOSE_LOGS, "assigning: " ..member.unit:name() .." to group " ..tostring(group_index))
                        assigned[candidate] = true
                        members[#members + 1] = candidate
                    end
                end
                group_index = group_index + 1
            end

            local group = ArtilleryGroup:new(members)
            local previous = find_previous_group(members, previous_groups)
            if previous then group:InheritStateFrom(previous) end
            groups[#groups + 1] = group
        end
    end
    return groups
end

local function initialize_on_first_tick()
    local ready_script_units = collect_ready_artillery_units()
    siege_state.artillery_groups = build_artillery_groups(ready_script_units, siege_state.artillery_groups)
end

local function tick()
    local ok, err = pcall(function()
        if not bm:is_siege_battle() then return end -- doesnt work if the check happens in initialize
        output_log_anian(VERBOSE_LOGS, "tick start: " ..siege_state.passed_ticks )
        if siege_state.passed_ticks == 0 then
            initialize_on_first_tick()
        end

        for index, group in ipairs(siege_state.artillery_groups) do
            output_log_anian(VERBOSE_LOGS, "artillery group- " ..index .." amount: " ..group:UnitCount())
            group:HandleTargetSelection()
        end
        output_log_anian(VERBOSE_LOGS, "tick: " ..siege_state.passed_ticks .." went all the way")
        siege_state.passed_ticks = siege_state.passed_ticks + 1
        if siege_state.passed_ticks % 50 == 0 then initialize_on_first_tick() end
    end)
    if not ok then output_log_anian(LOGS, "ERROR IN TICK: " .. tostring(err)) end
end

local function initialize()
    -- for some reason the logs are not showing when in this method
    local ok, err = pcall(function()
    reset_siege_state()
    if bm then
        if bm:player_is_attacker() then
            -- output_log_anian(LOGS, "not player attacker, or not siege, returning")
            return
         end
        -- output_log_anian(LOGS, "battle manager available, registering tick callback")
        bm:repeat_callback(function() tick() end, TICK_INTERVAL_MS)
        if bm.register_phase_change_callback then
            bm:register_phase_change_callback("Complete", close_log_file)
        end
    end
    end)
    if not ok then output_log_anian(LOGS, "ERROR IN TICK: " .. tostring(err)) end

        -- else
    --     output_log_anian(LOGS, "battle manager not available, waiting for battle start")
    --     core:add_listener(
    --         "ArtillerySiegeAI",
    --         "BattleStarted",
    --         true,
    --         function()
    --             bm = get_bm()
    --             if bm then
    --                 output_log_anian(LOGS, "battle started, registering tick callback")
    --                 bm:repeat_callback(function() tick() end, TICK_INTERVAL_MS)
    --             else
    --                 output_log_anian(LOGS, "failed to get battle manager after battle start")
    --             end
    --         end,
    --         true
    --     )
end

initialize()
