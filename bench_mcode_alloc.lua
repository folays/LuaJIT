ffi = require("ffi")

ffi.cdef[[
void *malloc(size_t size);
void free(void *ptr);

int getpid(void);

typedef struct lua_State lua_State;
lua_State *(luaL_newstate) (void);
void luaL_openlibs(lua_State *L);
int luaL_loadfile(lua_State *L, const char *filename);
void lua_call(lua_State *L, int nargs, int nresults);
int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
const char *lua_tolstring(lua_State *L, int idx, size_t *len);
void lua_settop(lua_State *L, int idx);

void *mmap(void *addr, size_t len, int prot, int flags, int fd, uint64_t offset);
int munmap(void *addr, size_t len);
]]

function eat_memory(kB, nb) -- raw eat (1024) * kB * nb
    for i=1,nb do
        local buf = ffi.C.malloc(1024*kB)
        buf = ffi.cast(ffi.typeof("uint8_t(&)[$]", 1024*kB), buf)
        for i_kB=0,kB-1 do -- populate pages
            buf[1024*i_kB] = 0x42
        end
    end
end
function eat_100_MiB_by_1_MiB() eat_memory(1024, 100) end

local pid = ffi.C.getpid()
local si_suffix_table = {K=1024, M=1024*1024, G=1024*1024*1024}
function vm_size()
    local total_MB

    local file = io.popen("vmmap "..pid)
    for line in file:lines() do
        local total, suffix = line:match("^TOTAL +(%d+.?%d*)([KMG])")
        if total then
            total_MB = total * si_suffix_table[suffix] / 1024 / 1024
            --print("total_MB", total_MB)
        end

        local range1, range2 = line:match("^[%w_() ]+ +(%x+)-(%x+) +%[")
        if range1 then
        end
    end
    file:close()

    return total_MB
end

local LJ_TARGET_JUMPRANGE = 31
local sizemcode = 32 * 1024
local maxmcode = 512 * 1024
local t_ranges = {}
function ranges_populate(target) -- Figuring out the whole mcode from code excerpt from mcode_alloc()
    target = bit.band(target, bit.bnot(0xffffULL))
    printf("TARGET 0x%x", target)
    --local range = (1u << (LJ_TARGET_JUMPRANGE-1)) - (1u << 21);
    local range = bit.lshift(1ULL, LJ_TARGET_JUMPRANGE-1) - bit.lshift(1ULL, 21)
    printf("RANGE 0x%x", range)
    local max = tonumber(bit.lshift(1ULL, 52)-1)

    for i=1,1000000 do
        local hint = bit.band(math.random(0,max), (bit.lshift(1ULL, LJ_TARGET_JUMPRANGE) - 0x10000))
        --printf("xxxx: %30x", tonumber(hint))
        if hint + sizemcode < range+range then
            --printf("yyyy: %30x %x", hint + sizemcode, range+range)
            --printf(".... target %x + hint %x - range %x", target,hint,range)
            hint = target + hint - range
            --printf("HINT: %30x", hint)
            hint = tonumber(bit.rshift(hint, 16))
            t_ranges[hint] = true
        end
    end

    local ranges_nb = 0
    for k, v in pairs(t_ranges) do
        ranges_nb = ranges_nb + 1
    end
    printf("TOTAL RANGES : %d", ranges_nb)
end

local PROT_NONE = 0
local MAP_ANON = 0x1000
local MAP_FIXED = 0x0010
local MAP_PRIVATE = 0x0002
function ranges_check()
    local t_ranges_available = {[true]=0,[false]=0}

    for range in pairs(t_ranges) do
        local range = ffi.cast("void *", bit.lshift(ffi.cast("uint64_t", range), 16))
        --printf("MMAP 0x%x", range)
        local mmap = ffi.C.mmap(range, sizemcode, PROT_NONE, bit.bor(MAP_ANON,MAP_PRIVATE), -1, 0)
        --print("MMAP", mmap, mmap == range)
        ffi.C.munmap(mmap, sizemcode)

        t_ranges_available[mmap == range] = t_ranges_available[mmap == range] + 1
    end

    local t = {
        ok = t_ranges_available[true],
        ok_pct = t_ranges_available[true] / (t_ranges_available[true] + t_ranges_available[false]) * 100,
        fail = t_ranges_available[false],
    }
    return t
end


if __main__ then
    os.execute("date")

    function printf(format, ...) print(string.format(format,...)) end
    printf("TARGET lj_vm_exit_handler 0x%x", lj_vm_exit_handler())

    ranges_populate(lj_vm_exit_handler()) -- http://luajit.org/running.html
    ranges_check()

    for i=1,1000 do
        local L = ffi.C.luaL_newstate()
        ffi.C.luaL_openlibs(L)
        ffi.C.luaL_loadfile(L, "bench_mcode_alloc.lua")
        if ffi.C.lua_pcall(L, 0, 1, 0) ~= 0 then
            local err = ffi.C.lua_tolstring(L, -1, nil)
            print("CHIlD ERROR", ffi.string(err))
            os.exit(1)
        end
        ffi.C.lua_settop(L, 0) -- pop value
        if i % 100 == 0 then
            local ranges = ranges_check()
            local vm_size = vm_size()
            printf("[%5d] RANGES AVAILABLE: yes %d (%.3f%%) no %d ; vmsize %f MB",
                    i, ranges.ok, ranges.ok_pct, ranges.fail, vm_size
            )
        end
        io.flush()
    end
    print("END")
else -- children
    local jit = require("jit")
    --print(jit.version)
    --eat_100_MiB_by_1_MiB()
    eat_memory(8, 100)
    eat_memory(1, 1)
    eat_memory(3*1024, 1)

    ffi.C.malloc(1024 * 1024)

    for i=1,100 do end
end
