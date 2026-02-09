#!/bin/bash
# bind - Create connections, establish contracts
#
# Semantic effect:
#   - Strengthens binder_who_smiles (+0.30)
#   - Strengthens iron_promise (+0.20)
#   - Slight cost to soft_betrayal (-0.05)

jq '
  .values.binder_who_smiles = ((.values.binder_who_smiles // 0) + 0.30 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.iron_promise = ((.values.iron_promise // 0) + 0.20 | if . > 1 then 1 elif . < -1 then -1 else . end) |
  .values.soft_betrayal = ((.values.soft_betrayal // 0) - 0.05 | if . > 1 then 1 elif . < -1 then -1 else . end)
'
