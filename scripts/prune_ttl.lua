-- expiring entries: every request records itself with a sequence number;
-- one request in 20 walks the table and erases entries older than the
-- newest 500, erasing keys while it iterates (cleanup-job pattern)
if RGW["ttl_seq"] == nil then RGW["ttl_seq"] = 0 end
RGW.increment("ttl_seq")
local seq = RGW["ttl_seq"]
RGW["ttl_" .. tostring((Request and Request.Id) or math.random(1e9))] = seq
if math.random(20) == 1 then
  for k, v in pairs(RGW) do
    local key = tostring(k)
    if key:sub(1, 4) == "ttl_" and key ~= "ttl_seq" and type(v) == "number" and v < seq - 500 then
      RGW[key] = nil
    end
  end
end
