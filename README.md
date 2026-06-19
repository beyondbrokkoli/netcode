# Weaver Engine v2.0

A deterministic, zero-allocation lockstep rollback netcode engine built on a C/LuaJIT FFI boundary.

## Architecture

### Network Topology
The engine uses a single-broadcast topology to avoid $O(N^2)$ packet scaling. Each hardware frame generates one MTU-sized packet containing:
- 120 ticks of input history.
- An 8-player ACK array.

LAN peers communicate directly via UDP. WAN peers route through a dedicated Python ICE relay. 

The simulation runs at 60Hz with a 60-tick lookahead. The 120-tick history ensures that slow peers receive missing frames without stalling the simulation.

### Memory Management
The 60Hz network loop performs zero heap allocations to prevent LuaJIT garbage collection pauses.
- Network buffers use pre-allocated static ring buffers.
- Deserialization uses raw `uint64_t*` pointer casting for contiguous memory access.

### NAT Traversal
- **Bidirectional Handshake:** Requires a two-way PING/PONG exchange before upgrading a route to P2P.
- **LAN Loopback:** Detects shared public IPs to bypass router NAT loopback failures, forcing local peers to use the local network switch.
- **Socket Isolation:** The relay uses a dedicated internal socket to prevent stateful NAT collisions.

## Game Integration Interface

The engine is independent of game logic. It synchronizes an 8-byte `PlayerCommand` struct and manages the simulation loop.

### Input Structure
Players submit raw intents via a packed 8-byte C struct:

```c
typedef struct __attribute__((packed)) {
    uint8_t  opcode;     // Action ID
    uint8_t  flags;      // Modifiers
    uint16_t target_id;  // Entity ID
    uint32_t target_pos; // Grid index or coordinates
} PlayerCommand;
```

### Game State API (`game_state.lua`)
Implement the `Game` table with the following four functions:

```lua
local Game = {}

-- 1. State Allocation
-- Return the FFI C-struct representing the game state.
function Game.InitState(session_token) ... end
function Game.GetStateSize() ... end

-- 2. Simulation
-- Execute game rules using the synchronized commands for the current tick.
function Game.SimulateTick(state, commands_array, tick)
    for p = 0, MAX_PLAYERS - 1 do
        local cmd = commands_array[p][0]
        if cmd.opcode == OPCODE_MOVE then
            -- Update state deterministically
        end
    end
end

-- 3. State Verification
-- Return a hash of the state for desync detection.
function Game.HashState(state) ... end

return Game
```

### Submitting Inputs (`main.lua`)
Submit local player or bot inputs to the engine's pending frame buffer. This runs outside the deterministic simulation loop.

```lua
Engine.SubmitCommand(ctx, OPCODE_RAISE_TILE, 0, 0, target_grid_index)
```

## Testing & Infrastructure

The repository includes a Python test harness for simulating multi-node environments.

A centralized matchmaker and UDP relay are currently hosted online for testing. The harness is pre-configured to route signaling and game traffic through this infrastructure.

To run an 8-player simulation:
1. Execute `python harness_split.py` and select `(H)ost` to initialize Node 0 and Nodes 1-3.
2. On a second machine (or the same one), execute `python harness_split.py` and select `(J)oin` using the 4-character lobby code to initialize Nodes 4-7.

The nodes will automatically establish quorum and maintain deterministic consensus via the hosted relay.
