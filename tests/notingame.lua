-- Spot-checks the generated quest blacklist against entries whose Questie rules we evaluated by hand.
-- usage: luajit tests/notingame.lua OldmanJava/NotInGame.lua
local SP = {}
assert(loadfile(assert(arg[1], "path to NotInGame.lua")))("OldmanJava", SP)
local n = 0
for _ in pairs(SP.NotInGame) do n = n + 1 end
print("entries", n)
-- 787 true, 6606 true, 2358 Era-or-Wotlk -> hidden, 936 Era-or-Cata -> hidden,
-- 236 < Wotlk -> hidden, 7704 ~= Wotlk -> hidden, 13158 >= Cata -> kept, 8811 >= Tbc -> kept
local expect = { [787] = true, [6606] = true, [2358] = true, [936] = true, [236] = true, [7704] = true, [13158] = false, [8811] = false }
local ok = true
for id, want in pairs(expect) do
    local got = SP.NotInGame[id] == true
    print(id, got and "hidden" or "kept", got == want and "ok" or "WRONG")
    ok = ok and got == want
end
os.exit(ok and 0 or 1)
