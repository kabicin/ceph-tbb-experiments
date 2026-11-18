-- read-only full scan: 5000 fixed keys (created by the first requests);
-- every request walks the whole table once and sums the values.
-- measures the cost of one iteration step when nobody is writing
if RGW["scan_5000"] == nil then
  for i = 1, 5000 do RGW["scan_" .. i] = i end
end
local n, sum = 0, 0
for k, v in pairs(RGW) do
  n = n + 1
  if type(v) == "number" then sum = sum + v end
end
