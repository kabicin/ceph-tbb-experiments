-- read-mostly: 50 shared "config" keys; each request does 500 reads and,
-- with 1% odds per read, a write (~5 writes per request).
-- shows how concurrent readers scale: one global mutex vs shared shard locks
local keys = {}
for i = 1, 50 do keys[i] = "cfg_" .. i end
if RGW["cfg_50"] == nil then
  for i = 1, 50 do RGW[keys[i]] = i end
end
local sum = 0
for i = 1, 500 do
  local k = keys[i % 50 + 1]
  local v = RGW[k]
  if v then sum = sum + v end
  if math.random(100) == 1 then RGW[k] = i end
end
