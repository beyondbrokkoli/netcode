🕸️ Weaver Engine (v2.0 "Black Box")

A deterministic, zero-allocation lockstep rollback engine built for AAA RTS concurrency.

Built entirely on a C/LuaJIT FFI boundary, the Weaver Engine separates rendering (Vulkan) from simulation state, utilizing aggressive data-oriented design to maintain perfect synchronization across 8 players.

Surviving rigorous chaos engineering (1800ms latency, 50% packet loss, 50% out-of-order delivery), v2.0 introduces the "Black Box" Abstraction and Omnibus Megaphone Routing, delivering an indestructible UDP carrier wave for any deterministic game logic.

⚡ Core Network Architecture

1. The Omnibus Megaphone (O(1) Broadcasts)

Traditional lockstep engines suffer from $O(N^2)$ packet storms. Weaver utilizes an "Omnibus" topology. The engine constructs exactly one MTU blanket per hardware frame, packed with a 120-tick history payload and the complete 8-player ACK array.

Seamless Fallback: It blasts directly over P2P for local peers and sends a single, authoritative broadcast to the dedicated Python ICE Relay for WAN routing.

The Golden Ratio: Running at a 60Hz tick rate with a 60-tick lookahead cap, our 120-tick MTU history mathematically guarantees that every packet contains the missing frames for the slowest player, completely eliminating deadlock ("Spiral of Death") stalls.

2. Zero-Allocation Hot Path

The engine strictly forbids Garbage Collection triggers (like ffi.new) in the 60Hz pump. Incoming/outgoing packets use pre-allocated static ring buffers. Network deserialization and desync detection are optimized via raw uint64_t* contiguous memory casting, checking two 8-byte command intents in a single CPU instruction.

3. Bulletproof NAT Traversal

Symmetric Mutual Handshake (PING/PONG): Prevents the "One-Way Firewall Isolation" trap by demanding two-way trust before upgrading a route to P2P.

Anti-Hairpin LAN Clamp: Intelligently detects shared public IPs to bypass router NAT loopback drops, instantly clamping local connections to hardware switches.

First-Fail Socket Hijack Prevention: The Hetzner Relay operates on a pristine, dedicated internal socket (Index 8) to prevent stateful NAT collision.

📦 The "Black Box" API

As of v2.0, the Weaver Engine is completely blinded to game logic. It does not know what a "unit," "building," or "tile" is. It provides the Carrier Wave, and you provide the Cargo.

The engine communicates with your game strictly through an 8-byte FFI PlayerCommand struct and the Game.* API contract.

The Command Payload

Instead of specific mouse clicks, players submit raw Intents:

typedef struct __attribute__((packed)) {
    uint8_t  opcode;     // Action ID (e.g., 1=Move, 2=Build)
    uint8_t  flags;      // Stance, modifiers
    uint16_t target_id;  // Deterministic Entity Registry ID
    uint32_t target_pos; // Grid Index or Coordinates
} PlayerCommand;


Implementing Your Game (game_state.lua)

To build a game on Weaver, you only need to modify one file. Define your monolithic C-struct, and fulfill these four API requirements:

local Game = {}

-- 1. State Allocation
-- Return the raw FFI C-struct representing your entire game board.
function Game.InitState(session_token) ... end
function Game.GetStateSize() ... end

-- 2. The Deterministic Dispatcher
-- Execute the game rules based on the synchronized PlayerCommands.
function Game.SimulateTick(state, commands_array, tick)
    for p = 0, MAX_PLAYERS - 1 do
        local cmd = commands_array[p][0]
        if cmd.opcode == OPCODE_MOVE then
            -- Deterministic pathfinding logic here
        end
    end
end

-- 3. Checksum Generation
-- Hash your arrays for the rollback consensus guard.
function Game.HashState(state) ... end

return Game


Submitting Inputs (main.lua)

Local UI and Bot logic run at arbitrary framerates outside the simulation loop. To interact with the game, submit intents directly to the engine's pending frame buffer:

Engine.SubmitCommand(ctx, OPCODE_RAISE_TILE, 0, 0, target_grid_index)


🛠️ Testing & Harness

The repository includes a multithreaded Python harness (harness_full.py) and an asyncio UDP/HTTP Relay matchmaker.

To spin up a split-brain localhost multiverse:

Boot the Python Matchmaker locally (python server.py).

Run python harness_split.py and select (H)ost. It will boot Node 0 and Nodes 1-3.

On a second machine (or the same one), run python harness_split.py and select (J)oin using the 4-character lobby code to boot Nodes 4-7.

Watch 8 independent LuaJIT instances flawlessly establish quorum and maintain deterministic consensus.

Built in the UDP trenches. The netcode is indestructible. Time to build the game.
