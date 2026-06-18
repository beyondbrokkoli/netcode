local ffi = require("ffi")
local bit = require("bit")
local cfg = require("config_engine")
local net = require("network")
local cfg_net = require("config_net") -- [!] ADDED: The Registry

local CHAOS_PACKET_LOSS = 0.0
local Pump = {}

function Pump.send_dynamic_history(ctx)
    local current_tick = ctx.rollback_arena.head_tick
    local conf_tick = ctx.rollback_arena.confirmed_tick

    local pkt = ffi.new("LockstepPacket")
    ffi.fill(pkt, ffi.sizeof("LockstepPacket"), 0)

    pkt.session_token = ctx.session_token
    pkt.player_id = ctx.net_identity
    pkt.frame_tick = current_tick

    if conf_tick > 0 and ctx.rollback_arena.is_rollback_active == 0 then
        local conf_idx = bit.band(conf_tick, cfg_net.RING_MASK)
        pkt.state_checksum = ctx.rollback_arena.frames[conf_idx].state_checksum
        pkt.checksum_tick = conf_tick
    end

    -- [!] The Golden Ratio Baseline
    local needed_base = math.max(1, current_tick - cfg_net.HISTORY_HORIZON)
    local history_len = current_tick - needed_base + 1

    if history_len > cfg_net.HISTORY_LEN then
        history_len = cfg_net.HISTORY_LEN
    end

    pkt.base_tick = needed_base
    pkt.history_count = history_len

    -- Omnibus: Pack ACKs for the entire lobby
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            pkt.peer_acks[p] = ctx.peer_highest_tick[p]
        end
    end

    for i = 0, history_len - 1 do
        local h_tick = needed_base + i
        local h_idx = bit.band(h_tick, cfg_net.RING_MASK)
        local frame = ctx.rollback_arena.frames[h_idx]
        pkt.inputs[i] = frame.player_input[ctx.net_identity]
        pkt.clicks[i] = frame.click_grid_idx[ctx.net_identity]
    end

    -- Topology Routing: P2P + Single Dedicated Relay Megaphone
    local needs_relay = false
    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            if ctx.p2p_established and ctx.p2p_established[p] then
                net.SendTo(pkt, p) -- Direct P2P Blast
            else
                needs_relay = true
            end
        end
    end

    -- [!] FIRE THE MEGAPHONE
    -- Send exactly one packet to the pristine Dedicated Relay Socket (Index 8)
    if needs_relay then
        net.SendTo(pkt, cfg_net.MAX_PLAYERS)
    end
end

local MAX_BURST_PACKETS = 256
local global_in_buffer = ffi.new("LockstepPacket[?]", MAX_BURST_PACKETS)

function Pump.intercept_network(ctx, current_tick)
    local count = net.RecvAll(global_in_buffer, MAX_BURST_PACKETS)

    for i = 0, count - 1 do
        local pkt = global_in_buffer[i]
        local pid = pkt.player_id

        -- [!] SSoT: Echo Drop & Omnibus ACK Extraction
        -- Discard our own broadcast megaphone echoes bouncing back from the Python relay.
        if pid == ctx.net_identity then
            goto continue_inbox
        end

        if pkt.frame_tick < ctx.rollback_arena.confirmed_tick then
            goto continue_inbox
        end

        if pid < cfg_net.MAX_PLAYERS and pkt.frame_tick >= 0 and ctx.peer_active[pid] then
            local relevant_ack = pkt.peer_acks[ctx.net_identity]
            if relevant_ack > ctx.peer_ack_of_me[pid] then
                ctx.peer_ack_of_me[pid] = relevant_ack
            end

            local window_start = math.max(0, current_tick - cfg_net.HISTORY_HORIZON)
            local window_end = math.min(current_tick + cfg_net.RING_MASK, ctx.rollback_arena.confirmed_tick + cfg_net.RING_MASK)

            for h = 0, pkt.history_count - 1 do
                local h_tick = pkt.base_tick + h

                if h_tick > ctx.rollback_arena.confirmed_tick and h_tick >= window_start and h_tick <= window_end then
                    local h_idx = bit.band(h_tick, cfg_net.RING_MASK)
                    local h_frame = ctx.rollback_arena.frames[h_idx]

                    if h_frame.tick ~= h_tick then
                        h_frame.tick = h_tick
                        h_frame.state = cfg.net_state.empty
                        for p_scan = 0, cfg_net.MAX_PLAYERS - 1 do
                            h_frame.player_input[p_scan] = 0
                            h_frame.click_grid_idx[p_scan] = 65535
                        end
                        h_frame.state_checksum = 0
                        h_frame.remote_checksum = 0
                    end

                    local inc_input = pkt.inputs[h]
                    local inc_click = pkt.clicks[h]

                    if h_frame.player_input[pid] ~= inc_input or h_frame.click_grid_idx[pid] ~= inc_click then
                        if h_tick < current_tick then
                            if ctx.rollback_arena.is_rollback_active == 0 or h_tick < ctx.rollback_arena.rollback_target then
                                ctx.rollback_arena.is_rollback_active = 1
                                ctx.rollback_arena.rollback_target = h_tick
                            end
                        end
                        h_frame.player_input[pid] = inc_input
                        h_frame.click_grid_idx[pid] = inc_click
                    end
                end
            end

            local payload_highest_tick = pkt.base_tick + pkt.history_count - 1

            -- [!] FIXED: The Contiguous ACK Guard
            -- Only advance consensus if the incoming packet perfectly overlaps or connects 
            -- to our currently verified timeline. If pkt.base_tick is floating in the future, 
            -- it means packets arrived out of order and we have a hole in reality.
            if pkt.base_tick <= ctx.peer_highest_tick[pid] + 1 then
                if payload_highest_tick > ctx.peer_highest_tick[pid] then
                    ctx.peer_highest_tick[pid] = payload_highest_tick
                end
            end

            if pkt.checksum_tick > 0 and pkt.checksum_tick >= math.max(0, ctx.rollback_arena.confirmed_tick - cfg_net.DESYNC_SWEEP) and pkt.checksum_tick <= current_tick then
                local c_idx = bit.band(pkt.checksum_tick, cfg_net.RING_MASK)
                local c_frame = ctx.rollback_arena.frames[c_idx]

                if c_frame.tick == pkt.checksum_tick then
                    c_frame.remote_checksum = pkt.state_checksum
                end
            end
        end

        ::continue_inbox::
    end
end

return Pump
