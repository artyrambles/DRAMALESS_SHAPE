-- Run one standalone test from the checkout rather than LOVE's mounted source
-- tree. Useful for the tiny API tests whose normal loader prefers
-- love.filesystem when they execute inside a full game driver.

local target = assert(arg and arg[1], "test path is required")
love = nil
dofile(target)
