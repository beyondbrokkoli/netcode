local ffi = require("ffi")
local cfg_net = require("config_net")
local M = {}

local struct_sizes = {
    float = 4, uint32_t = 4, int32_t = 4,
    uint64_t = 8, int64_t = 8,
    uint16_t = 2, int16_t = 2,
    uint8_t = 1, int8_t = 1
}

local function get_base_size(type_str)
    if struct_sizes[type_str] then return struct_sizes[type_str] end
    if string.find(type_str, "*") then return 8 end
    if string.find(type_str, "64") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end
    error("[FATAL] Unknown type size requested in SSoT Generator: " .. tostring(type_str))
end

M.specs = {
    {
       name = "PlayerCommand", align = 1, force_align = true, wire_format = true,
       members = {
            { type = "uint8_t", name = "opcode" },
            { type = "uint8_t", name = "flags" },
            { type = "uint16_t", name = "target_id" },
            { type = "uint32_t", name = "target_pos" }
        }
    },
    {
        name = "LockstepPacket", align = 1, wire_format = true, force_align = true,
        members = {
            { type = "uint64_t", name = "session_token" },
            { type = "uint32_t", name = "frame_tick" },
            { type = "uint32_t", name = "checksum_tick" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "base_tick" },
            { type = "uint8_t", name = "player_id" },
            { type = "uint8_t", name = "history_count" },
            { type = "uint16_t", name = "_align_pad" }, -- [!] RESTORED: Forces 4-byte alignment
            { type = "uint32_t", name = "peer_acks", count = cfg_net.MAX_PLAYERS },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.HISTORY_LEN, 2 } }
        }
    },
    {
        name = "NetworkFrame", align = 4, force_align = true,
        members = {
            { type = "uint32_t", name = "tick" },
            { type = "uint8_t", name = "state" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "remote_checksum" },
            { type = "uint8_t", name = "remote_peer_id" },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.MAX_PLAYERS, 2 } }
        }
    },
    {
        name = "RollbackBuffer", align = 64, force_align = true,
        members = {
            { type = "uint32_t", name = "head_tick" },
            { type = "uint32_t", name = "confirmed_tick" },
            { type = "uint8_t", name = "is_rollback_active" },
            { type = "uint32_t", name = "rollback_target" },
            { type = "NetworkFrame", name = "frames", count = cfg_net.RING_SIZE }
        }
    }
}

local cdef_builder = ""
for _, struct in ipairs(M.specs) do
    local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
    cdef_builder = cdef_builder .. string.format("typedef struct %s {\n", attr)
    local offset = 0
    local pad_id = 0
    for _, m in ipairs(struct.members) do
        local m_size = get_base_size(m.type)
        if not struct.wire_format then
            local rem = offset % m_size
            if rem ~= 0 then
                local pad_bytes = m_size - rem
                cdef_builder = cdef_builder .. string.format(" uint8_t _pad_%d[%d];\n", pad_id, pad_bytes)
                offset = offset + pad_bytes
                pad_id = pad_id + 1
            end
        end
        local arr = ""
        local element_count = 1
        if type(m.count) == "table" then
            for _, dim in ipairs(m.count) do
                arr = arr .. string.format("[%d]", dim)
                element_count = element_count * dim
            end
        elseif m.count then
            arr = string.format("[%d]", m.count)
            element_count = m.count
        end
        cdef_builder = cdef_builder .. string.format(" %s %s%s;\n", m.type, m.name, arr)
        local real_size = m_size * element_count
        if struct_sizes[m.type] then
            real_size = struct_sizes[m.type] * element_count
        end
        offset = offset + real_size
    end
    if not struct.wire_format then
        local tail_rem = offset % struct.align
        if tail_rem ~= 0 then
            local tail_pad = struct.align - tail_rem
            cdef_builder = cdef_builder .. string.format(" uint8_t _pad_tail[%d];\n", tail_pad)
            offset = offset + tail_pad
        end
    end
    cdef_builder = cdef_builder .. "} " .. struct.name .. ";\n\n"
    struct_sizes[struct.name] = offset
end
ffi.cdef(cdef_builder)
return M
