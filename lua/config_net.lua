local ConfigNet = {}

-- Engine & Temporal Logic
ConfigNet.MAX_PLAYERS = 8
ConfigNet.RING_SIZE = 256
ConfigNet.RING_MASK = ConfigNet.RING_SIZE - 1         -- 255
ConfigNet.HISTORY_LEN = 240                           -- [!] PHASE 3: Scaled up to survive 2000ms RTT
ConfigNet.HISTORY_HORIZON = ConfigNet.HISTORY_LEN - 1 -- 239
ConfigNet.MAX_PACKED_ACTIONS = 128 -- [!] Expanded to survive held-inputs under heavy jitter
ConfigNet.LOOKAHEAD_CAP = 200
ConfigNet.DESYNC_SWEEP = 60
ConfigNet.TICK_RATE = 60
ConfigNet.HASH_WINDOW_LEN = 64

-- Infrastructure Routing (Matchmaker, STUN, Fallback ICE)
ConfigNet.MATCHMAKER_URL = "http://138.199.152.240:80"
ConfigNet.STUN_SERVER = "138.199.152.240"
ConfigNet.STUN_PORT = 3478
ConfigNet.RELAY_IP = "138.199.152.240"
ConfigNet.RELAY_PORT = 49152

-- I/O Limits
ConfigNet.MAX_BURST_PACKETS = 256

return ConfigNet
