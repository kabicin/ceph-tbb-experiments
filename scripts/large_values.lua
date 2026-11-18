-- large values: 100 shared keys holding 900-byte strings; each request reads
-- 50 and rewrites 5. measures copying big values while locks are held
local blob = string.rep("x", 900)
if RGW["blob_100"] == nil then
  for i = 1, 100 do RGW["blob_" .. i] = blob end
end
for i = 1, 50 do local v = RGW["blob_" .. math.random(100)] end
for i = 1, 5 do RGW["blob_" .. math.random(100)] = blob end
