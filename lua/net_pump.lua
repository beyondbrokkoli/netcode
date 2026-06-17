local ffi = require("ffi")
local bit = require("bit")
local cfg = require("config_engine")
local net = require("network")
local cfg_net = require("config_net")

local CHAOS_PACKET_LOSS = 0.0
local Pump = {}

function Pump.send_dynamic_history(ctx)
    local current_tick = ctx.rollback_arena.head_tick
    local conf_tick = ctx.rollback_arena.confirmed_tick

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            local pkt = ffi.new("LockstepPacket")
            ffi.fill(pkt, ffi.sizeof("LockstepPacket"), 0)

            pkt.session_token = ctx.session_token
            pkt.player_id = ctx.net_identity
            pkt.frame_tick = current_tick
            pkt.ack_tick = ctx.peer_highest_tick[p]

            -- [!] DEEP AMNESIA FIX: Re-Anchor to conf_tick (mathematical certainty), but use the expanded window
            if conf_tick > 0 and ctx.rollback_arena.is_rollback_active == 0 then
                local chk_base = conf_tick - cfg_net.HASH_WINDOW_LEN + 1
                if chk_base < 1 then chk_base = 1 end
                pkt.checksum_base_tick = chk_base

                for i = 0, conf_tick - chk_base do
                    local c_idx = bit.band(chk_base + i, cfg_net.RING_MASK)
                    pkt.recent_checksums[i] = ctx.rollback_arena.frames[c_idx].state_checksum
                end
            end

            local needed_base = ctx.peer_ack_of_me[p] + 1
            if needed_base == 1 then
                needed_base = math.max(1, current_tick - cfg_net.HISTORY_HORIZON)
            end

            local history_len = current_tick - needed_base + 1
            if history_len > cfg_net.HISTORY_LEN then
                history_len = cfg_net.HISTORY_LEN
                needed_base = current_tick - cfg_net.HISTORY_HORIZON
            elseif history_len <= 0 then
                history_len = 1
                needed_base = current_tick
            end

            pkt.base_tick = needed_base
            pkt.history_count = history_len
            pkt.packed_count = 0

            -- [!] One-Pass Reverse Packing (Guaranteed Fit)
            for i = history_len - 1, 0, -1 do
                local h_tick = needed_base + i
                local h_idx = bit.band(h_tick, cfg_net.RING_MASK)
                local frame = ctx.rollback_arena.frames[h_idx]

                local inc_input = frame.player_input[ctx.net_identity]
                local inc_click = frame.click_grid_idx[ctx.net_identity]

                if (inc_input ~= 0 or inc_click ~= 65535) then
                    local mask_idx = bit.rshift(i, 5)
                    local bit_idx = bit.band(i, 31)

                    pkt.active_mask[mask_idx] = bit.bor(pkt.active_mask[mask_idx], bit.lshift(1, bit_idx))
                    pkt.packed_inputs[pkt.packed_count] = inc_input
                    pkt.packed_clicks[pkt.packed_count] = inc_click
                    pkt.packed_count = pkt.packed_count + 1
                end
            end

            net.SendTo(pkt, p)
        end
    end
end

local MAX_BURST_PACKETS = 256
local global_in_buffer = ffi.new("LockstepPacket[?]", MAX_BURST_PACKETS)

function Pump.intercept_network(ctx, current_tick)
    local count = net.RecvAll(global_in_buffer, MAX_BURST_PACKETS)

    for i = 0, count - 1 do
        local pkt = global_in_buffer[i]
        local pid = pkt.player_id

        if pkt.frame_tick < ctx.rollback_arena.confirmed_tick then
            goto continue_inbox
        end

        if pid < cfg_net.MAX_PLAYERS and pkt.frame_tick >= 0 and ctx.peer_active[pid] then
            if pkt.ack_tick > ctx.peer_ack_of_me[pid] then
                ctx.peer_ack_of_me[pid] = pkt.ack_tick
            end

            local window_start = math.max(0, current_tick - cfg_net.HISTORY_HORIZON)
            local window_end = math.min(current_tick + cfg_net.RING_MASK, ctx.rollback_arena.confirmed_tick + cfg_net.RING_MASK)

            local unpack_idx = 0

            -- [!] REVERSED: Unpack from newest to oldest to match the byte payload order
            for h = pkt.history_count - 1, 0, -1 do
                local h_tick = pkt.base_tick + h

                local inc_input = 0
                local inc_click = 65535

                local mask_idx = bit.rshift(h, 5)
                local bit_idx = bit.band(h, 31)

                if bit.band(pkt.active_mask[mask_idx], bit.lshift(1, bit_idx)) ~= 0 then
                    if unpack_idx < pkt.packed_count then
                        inc_input = pkt.packed_inputs[unpack_idx]
                        inc_click = pkt.packed_clicks[unpack_idx]
                        unpack_idx = unpack_idx + 1
                    end
                end

                if h_tick > ctx.rollback_arena.confirmed_tick and h_tick >= window_start and h_tick <= window_end then
                    local h_idx = bit.band(h_tick, cfg_net.RING_MASK)
                    local h_frame = ctx.rollback_arena.frames[h_idx]

                    if h_frame.tick ~= h_tick then
                        h_frame.tick = h_tick
                        h_frame.state = cfg.net_state.empty
                        for p_scan = 0, cfg_net.MAX_PLAYERS - 1 do
                            h_frame.player_input[p_scan] = 0
                            h_frame.click_grid_idx[p_scan] = 65535
                            h_frame.remote_checksums[p_scan] = 0
                        end
                        h_frame.state_checksum = 0
                    end

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

            if pkt.frame_tick > ctx.peer_highest_tick[pid] then
                ctx.peer_highest_tick[pid] = pkt.frame_tick
            end

            -- [!] REVERTED: Remove ctx.peer_checksum_base tracker
            if pkt.checksum_base_tick > 0 then
                for chk_i = 0, cfg_net.HASH_WINDOW_LEN - 1 do
                    local chk_tick = pkt.checksum_base_tick + chk_i
                    local inc_chk = pkt.recent_checksums[chk_i]

                    if inc_chk ~= 0 and chk_tick >= math.max(0, ctx.rollback_arena.confirmed_tick - cfg_net.DESYNC_SWEEP) and chk_tick <= current_tick then
                        local c_idx = bit.band(chk_tick, cfg_net.RING_MASK)
                        local c_frame = ctx.rollback_arena.frames[c_idx]

                        if c_frame.tick == chk_tick then
                            c_frame.remote_checksums[pid] = inc_chk
                        end
                    end
                end
            end
        end

        ::continue_inbox::
    end
end

return Pump
