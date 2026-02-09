#!/bin/bash
# hush - Attenuate the signal, strengthen quiet aspects
#
# Semantic effect:
#   - Strengthens quiet_tide (+0.18)
#   - Weakens last_witness (-0.08)
#   - Slight boost to silk_shadow (+0.05)
#
# DSP effect: gentle attenuation across all values

jq '
  .values.quiet_tide = ((.values.quiet_tide // 0) + 0.18 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.last_witness = ((.values.last_witness // 0) - 0.08 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.silk_shadow = ((.values.silk_shadow // 0) + 0.05 | if . > 1 then 1 elif . < -1 then -1 else . end)
'
