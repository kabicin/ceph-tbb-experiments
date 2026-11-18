-- atomic counters: 200 RGW.increment calls spread over 4 shared keys
-- (the race-free way to write counter.lua). measures the increment path
-- when every request hits the same few keys
for i = 1, 4 do
  if RGW["hot_" .. i] == nil then RGW["hot_" .. i] = 0 end
end
for i = 1, 200 do
  RGW.increment("hot_" .. (i % 4 + 1))
end
