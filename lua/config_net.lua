local ConfigNet = {}

-- Engine & Temporal Logic
ConfigNet.MAX_PLAYERS = 2

-- [!] THE GOLDEN RATIO
ConfigNet.TICK_RATE = 60
ConfigNet.LOOKAHEAD_CAP = 60          -- 1 Second Hard Pause. We never guess further than this.
ConfigNet.HISTORY_LEN = 120           -- 2 Seconds of payload. The "Blanket" is always 2x the Cap.
ConfigNet.HISTORY_HORIZON = ConfigNet.HISTORY_LEN - 1
ConfigNet.DESYNC_SWEEP = 60           -- 1 Second trailing validation

ConfigNet.RING_SIZE = 512             -- 512 > (120 + 60 + 60) -> Zero Memory Collisions
ConfigNet.RING_MASK = ConfigNet.RING_SIZE - 1

-- Infrastructure Routing (Matchmaker, STUN, Fallback ICE)
ConfigNet.MATCHMAKER_URL = "http://138.199.152.240:80"
ConfigNet.STUN_SERVER = "138.199.152.240"
ConfigNet.STUN_PORT = 3478
ConfigNet.RELAY_IP = "138.199.152.240"
ConfigNet.RELAY_PORT = 49152

-- I/O Limits
ConfigNet.MAX_BURST_PACKETS = 256

return ConfigNet
