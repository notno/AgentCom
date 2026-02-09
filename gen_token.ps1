$body = @{agent_id = "flere-imsaho"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://127.0.0.1:4000/admin/tokens" -Method Post -ContentType "application/json" -Body $body | ConvertTo-Json
