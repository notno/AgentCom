#!/bin/bash
# Example: Run a spell pipeline via HTTP API
#
# Usage: ./run_spell.sh [host:port]
#
# Requires: curl, jq

HOST="${1:-localhost:4000}"

echo "🔮 Running spell: fire |> ignite |> hush |> veil |> commit |> emit"
echo ""

curl -s -X POST "http://${HOST}/api/pipeline/run" \
  -H "Content-Type: application/json" \
  -d '{
    "steps": [
      {"type": "source", "name": "fire", "pattern": {"spark_lord": 0.8, "ember_heart": 0.3}},
      {"type": "bash", "script": "priv/operators/ignite.sh"},
      {"type": "bash", "script": "priv/operators/hush.sh"},
      {"type": "bash", "script": "priv/operators/veil.sh"},
      {"type": "commit"},
      {"type": "emit"}
    ]
  }' | jq '.'

echo ""
echo "✨ Spell complete"
