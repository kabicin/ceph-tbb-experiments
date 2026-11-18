-- correctness under concurrency: 1000 "stable_" keys never change after they
-- are created. one request in 5 walks the table and checks it saw every
-- stable key exactly once; the others insert and erase 50 keys of their own.
-- result_scans counts checked walks, result_bad_scans the walks that missed
-- or repeated a stable key (expected 0)
-- NOTE: on main, pairs() walks the map without a lock (a data race)
if RGW["init_stable"] == nil then
  for i = 1, 1000 do RGW["stable_" .. i] = i end
  if RGW["result_scans"] == nil then RGW["result_scans"] = 0 end
  if RGW["result_bad_scans"] == nil then RGW["result_bad_scans"] = 0 end
  RGW["init_stable"] = true
end
if math.random(5) == 1 then
  local seen, n, dup = {}, 0, false
  for k in pairs(RGW) do
    local key = tostring(k)
    if key:sub(1, 7) == "stable_" then
      if seen[key] then dup = true end
      seen[key] = true
      n = n + 1
    end
  end
  RGW.increment("result_scans")
  if dup or n ~= 1000 then RGW.increment("result_bad_scans") end
else
  local prefix = "tmp_" .. tostring((Request and Request.Id) or math.random(1e9)) .. "_"
  for i = 1, 50 do RGW[prefix .. i] = i end
  for i = 1, 50 do RGW[prefix .. i] = nil end
end
