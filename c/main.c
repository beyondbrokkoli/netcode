// main.c - Headless LuaJIT Bootloader
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

int main(int argc, char** argv) {
    printf("===========================================\n");
    printf(" WEAVER V2 HEADLESS BOOTLOADER\n");
    printf("===========================================\n");

    // 1. Initialize the Lua Virtual Machine
    lua_State* L = luaL_newstate();
    if (L == NULL) {
        printf("[FATAL] Failed to allocate Lua State!\n");
        return 1;
    }

    // 2. Load standard Lua libraries (math, string, table, io, etc.)
    luaL_openlibs(L);

    // 3. Configure package.path so Lua knows where to find your modules
    // This mimics the 'package.path = "./lua/?.lua;" .. package.path' in main.lua
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const char* current_path = lua_tostring(L, -1);
    
    char new_path[2048];
    snprintf(new_path, sizeof(new_path), "./lua/?.lua;%s", current_path);
    
    lua_pushstring(L, new_path);
    lua_setfield(L, -3, "path");
    lua_pop(L, 2); // Clean up the stack

    // 4. Execute the netcode entry point
    printf("[C-BOOT] Handing execution to lua/main.lua...\n\n");
    if (luaL_dofile(L, "lua/main.lua") != LUA_OK) {
        // If Lua crashes or throws an unhandled error, print it
        printf("\n[LUA FATAL ERROR] %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        lua_close(L);
        return 1;
    }

    // 5. Clean exit (This is reached when main.lua finishes naturally)
    lua_close(L);
    printf("\n[C-BOOT] Lua VM cleanly destroyed. Exiting.\n");
    return 0;
}
