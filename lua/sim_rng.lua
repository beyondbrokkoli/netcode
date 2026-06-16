local ffi = require("ffi")
local bit = require("bit")

local RNG = {}

function RNG.seed(state_ptr, session_token)
    local ptr = ffi.cast("uint32_t*", ffi.new("uint64_t[1]", session_token))
    state_ptr[0] = bit.bxor(ptr[0], ptr[1])
    if state_ptr[0] == 0 then
        state_ptr[0] = 0x811C9DC5
    end
end

function RNG.next(state_ptr)
    state_ptr[0] = state_ptr[0] * 1103515245 + 12345
    return state_ptr[0]
end

function RNG.range(state_ptr, min, max)
    return min + (tonumber(RNG.next(state_ptr)) % (max - min + 1))
end

return RNG
