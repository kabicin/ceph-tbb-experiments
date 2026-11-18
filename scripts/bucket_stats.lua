-- realistic accounting: per bucket and op counters over ~1000 buckets
-- (~6000 keys). each request bumps 4 counters and records its access time.
-- mild contention, no iteration: close to what a production script does
local bucket = (Request and Request.Bucket and Request.Bucket.Name) or ("bucket" .. math.random(1000))
local op = (Request and Request.RGWOp) or ({"get_obj", "put_obj", "list_bucket", "delete_obj"})[math.random(4)]
local function bump(k, n)
  if RGW[k] == nil then RGW[k] = 0 end
  RGW.increment(k, n)
end
bump("ops_" .. bucket .. "_" .. op, 1)
bump("ops_" .. bucket, 1)
bump("ops_total", 1)
bump("bytes_" .. bucket, math.random(4096))
RGW["last_" .. bucket] = os.time()
