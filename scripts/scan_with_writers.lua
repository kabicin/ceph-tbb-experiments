-- iteration racing with writers: 2000 fixed keys; one request in 10 walks
-- the table, the other 9 insert and erase 20 keys of their own.
-- NOTE: on main, pairs() walks the map without a lock, so this script is a
-- data race there (other requests' inserts can rehash under the iterator)
if RGW["base_2000"] == nil then
  for i = 1, 2000 do RGW["base_" .. i] = i end
end
if math.random(10) == 1 then
  local n = 0
  for k, v in pairs(RGW) do n = n + 1 end
else
  local prefix = "w_" .. tostring((Request and Request.Id) or math.random(1e9)) .. "_"
  for i = 1, 20 do RGW[prefix .. i] = i end
  for i = 1, 20 do RGW[prefix .. i] = nil end
end
