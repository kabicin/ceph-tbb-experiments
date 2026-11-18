-- no sharing: each request writes, reads back and erases 20 keys of its own,
-- 10 rounds. no key is ever touched by two requests, so any slowdown as
-- threads are added comes from the table's own locking
local prefix = "req_" .. tostring((Request and Request.Id) or math.random(1e9)) .. "_"
local keys = {}
for i = 1, 20 do keys[i] = prefix .. i end
for round = 1, 10 do
  for i = 1, 20 do RGW[keys[i]] = round end
  for i = 1, 20 do assert(RGW[keys[i]] == round) end
end
for i = 1, 20 do RGW[keys[i]] = nil end
