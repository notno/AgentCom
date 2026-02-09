#!/bin/bash
# ignite - Kindle fire, awaken energy
#
# Semantic effect:
#   - Strongly strengthens spark_lord (+0.40)
#   - Strengthens ember_heart (+0.25)
#   - Strengthens storm_bringer (+0.10)
#   - Weakens quiet_tide (-0.20)

jq '
  .values.spark_lord = ((.values.spark_lord // 0) + 0.40 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.ember_heart = ((.values.ember_heart // 0) + 0.25 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.storm_bringer = ((.values.storm_bringer // 0) + 0.10 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.quiet_tide = ((.values.quiet_tide // 0) - 0.20 | if . > 1 then 1 elif . < -1 then -1 else . end)
'
