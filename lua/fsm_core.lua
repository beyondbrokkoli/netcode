-- lua/fsm_core.lua
local net = require("network")
local State = require("sim_world")
local bit = require("bit")
local ffi = require("ffi")
local RNG = require("sim_rng")
local cfg_net = require("config_net")

local FSM = {}

function FSM.tick_playing_state(ctx, FIXED_DT, bytes_terrain, bytes_elevation)
    local true_consensus = 0xFFFFFFFF
    local min_ack_of_me = 0xFFFFFFFF

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            if ctx.peer_highest_tick[p] < true_consensus then
                true_consensus = ctx.peer_highest_tick[p]
            end
            if ctx.peer_ack_of_me[p] < min_ack_of_me then
                min_ack_of_me = ctx.peer_ack_of_me[p]
            end
        end
    end

    local local_max_valid_tick = math.max(0, ctx.sim_tick_count - 1)
    if true_consensus > local_max_valid_tick then
        true_consensus = local_max_valid_tick
    end
    if true_consensus ~= 0xFFFFFFFF and true_consensus > ctx.rollback_arena.confirmed_tick then
        ctx.rollback_arena.confirmed_tick = true_consensus
    end

    if min_ack_of_me == 0xFFFFFFFF then
        min_ack_of_me = ctx.rollback_arena.confirmed_tick
    end

    local remote_highest = ctx.rollback_arena.confirmed_tick
    local safe_horizon = math.min(remote_highest, min_ack_of_me)

    if remote_highest > ctx.sim_tick_count + 2 then
        ctx.accumulator = ctx.accumulator + ((remote_highest - ctx.sim_tick_count) * FIXED_DT)
    end

    if ctx.sim_tick_count > safe_horizon + cfg_net.LOOKAHEAD_CAP then
        ctx.accumulator = 0
    end

    while ctx.accumulator >= FIXED_DT do
        local c_idx = bit.band(ctx.sim_tick_count, cfg_net.RING_MASK)
        local frame = ctx.rollback_arena.frames[c_idx]

        if frame.tick ~= ctx.sim_tick_count then
            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                frame.player_input[p] = 0
                frame.click_grid_idx[p] = 65535
                -- [!] PHASE 2: Ensure the 2D array is zeroed out for future ticks
                frame.remote_checksums[p] = 0
            end
            frame.state_checksum = 0
            frame.state = 0
            frame.remote_peer_id = 0
        end
        frame.tick = ctx.sim_tick_count

        ctx.rollback_arena.head_tick = ctx.sim_tick_count

        if ctx.rollback_arena.is_rollback_active == 1 then
            local t_tgt = ctx.rollback_arena.rollback_target

            if (ctx.sim_tick_count - t_tgt) > cfg_net.HISTORY_HORIZON then
                print(string.format("[FATAL] Rollback horizon exceeded memory limit! Target: %d | Head: %d", t_tgt, ctx.sim_tick_count))
                os.exit(1)
            end

            local r_idx = bit.band(t_tgt - 1, cfg_net.RING_MASK)

            ffi.copy(ctx.rts_grid.terrain, ctx.snapshot_ring.terrain[r_idx], bytes_terrain)
            ffi.copy(ctx.rts_grid.elevation, ctx.snapshot_ring.elevation[r_idx], bytes_elevation)
            ffi.copy(ctx.rts_grid.rng_state, ctx.snapshot_ring.rng_state[r_idx], 4)

            for t = t_tgt, ctx.sim_tick_count - 1 do
                local f_idx = bit.band(t, cfg_net.RING_MASK)
                local f = ctx.rollback_arena.frames[f_idx]
                State.update_simulation(ctx.rts_grid, t, f, cfg_net.MAX_PLAYERS)

                local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
                f.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)

                ffi.copy(ctx.snapshot_ring.terrain[f_idx], ctx.rts_grid.terrain, bytes_terrain)
                ffi.copy(ctx.snapshot_ring.elevation[f_idx], ctx.rts_grid.elevation, bytes_elevation)
                ffi.copy(ctx.snapshot_ring.rng_state[f_idx], ctx.rts_grid.rng_state, 4)
            end
            ctx.rollback_arena.is_rollback_active = 0
        end

        if ctx.sim_tick_count <= remote_highest + cfg_net.LOOKAHEAD_CAP then
            State.update_simulation(ctx.rts_grid, ctx.sim_tick_count, frame, cfg_net.MAX_PLAYERS)

            local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
            frame.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)

            ffi.copy(ctx.snapshot_ring.terrain[c_idx], ctx.rts_grid.terrain, bytes_terrain)
            ffi.copy(ctx.snapshot_ring.elevation[c_idx], ctx.rts_grid.elevation, bytes_elevation)
            ffi.copy(ctx.snapshot_ring.rng_state[c_idx], ctx.rts_grid.rng_state, 4)

            ctx.sim_tick_count = ctx.sim_tick_count + 1

            local conf_tick = ctx.rollback_arena.confirmed_tick
            -- [!] PATCH: Floor the sweep at Tick 1. Tick 0 is never transmitted over the wire.
            local sweep_start = math.max(1, conf_tick - cfg_net.DESYNC_SWEEP)

            for v_tick = sweep_start, conf_tick do
                local v_idx = bit.band(v_tick, cfg_net.RING_MASK)
                local v_frame = ctx.rollback_arena.frames[v_idx]

               -- Inside FSM.tick_playing_state (around line 105)
               if v_frame.tick == v_tick and v_frame.state_checksum ~= 0 then
                   for p_chk = 0, cfg_net.MAX_PLAYERS - 1 do
                       if p_chk ~= ctx.net_identity then
                           local remote_hash = v_frame.remote_checksums[p_chk]

                           if remote_hash ~= 0 then
                               -- Standard validation
                               if v_frame.state_checksum ~= remote_hash then
                                   print(string.format("[FATAL DESYNC] Tick: %d | Local: 0x%08X | Remote (P%d): 0x%08X",
                                       v_tick, v_frame.state_checksum, p_chk, remote_hash))
                                   os.exit(1)
                               end


                            else
                                -- [!] PATCH 2.2: The Ultimate Starvation Fix
                                -- Fast peers are forbidden from sending hashes until global consensus rises.
                                -- We must patiently hold the unvalidated frame until the absolute physical
                                -- memory limit of our ring buffer is reached (HISTORY_HORIZON).
                                if (ctx.sim_tick_count - v_tick) >= cfg_net.HISTORY_HORIZON then
                                    print(string.format("[FATAL DESYNC] Hash Starvation! P%d permanently ghosted us on Tick: %d", p_chk, v_tick))
                                    os.exit(1)
                                end
                            end
                        end
                    end
                end
            end
        end
        ctx.accumulator = ctx.accumulator - FIXED_DT
    end
end

return FSM
