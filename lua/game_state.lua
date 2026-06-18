local ffi = require("ffi")
local bit = require("bit")
local net = require("network")
local cfg = require("config_engine")
local cfg_net = require("config_net")
local Fixed = require("fixed_math")

local total_tiles = cfg.world.map_width * cfg.world.map_height

-- The monolithic Black Box State
ffi.cdef(string.format([[
    typedef struct {
        uint16_t terrain[8][%d];
        float elevation[8][%d];
        uint32_t rng_state[1];
    } GameState;
]], total_tiles, total_tiles))

local Game = {}

function Game.GetStateName() return "GameState" end
function Game.GetStateSize() return ffi.sizeof("GameState") end

function Game.InitState(session_token)
    local state = ffi.new("GameState")
    
    -- Initialize RNG internally
    local ptr = ffi.cast("uint32_t*", ffi.new("uint64_t[1]", session_token or 0))
    state.rng_state[0] = bit.bxor(ptr[0], ptr[1])
    if state.rng_state[0] == 0 then state.rng_state[0] = 0x811C9DC5 end
    
    return state
end

function Game.SimulateTick(state, commands_array, tick)
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        for c = 0, 1 do
            local cmd = commands_array[p][c]
            if cmd.opcode == 1 then
                local idx = cmd.target_pos
                if idx < total_tiles then
                    if state.terrain[p][idx] == 0 then
                        state.terrain[p][idx] = p + 10
                        state.elevation[p][idx] = Fixed.from_float(15.0)
                    else
                        state.terrain[p][idx] = 0
                        state.elevation[p][idx] = Fixed.from_float(0.0)
                    end
                end
            end
        end
    end
end

function Game.HashState(state)
    local h1 = net.HashState(state.terrain, ffi.sizeof(state.terrain), 0)
    local h2 = net.HashState(state.elevation, ffi.sizeof(state.elevation), h1)
    return net.HashState(state.rng_state, 4, h2)
end

return Game
