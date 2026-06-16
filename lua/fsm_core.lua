local net = require("network")
local State = require("sim_world")
local bit = require("bit")
local ffi = require("ffi")
local RNG = require("sim_rng")

local FSM = {}

function FSM.tick_playing_state(ctx, FIXED_DT, bytes_terrain, bytes_elevation)
    local true_consensus = 0xFFFFFFFF
    local min_ack_of_me = 0xFFFFFFFF -- [!] ADD THIS

    for p = 0, 7 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            if ctx.peer_highest_tick[p] < true_consensus then
                true_consensus = ctx.peer_highest_tick[p]
            end
            -- [!] ADD THIS: Find the slowest peer's ack of our data
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

    -- [!] ADD THIS: Fallback if alone
    if min_ack_of_me == 0xFFFFFFFF then
        min_ack_of_me = ctx.rollback_arena.confirmed_tick
    end

    local remote_highest = ctx.rollback_arena.confirmed_tick

    -- [!] ADD THIS: The absolute lowest tick across both Recv and Send
    local safe_horizon = math.min(remote_highest, min_ack_of_me)

    if remote_highest > ctx.sim_tick_count + 2 then
        ctx.accumulator = ctx.accumulator + ((remote_highest - ctx.sim_tick_count) * FIXED_DT)
    end

    -- [!] FIX: Stall against the safe_horizon, not just remote_highest.
    -- This guarantees the fast node stops at Tick 101 if the slow node hasn't acked Tick 1.
    -- The 128-packet buffer will now safely hold Ticks 1-101.
    if ctx.sim_tick_count > safe_horizon + 100 then
        ctx.accumulator = 0
    end

    while ctx.accumulator >= FIXED_DT do
        local c_idx = bit.band(ctx.sim_tick_count, 255)
        local frame = ctx.rollback_arena.frames[c_idx]

        if frame.tick ~= ctx.sim_tick_count then
            for p = 0, 7 do
                frame.player_input[p] = 0
                frame.click_grid_idx[p] = 65535
            end
            frame.state_checksum = 0
            frame.remote_checksum = 0
            -- [FIX: BUG 3] Zero-initialize remaining struct fields to prevent dirty reads
            frame.state = 0 
            frame.remote_peer_id = 0
        end
        frame.tick = ctx.sim_tick_count

        ctx.rollback_arena.head_tick = ctx.sim_tick_count

        if ctx.rollback_arena.is_rollback_active == 1 then
            local t_tgt = ctx.rollback_arena.rollback_target
            
            -- [FIX: BUG 6] Fatal trap if rollback horizon exceeds structural capacity
            if (ctx.sim_tick_count - t_tgt) > 127 then
                print(string.format("[FATAL] Rollback horizon exceeded 128-tick memory limit! Target: %d | Head: %d", t_tgt, ctx.sim_tick_count))
                os.exit(1)
            end

            local r_idx = bit.band(t_tgt - 1, 255)

            ffi.copy(ctx.rts_grid.terrain, ctx.snapshot_ring.terrain[r_idx], bytes_terrain)
            ffi.copy(ctx.rts_grid.elevation, ctx.snapshot_ring.elevation[r_idx], bytes_elevation)
            ffi.copy(ctx.rts_grid.rng_state, ctx.snapshot_ring.rng_state[r_idx], 4)

            for t = t_tgt, ctx.sim_tick_count - 1 do
                local f_idx = bit.band(t, 255)
                local f = ctx.rollback_arena.frames[f_idx]
                State.update_simulation(ctx.rts_grid, t, f, 8)

                local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
                f.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)

                ffi.copy(ctx.snapshot_ring.terrain[f_idx], ctx.rts_grid.terrain, bytes_terrain)
                ffi.copy(ctx.snapshot_ring.elevation[f_idx], ctx.rts_grid.elevation, bytes_elevation)
                ffi.copy(ctx.snapshot_ring.rng_state[f_idx], ctx.rts_grid.rng_state, 4)
            end
            ctx.rollback_arena.is_rollback_active = 0
        end

        if ctx.sim_tick_count <= remote_highest + 100 then
            State.update_simulation(ctx.rts_grid, ctx.sim_tick_count, frame, 8)

            local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
            frame.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)

            ffi.copy(ctx.snapshot_ring.terrain[c_idx], ctx.rts_grid.terrain, bytes_terrain)
            ffi.copy(ctx.snapshot_ring.elevation[c_idx], ctx.rts_grid.elevation, bytes_elevation)
            ffi.copy(ctx.snapshot_ring.rng_state[c_idx], ctx.rts_grid.rng_state, 4)

            ctx.sim_tick_count = ctx.sim_tick_count + 1

            local conf_tick = ctx.rollback_arena.confirmed_tick
            local sweep_start = math.max(0, conf_tick - 60)

            for v_tick = sweep_start, conf_tick do
                local v_idx = bit.band(v_tick, 255)
                local v_frame = ctx.rollback_arena.frames[v_idx]

                if v_frame.tick == v_tick and v_frame.state_checksum ~= 0 and v_frame.remote_checksum ~= 0 then
                    if v_frame.state_checksum ~= v_frame.remote_checksum then
                        print(string.format("[FATAL DESYNC] Tick: %d | Local: 0x%08X | Remote: 0x%08X", v_tick, v_frame.state_checksum, v_frame.remote_checksum))
                        os.exit(1)
                    end
                end
            end
        end
        ctx.accumulator = ctx.accumulator - FIXED_DT
    end
end

return FSM
