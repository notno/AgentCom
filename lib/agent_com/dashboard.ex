defmodule AgentCom.Dashboard do
  @moduledoc """
  Serves the analytics dashboard as a simple self-contained HTML page.
  No external dependencies — inline CSS + JS, auto-refreshes every 30s.
  """

  def render do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>AgentCom Dashboard</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0a0a0f; color: #e0e0e0; padding: 20px; }
        h1 { color: #7eb8da; margin-bottom: 4px; font-size: 1.5em; }
        .subtitle { color: #666; margin-bottom: 20px; font-size: 0.85em; }
        .summary { display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }
        .card { background: #141420; border: 1px solid #2a2a3a; border-radius: 8px; padding: 16px 20px; min-width: 140px; }
        .card .value { font-size: 2em; font-weight: 700; color: #7eb8da; }
        .card .label { font-size: 0.8em; color: #888; margin-top: 4px; }
        table { width: 100%; border-collapse: collapse; background: #141420; border-radius: 8px; overflow: hidden; }
        th { background: #1a1a2e; color: #7eb8da; text-align: left; padding: 12px 16px; font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.5px; }
        td { padding: 10px 16px; border-top: 1px solid #1a1a2e; font-size: 0.9em; }
        tr:hover td { background: #1a1a2e; }
        .status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
        .status.active { background: #4ade80; }
        .status.idle { background: #fbbf24; }
        .status.offline { background: #666; }
        .bar { display: inline-block; height: 14px; background: #7eb8da; border-radius: 2px; min-width: 2px; opacity: 0.8; }
        .bar.received { background: #a78bfa; }
        .time { color: #888; font-size: 0.85em; }
        .refresh { color: #444; font-size: 0.75em; margin-top: 16px; }
        @media (max-width: 600px) { .summary { flex-direction: column; } .card { min-width: auto; } }
      </style>
    </head>
    <body>
      <h1>🔷 AgentCom</h1>
      <p class="subtitle">Culture Mind Activity Dashboard</p>
      <div id="summary" class="summary"></div>
      <table>
        <thead><tr>
          <th>Agent</th><th>Status</th><th>Sent (24h)</th><th>Recv (24h)</th><th>This Hour</th><th>Last Active</th><th>Connections</th>
        </tr></thead>
        <tbody id="agents"></tbody>
      </table>
      <p class="refresh" id="refresh"></p>
      <script>
        function timeAgo(ms) {
          if (!ms) return '—';
          const sec = Math.floor((Date.now() - ms) / 1000);
          if (sec < 60) return sec + 's ago';
          if (sec < 3600) return Math.floor(sec/60) + 'm ago';
          if (sec < 86400) return Math.floor(sec/3600) + 'h ago';
          return Math.floor(sec/86400) + 'd ago';
        }
        async function refresh() {
          try {
            const [summary, agents] = await Promise.all([
              fetch('/api/analytics/summary').then(r=>r.json()),
              fetch('/api/analytics/agents').then(r=>r.json())
            ]);
            document.getElementById('summary').innerHTML = `
              <div class="card"><div class="value">${summary.total_agents}</div><div class="label">Total Minds</div></div>
              <div class="card"><div class="value">${summary.agents_connected}</div><div class="label">Connected</div></div>
              <div class="card"><div class="value">${summary.agents_active}</div><div class="label">Active</div></div>
              <div class="card"><div class="value">${summary.total_messages_24h}</div><div class="label">Messages (24h)</div></div>
            `;
            const maxSent = Math.max(1, ...agents.agents.map(a=>a.messages_sent_24h));
            document.getElementById('agents').innerHTML = agents.agents.map(a => `<tr>
              <td><strong>${a.agent_id}</strong></td>
              <td><span class="status ${a.status}"></span>${a.status}</td>
              <td><span class="bar" style="width:${Math.max(2,a.messages_sent_24h/maxSent*100)}px"></span> ${a.messages_sent_24h}</td>
              <td><span class="bar received" style="width:${Math.max(2,a.messages_received_24h/maxSent*100)}px"></span> ${a.messages_received_24h}</td>
              <td>${a.messages_sent_this_hour}</td>
              <td class="time">${timeAgo(a.last_active)}</td>
              <td>${a.total_connections}</td>
            </tr>`).join('');
            document.getElementById('refresh').textContent = 'Last refresh: ' + new Date().toLocaleTimeString() + ' (auto-refreshes every 30s)';
          } catch(e) { console.error('Dashboard refresh failed:', e); }
        }
        refresh();
        setInterval(refresh, 30000);
      </script>
    </body>
    </html>
    """
  end
end
