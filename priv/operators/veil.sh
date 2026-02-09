#!/bin/bash
# veil - Obscure and conceal, shift toward shadow
#
# Semantic effect:
#   - Strengthens silk_shadow (+0.25)
#   - Strengthens hollow_crown (+0.12)
#   - Weakens spark_lord (-0.15)
#   - Weakens golden_liar (-0.10)

jq '
  .values.silk_shadow = ((.values.silk_shadow // 0) + 0.25 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.hollow_crown = ((.values.hollow_crown // 0) + 0.12 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.spark_lord = ((.values.spark_lord // 0) - 0.15 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.golden_liar = ((.values.golden_liar // 0) - 0.10 | if . > 1 then 1 elif . < -1 then -1 else . end)
'
