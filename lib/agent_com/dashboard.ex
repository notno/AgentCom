defmodule AgentCom.Dashboard do
  @moduledoc """
  Serves the AgentCom Command Center dashboard as a self-contained HTML page.
  No external dependencies -- inline CSS + vanilla JS with WebSocket for real-time updates.
  Connects to /ws/dashboard for live state push with exponential backoff reconnect.
  """

  @doc "Returns the service worker JavaScript for handling push notifications."
  def service_worker do
    """
    self.addEventListener('push', function(event) {
      const data = event.data ? event.data.json() : {title: 'AgentCom', body: 'New notification'};
      event.waitUntil(
        self.registration.showNotification(data.title, {
          body: data.body,
          icon: data.icon || '/favicon.ico',
          badge: data.badge,
          tag: 'agentcom-alert',
          renotify: true
        })
      );
    });

    self.addEventListener('notificationclick', function(event) {
      event.notification.close();
      event.waitUntil(
        clients.matchAll({type: 'window'}).then(function(clientList) {
          for (var i = 0; i < clientList.length; i++) {
            if (clientList[i].url.includes('/dashboard') && 'focus' in clientList[i]) {
              return clientList[i].focus();
            }
          }
          if (clients.openWindow) {
            return clients.openWindow('/dashboard');
          }
        })
      );
    });
    """
  end

  def render do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>AgentCom Command Center</title>
      <style>
        /* === Reset & Base === */
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
          background: #0a0a0f; color: #e0e0e0; padding: 16px; line-height: 1.4;
          min-height: 100vh;
        }
        a { color: #7eb8da; text-decoration: none; }
        a:hover { text-decoration: underline; }

        /* === Header Bar === */
        .header {
          background: #141420; border: 1px solid #2a2a3a; border-radius: 8px;
          padding: 16px 20px; margin-bottom: 12px;
        }
        .header-top {
          display: flex; align-items: center; justify-content: space-between;
          flex-wrap: wrap; gap: 12px;
        }
        .header-title {
          font-size: 1.4em; font-weight: 700; color: #7eb8da;
          display: flex; align-items: center; gap: 8px;
        }
        .header-metrics {
          display: flex; align-items: center; gap: 20px; flex-wrap: wrap;
        }
        .header-metric {
          display: flex; flex-direction: column; align-items: center;
        }
        .header-metric .hm-value {
          font-size: 1.4em; font-weight: 700; color: #7eb8da;
          transition: transform 0.2s ease;
        }
        .header-metric .hm-value.bumped { transform: scale(1.15); }
        .header-metric .hm-label {
          font-size: 0.7em; color: #888; text-transform: uppercase; letter-spacing: 0.5px;
        }
        .health-badge {
          display: flex; align-items: center; gap: 6px; padding: 4px 10px;
          border-radius: 12px; font-size: 0.8em; cursor: pointer;
          background: rgba(74, 222, 128, 0.1); border: 1px solid rgba(74, 222, 128, 0.3);
        }
        .health-badge.warning {
          background: rgba(251, 191, 36, 0.1); border-color: rgba(251, 191, 36, 0.3);
        }
        .health-badge.critical {
          background: rgba(239, 68, 68, 0.1); border-color: rgba(239, 68, 68, 0.3);
        }
        .health-conditions {
          display: none; margin-top: 8px; padding: 8px 12px;
          background: #1a1a2e; border-radius: 6px; font-size: 0.8em; color: #ccc;
        }
        .health-conditions.visible { display: block; }
        .health-conditions li { margin: 4px 0; list-style: disc inside; }

        /* === Connection Status === */
        .conn-bar {
          display: flex; align-items: center; justify-content: space-between;
          background: #141420; border: 1px solid #2a2a3a; border-radius: 8px;
          padding: 8px 16px; margin-bottom: 12px; font-size: 0.8em;
        }
        .conn-status { display: flex; align-items: center; gap: 6px; }
        .conn-dot {
          width: 8px; height: 8px; border-radius: 50%; background: #fbbf24;
          transition: background-color 0.3s ease;
        }
        .conn-dot.connected { background: #4ade80; }
        .conn-dot.disconnected { background: #ef4444; animation: pulse 1.5s infinite; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
        .conn-text { color: #aaa; }
        .last-update { color: #666; }

        /* === Grid Layout === */
        .grid {
          display: grid;
          grid-template-columns: 1fr 1fr 1fr;
          gap: 12px;
          margin-bottom: 12px;
        }
        .grid-bottom {
          display: grid;
          grid-template-columns: 2fr 1fr;
          gap: 12px;
        }
        @media (max-width: 1200px) {
          .grid { grid-template-columns: 1fr 1fr; }
          .grid-bottom { grid-template-columns: 1fr; }
        }
        @media (max-width: 768px) {
          .grid { grid-template-columns: 1fr; }
        }

        /* === Panels === */
        .panel {
          background: #141420; border: 1px solid #2a2a3a; border-radius: 8px;
          padding: 14px 16px; overflow: hidden;
        }
        .panel.dead-letter { border-color: rgba(239, 68, 68, 0.4); }
        .panel-title {
          font-size: 0.75em; text-transform: uppercase; letter-spacing: 1px;
          color: #7eb8da; margin-bottom: 10px; font-weight: 600;
        }
        .panel-title .panel-count {
          font-size: 1.1em; color: #e0e0e0; margin-left: 6px;
        }

        /* === Tables === */
        table { width: 100%; border-collapse: collapse; }
        th {
          background: #1a1a2e; color: #7eb8da; text-align: left;
          padding: 8px 10px; font-size: 0.72em; text-transform: uppercase;
          letter-spacing: 0.5px; white-space: nowrap; cursor: pointer;
          user-select: none;
        }
        th:hover { background: #222240; }
        th .sort-arrow { margin-left: 4px; font-size: 0.9em; opacity: 0.5; }
        th .sort-arrow.active { opacity: 1; }
        td {
          padding: 7px 10px; border-top: 1px solid #1a1a2e;
          font-size: 0.82em; white-space: nowrap; overflow: hidden;
          text-overflow: ellipsis; max-width: 200px;
          transition: background-color 0.3s ease;
        }
        tr:hover td { background: #1a1a2e; }

        /* === Status Dots === */
        .dot {
          display: inline-block; width: 8px; height: 8px; border-radius: 50%;
          margin-right: 5px; vertical-align: middle;
        }
        .dot.idle, .dot.connected { background: #4ade80; }
        .dot.assigned, .dot.warning { background: #fbbf24; }
        .dot.working { background: #60a5fa; }
        .dot.blocked { background: #f97316; }
        .dot.offline, .dot.unknown { background: #666; }
        .dot.ok { background: #4ade80; }
        .dot.critical { background: #ef4444; }

        /* === Status Badges === */
        .badge {
          display: inline-block; padding: 2px 8px; border-radius: 10px;
          font-size: 0.75em; font-weight: 600; text-transform: uppercase;
        }
        .badge.queued { background: rgba(96, 165, 250, 0.15); color: #60a5fa; }
        .badge.assigned { background: rgba(251, 191, 36, 0.15); color: #fbbf24; }
        .badge.completed { background: rgba(74, 222, 128, 0.15); color: #4ade80; }
        .badge.failed, .badge.dead_letter { background: rgba(239, 68, 68, 0.15); color: #ef4444; }

        /* === Queue Cards === */
        .queue-cards { display: flex; gap: 10px; margin-bottom: 10px; flex-wrap: wrap; }
        .queue-card {
          flex: 1; min-width: 70px; text-align: center; padding: 10px 8px;
          border-radius: 6px; background: #1a1a2e;
        }
        .queue-card .qc-count {
          font-size: 1.6em; font-weight: 700;
          transition: transform 0.2s ease;
        }
        .queue-card .qc-count.bumped { transform: scale(1.15); }
        .queue-card .qc-label {
          font-size: 0.65em; text-transform: uppercase; letter-spacing: 0.5px;
          margin-top: 2px;
        }
        .queue-card.urgent { border: 1px solid rgba(239, 68, 68, 0.4); }
        .queue-card.urgent .qc-count { color: #ef4444; }
        .queue-card.urgent .qc-label { color: #ef4444; }
        .queue-card.high { border: 1px solid rgba(249, 115, 22, 0.4); }
        .queue-card.high .qc-count { color: #f97316; }
        .queue-card.high .qc-label { color: #f97316; }
        .queue-card.normal { border: 1px solid rgba(96, 165, 250, 0.4); }
        .queue-card.normal .qc-count { color: #60a5fa; }
        .queue-card.normal .qc-label { color: #60a5fa; }
        .queue-card.low { border: 1px solid rgba(102, 102, 102, 0.4); }
        .queue-card.low .qc-count { color: #888; }
        .queue-card.low .qc-label { color: #888; }

        .expand-btn {
          display: inline-block; background: none; border: 1px solid #2a2a3a;
          color: #7eb8da; padding: 4px 10px; border-radius: 4px; font-size: 0.75em;
          cursor: pointer; margin-top: 6px;
        }
        .expand-btn:hover { background: #1a1a2e; }
        .queued-list { display: none; margin-top: 8px; }
        .queued-list.visible { display: block; }

        /* === Throughput Cards === */
        .throughput-cards { display: flex; flex-direction: column; gap: 10px; }
        .tp-card {
          text-align: center; padding: 14px 10px;
          background: #1a1a2e; border-radius: 6px;
        }
        .tp-card .tp-value {
          font-size: 1.8em; font-weight: 700; color: #7eb8da;
          transition: transform 0.2s ease;
        }
        .tp-card .tp-value.bumped { transform: scale(1.15); }
        .tp-card .tp-label {
          font-size: 0.65em; text-transform: uppercase; color: #888;
          letter-spacing: 0.5px; margin-top: 2px;
        }

        /* === Filter Input === */
        .filter-row {
          display: flex; align-items: center; gap: 8px; margin-bottom: 8px;
        }
        .filter-input {
          flex: 1; background: #1a1a2e; border: 1px solid #2a2a3a; color: #e0e0e0;
          padding: 6px 10px; border-radius: 4px; font-size: 0.8em;
          outline: none;
        }
        .filter-input:focus { border-color: #7eb8da; }
        .filter-input::placeholder { color: #555; }

        /* === Retry Button === */
        .btn-retry {
          background: none; border: 1px solid #ef4444; color: #ef4444;
          padding: 3px 8px; border-radius: 4px; font-size: 0.72em;
          cursor: pointer; transition: all 0.2s ease;
        }
        .btn-retry:hover { background: rgba(239, 68, 68, 0.15); }
        .btn-retry.success {
          border-color: #4ade80; color: #4ade80;
          background: rgba(74, 222, 128, 0.15);
        }
        .btn-retry.failed {
          border-color: #ef4444; color: #ef4444;
          background: rgba(239, 68, 68, 0.3);
        }

        /* === Flash Animation === */
        .flash { background-color: rgba(126, 184, 218, 0.3) !important; }
        tr, .panel, .queue-card, .tp-card { transition: background-color 0.3s ease; }

        /* === Empty State === */
        .empty-state {
          text-align: center; color: #555; padding: 20px; font-size: 0.85em;
        }

        /* === Notification Button === */
        .notif-btn {
          background: none; border: 1px solid #7eb8da; color: #7eb8da;
          padding: 5px 12px; border-radius: 4px; font-size: 0.8em;
          cursor: pointer; transition: all 0.2s ease;
        }
        .notif-btn:hover { background: rgba(126, 184, 218, 0.15); }
        .notif-status {
          font-size: 0.7em; color: #888; margin-left: 8px;
        }
        .notif-status.blocked { color: #ef4444; }
        .notif-status.active { color: #4ade80; }

        /* === Scrollable table wrapper === */
        .table-wrap { overflow-x: auto; max-height: 400px; overflow-y: auto; }
        .table-wrap::-webkit-scrollbar { width: 6px; height: 6px; }
        .table-wrap::-webkit-scrollbar-track { background: #0a0a0f; }
        .table-wrap::-webkit-scrollbar-thumb { background: #2a2a3a; border-radius: 3px; }
      </style>
    </head>
    <body>

      <!-- Header Bar -->
      <div class="header">
        <div class="header-top">
          <div class="header-title">AgentCom Command Center</div>
          <div style="display: flex; align-items: center; gap: 8px;">
            <button id="notif-btn" class="notif-btn" style="display:none" onclick="enableNotifications()">Enable Notifications</button>
            <span id="notif-status" class="notif-status"></span>
          </div>
          <div class="header-metrics">
            <div id="health-badge" class="health-badge" onclick="toggleHealthConditions()">
              <span class="dot ok" id="health-dot"></span>
              <span id="health-text">Healthy</span>
            </div>
            <div class="header-metric">
              <span class="hm-value" id="hm-uptime">--</span>
              <span class="hm-label">Uptime</span>
            </div>
            <div class="header-metric">
              <span class="hm-value" id="hm-agents">0</span>
              <span class="hm-label">Agents</span>
            </div>
            <div class="header-metric">
              <span class="hm-value" id="hm-queued">0</span>
              <span class="hm-label">Queued</span>
            </div>
            <div class="header-metric">
              <span class="hm-value" id="hm-throughput">0/hr</span>
              <span class="hm-label">Throughput</span>
            </div>
          </div>
        </div>
        <ul class="health-conditions" id="health-conditions"></ul>
      </div>

      <!-- Connection Bar -->
      <div class="conn-bar">
        <div class="conn-status">
          <span class="conn-dot" id="conn-dot"></span>
          <span class="conn-text" id="conn-text">Connecting...</span>
        </div>
        <span class="last-update" id="last-update">--</span>
      </div>

      <!-- Top Grid: Agents | Queue Summary | Throughput -->
      <div class="grid">
        <div class="panel" id="panel-agents">
          <div class="panel-title">Agents <span class="panel-count" id="agent-count">0</span></div>
          <div class="table-wrap">
            <table id="agent-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>State</th>
                  <th>Current Task</th>
                  <th>Capabilities</th>
                  <th>Last Seen</th>
                </tr>
              </thead>
              <tbody id="agent-tbody"></tbody>
            </table>
          </div>
          <div class="empty-state" id="agents-empty">No agents connected</div>
        </div>

        <div class="panel" id="panel-queue">
          <div class="panel-title">Queue Summary</div>
          <div class="queue-cards">
            <div class="queue-card urgent">
              <div class="qc-count" id="q-urgent" data-priority="0">0</div>
              <div class="qc-label">Urgent</div>
            </div>
            <div class="queue-card high">
              <div class="qc-count" id="q-high" data-priority="1">0</div>
              <div class="qc-label">High</div>
            </div>
            <div class="queue-card normal">
              <div class="qc-count" id="q-normal" data-priority="2">0</div>
              <div class="qc-label">Normal</div>
            </div>
            <div class="queue-card low">
              <div class="qc-count" id="q-low" data-priority="3">0</div>
              <div class="qc-label">Low</div>
            </div>
          </div>
          <button class="expand-btn" id="queue-expand-btn" onclick="toggleQueuedList()">
            Show 0 queued tasks
          </button>
          <div class="queued-list" id="queued-list">
            <div class="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Description</th>
                    <th>Priority</th>
                    <th>Submitted By</th>
                    <th>Created</th>
                    <th>PR</th>
                  </tr>
                </thead>
                <tbody id="queued-tbody"></tbody>
              </table>
            </div>
          </div>
        </div>

        <div class="panel" id="panel-throughput">
          <div class="panel-title">Throughput (Last Hour)</div>
          <div class="throughput-cards">
            <div class="tp-card">
              <div class="tp-value" id="tp-completed">0</div>
              <div class="tp-label">Tasks Completed</div>
            </div>
            <div class="tp-card">
              <div class="tp-value" id="tp-avg-time">--</div>
              <div class="tp-label">Avg Completion</div>
            </div>
            <div class="tp-card">
              <div class="tp-value" id="tp-tokens">0</div>
              <div class="tp-label">Tokens Used</div>
            </div>
          </div>
        </div>
      </div>

      <!-- Bottom Grid: Recent Tasks | Dead Letter -->
      <div class="grid-bottom">
        <div class="panel" id="panel-recent">
          <div class="panel-title">Recent Tasks <span class="panel-count" id="recent-count">0</span></div>
          <div class="filter-row">
            <input type="text" class="filter-input" id="task-filter"
                   placeholder="Filter tasks..." oninput="filterRecentTasks()">
          </div>
          <div class="table-wrap">
            <table id="recent-table">
              <thead>
                <tr>
                  <th onclick="sortTable('recent-table', 0)">Task <span class="sort-arrow" id="sort-0"></span></th>
                  <th onclick="sortTable('recent-table', 1)">Agent <span class="sort-arrow" id="sort-1"></span></th>
                  <th onclick="sortTable('recent-table', 2)">Status <span class="sort-arrow" id="sort-2"></span></th>
                  <th onclick="sortTable('recent-table', 3)">Duration <span class="sort-arrow" id="sort-3"></span></th>
                  <th onclick="sortTable('recent-table', 4)">Tokens <span class="sort-arrow" id="sort-4"></span></th>
                  <th onclick="sortTable('recent-table', 5)">PR <span class="sort-arrow" id="sort-5"></span></th>
                  <th onclick="sortTable('recent-table', 6)">Completed <span class="sort-arrow active" id="sort-6">&#9660;</span></th>
                </tr>
              </thead>
              <tbody id="recent-tbody"></tbody>
            </table>
          </div>
          <div class="empty-state" id="recent-empty">No recent tasks</div>
        </div>

        <div class="panel dead-letter" id="panel-deadletter">
          <div class="panel-title" style="color: #ef4444;">
            Dead Letter <span class="panel-count" id="dl-count">0</span>
          </div>
          <div class="table-wrap">
            <table id="dl-table">
              <thead>
                <tr>
                  <th>Task</th>
                  <th>Error</th>
                  <th>Retries</th>
                  <th>Created</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody id="dl-tbody"></tbody>
            </table>
          </div>
          <div class="empty-state" id="dl-empty">No dead-letter tasks</div>
        </div>
      </div>

      <!-- DETS Storage Health -->
      <div style="margin-top: 12px;">
        <div class="panel" id="panel-dets">
          <div class="panel-title">DETS Storage Health</div>
          <div class="table-wrap">
            <table id="dets-table">
              <thead>
                <tr>
                  <th>Table</th>
                  <th>Records</th>
                  <th>File Size</th>
                  <th>Fragmentation</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody id="dets-tbody"></tbody>
            </table>
          </div>
          <div style="margin-top: 8px; font-size: 0.8em; color: #888;" id="dets-backup-info">
            Last backup: --
          </div>
          <div class="empty-state" id="dets-empty">No DETS health data</div>
        </div>
      </div>

      <script>
        // =====================================================================
        // State
        // =====================================================================
        let dashState = null;
        let sortCol = 6;
        let sortAsc = false;
        let reconnectCount = 0;

        // =====================================================================
        // Utility functions
        // =====================================================================
        function timeAgo(ms) {
          if (!ms) return '--';
          const sec = Math.floor((Date.now() - ms) / 1000);
          if (sec < 0) return 'just now';
          if (sec < 60) return sec + 's ago';
          if (sec < 3600) return Math.floor(sec / 60) + 'm ago';
          if (sec < 86400) return Math.floor(sec / 3600) + 'h ago';
          return Math.floor(sec / 86400) + 'd ago';
        }

        function formatDuration(ms) {
          if (!ms || ms <= 0) return '--';
          const totalSec = Math.floor(ms / 1000);
          const m = Math.floor(totalSec / 60);
          const s = totalSec % 60;
          if (m > 0) return m + 'm ' + s + 's';
          return s + 's';
        }

        function formatUptime(ms) {
          if (!ms || ms <= 0) return '--';
          const totalSec = Math.floor(ms / 1000);
          const d = Math.floor(totalSec / 86400);
          const h = Math.floor((totalSec % 86400) / 3600);
          const m = Math.floor((totalSec % 3600) / 60);
          let parts = [];
          if (d > 0) parts.push(d + 'd');
          if (h > 0 || d > 0) parts.push(h + 'h');
          parts.push(m + 'm');
          return parts.join(' ');
        }

        function flashElement(el) {
          if (!el) return;
          el.classList.add('flash');
          setTimeout(function() { el.classList.remove('flash'); }, 1500);
        }

        function bumpCount(el) {
          if (!el) return;
          el.classList.add('bumped');
          setTimeout(function() { el.classList.remove('bumped'); }, 200);
        }

        function escapeHtml(str) {
          if (!str) return '';
          return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        function truncate(str, len) {
          if (!str) return '--';
          str = String(str);
          return str.length > len ? str.substring(0, len) + '...' : str;
        }

        function priorityName(p) {
          var names = {0: 'urgent', 1: 'high', 2: 'normal', 3: 'low'};
          return names[p] || 'normal';
        }

        function fsmStateClass(s) {
          if (!s) return 'unknown';
          return String(s).replace(':', '');
        }

        function formatTime(ms) {
          if (!ms) return '--';
          return new Date(ms).toLocaleTimeString();
        }

        // =====================================================================
        // Connection indicator
        // =====================================================================
        function setConnectionStatus(status) {
          var dot = document.getElementById('conn-dot');
          var text = document.getElementById('conn-text');
          dot.className = 'conn-dot ' + status;
          if (status === 'connected') {
            text.textContent = 'Connected';
          } else if (status === 'disconnected') {
            text.textContent = 'Disconnected';
          } else {
            text.textContent = 'Connecting...';
          }
        }

        function updateLastUpdate() {
          document.getElementById('last-update').textContent =
            'Last update: ' + new Date().toLocaleTimeString();
        }

        // =====================================================================
        // Health toggle
        // =====================================================================
        function toggleHealthConditions() {
          var el = document.getElementById('health-conditions');
          el.classList.toggle('visible');
        }

        // =====================================================================
        // Queue expand toggle
        // =====================================================================
        function toggleQueuedList() {
          var el = document.getElementById('queued-list');
          el.classList.toggle('visible');
          var btn = document.getElementById('queue-expand-btn');
          if (el.classList.contains('visible')) {
            btn.textContent = 'Hide queued tasks';
          } else {
            btn.textContent = btn.getAttribute('data-label') || 'Show 0 queued tasks';
          }
        }

        // =====================================================================
        // Render full state (snapshot)
        // =====================================================================
        function renderFullState(data) {
          dashState = data;

          // -- Header metrics --
          document.getElementById('hm-uptime').textContent = formatUptime(data.uptime_ms);
          var agentEl = document.getElementById('hm-agents');
          agentEl.textContent = (data.agents || []).length;
          bumpCount(agentEl);

          var totalQueued = (data.queue && data.queue.by_status) ? (data.queue.by_status.queued || 0) : 0;
          var queuedEl = document.getElementById('hm-queued');
          queuedEl.textContent = totalQueued;
          bumpCount(queuedEl);

          var tpEl = document.getElementById('hm-throughput');
          tpEl.textContent = ((data.throughput || {}).completed_last_hour || 0) + '/hr';
          bumpCount(tpEl);

          // -- Health --
          renderHealth(data.health || {status: 'ok', conditions: []});

          // -- Agent table --
          renderAgentTable(data.agents || []);

          // -- Queue summary --
          renderQueueSummary(data.queue || {});

          // -- Throughput --
          renderThroughput(data.throughput || {});

          // -- Recent tasks --
          renderRecentTasks(data.recent_completions || []);

          // -- Dead letter --
          renderDeadLetter(data.dead_letter_tasks || []);

          // -- DETS health --
          renderDetsHealth(data.dets_health || null);

          updateLastUpdate();
        }

        // =====================================================================
        // Health
        // =====================================================================
        function renderHealth(health) {
          var badge = document.getElementById('health-badge');
          var dot = document.getElementById('health-dot');
          var text = document.getElementById('health-text');
          var conditions = document.getElementById('health-conditions');

          var status = health.status || 'ok';
          badge.className = 'health-badge' + (status !== 'ok' ? ' ' + status : '');
          dot.className = 'dot ' + status;

          if (status === 'ok') {
            text.textContent = 'Healthy';
          } else if (status === 'warning') {
            text.textContent = 'Warning -- ' + (health.conditions || []).length + ' condition(s)';
          } else if (status === 'critical') {
            text.textContent = 'Critical -- ' + ((health.conditions || [])[0] || 'see details');
          }

          conditions.innerHTML = (health.conditions || []).map(function(c) {
            return '<li>' + escapeHtml(c) + '</li>';
          }).join('');
        }

        // =====================================================================
        // Agent table
        // =====================================================================
        function renderAgentTable(agents) {
          var tbody = document.getElementById('agent-tbody');
          var empty = document.getElementById('agents-empty');
          var count = document.getElementById('agent-count');
          count.textContent = agents.length;

          if (agents.length === 0) {
            tbody.innerHTML = '';
            empty.style.display = 'block';
            return;
          }
          empty.style.display = 'none';

          tbody.innerHTML = agents.map(function(a) {
            var stateStr = fsmStateClass(a.fsm_state);
            var caps = (a.capabilities || []).map(function(c) {
              return typeof c === 'object' ? (c.name || JSON.stringify(c)) : String(c);
            }).join(', ') || '--';
            var taskSnippet = a.current_task_id ? truncate(a.current_task_id, 20) : '--';
            var name = escapeHtml(a.name || a.agent_id);

            return '<tr data-agent-id="' + escapeHtml(a.agent_id) + '">' +
              '<td title="' + escapeHtml(a.agent_id) + '">' + name + '</td>' +
              '<td><span class="dot ' + stateStr + '"></span>' + stateStr + '</td>' +
              '<td title="' + escapeHtml(a.current_task_id || '') + '">' + taskSnippet + '</td>' +
              '<td>' + escapeHtml(caps) + '</td>' +
              '<td>' + timeAgo(a.connected_at || a.last_state_change) + '</td>' +
              '</tr>';
          }).join('');
        }

        // =====================================================================
        // Queue summary
        // =====================================================================
        function renderQueueSummary(queue) {
          var byPriority = queue.by_priority || {};
          var byStatus = queue.by_status || {};

          var priorities = [
            {id: 'q-urgent', key: '0', fallback: 0},
            {id: 'q-high', key: '1', fallback: 0},
            {id: 'q-normal', key: '2', fallback: 0},
            {id: 'q-low', key: '3', fallback: 0}
          ];

          var totalQueued = 0;
          priorities.forEach(function(p) {
            var el = document.getElementById(p.id);
            var val = byPriority[p.key] || byPriority[parseInt(p.key)] || p.fallback;
            totalQueued += val;
            if (el.textContent !== String(val)) {
              el.textContent = val;
              bumpCount(el);
            }
          });

          var btn = document.getElementById('queue-expand-btn');
          btn.setAttribute('data-label', 'Show ' + totalQueued + ' queued tasks');
          if (!document.getElementById('queued-list').classList.contains('visible')) {
            btn.textContent = 'Show ' + totalQueued + ' queued tasks';
          }
        }

        function renderQueuedTaskList(tasks) {
          var tbody = document.getElementById('queued-tbody');
          if (!tasks || tasks.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="empty-state">No queued tasks</td></tr>';
            return;
          }
          tbody.innerHTML = tasks.map(function(t) {
            return '<tr data-task-id="' + escapeHtml(t.id || t.task_id) + '">' +
              '<td>' + escapeHtml(truncate(t.description, 40)) + '</td>' +
              '<td>' + priorityName(t.priority) + '</td>' +
              '<td>' + escapeHtml(t.submitted_by || '--') + '</td>' +
              '<td>' + timeAgo(t.created_at) + '</td>' +
              '<td>---</td>' +
              '</tr>';
          }).join('');
        }

        // =====================================================================
        // Throughput
        // =====================================================================
        function renderThroughput(tp) {
          var comp = document.getElementById('tp-completed');
          var newVal = String(tp.completed_last_hour || 0);
          if (comp.textContent !== newVal) {
            comp.textContent = newVal;
            bumpCount(comp);
          }

          document.getElementById('tp-avg-time').textContent =
            formatDuration(tp.avg_completion_ms);

          var tokEl = document.getElementById('tp-tokens');
          var tokVal = String(tp.total_tokens_hour || 0);
          if (tokEl.textContent !== tokVal) {
            tokEl.textContent = tokVal;
            bumpCount(tokEl);
          }
        }

        // =====================================================================
        // Recent tasks (sortable, filterable)
        // =====================================================================
        var recentData = [];

        function renderRecentTasks(completions) {
          recentData = completions;
          doRenderRecent();
        }

        function doRenderRecent() {
          var tbody = document.getElementById('recent-tbody');
          var empty = document.getElementById('recent-empty');
          var count = document.getElementById('recent-count');

          var filter = (document.getElementById('task-filter').value || '').toLowerCase();
          var filtered = recentData;
          if (filter) {
            filtered = recentData.filter(function(c) {
              return (c.description || '').toLowerCase().indexOf(filter) !== -1 ||
                     (c.agent_id || '').toLowerCase().indexOf(filter) !== -1 ||
                     (c.task_id || '').toLowerCase().indexOf(filter) !== -1;
            });
          }

          // Sort
          filtered = filtered.slice().sort(function(a, b) {
            var aVal, bVal;
            switch (sortCol) {
              case 0: aVal = a.description || ''; bVal = b.description || ''; break;
              case 1: aVal = a.agent_id || ''; bVal = b.agent_id || ''; break;
              case 2: aVal = 'completed'; bVal = 'completed'; break;
              case 3: aVal = a.duration_ms || 0; bVal = b.duration_ms || 0; break;
              case 4: aVal = a.tokens_used || 0; bVal = b.tokens_used || 0; break;
              case 5: aVal = ''; bVal = ''; break;
              case 6: aVal = a.completed_at || 0; bVal = b.completed_at || 0; break;
              default: aVal = 0; bVal = 0;
            }
            if (typeof aVal === 'string') {
              var cmp = aVal.localeCompare(bVal);
              return sortAsc ? cmp : -cmp;
            }
            return sortAsc ? aVal - bVal : bVal - aVal;
          });

          count.textContent = filtered.length;

          if (filtered.length === 0) {
            tbody.innerHTML = '';
            empty.style.display = 'block';
            return;
          }
          empty.style.display = 'none';

          tbody.innerHTML = filtered.map(function(c) {
            return '<tr data-task-id="' + escapeHtml(c.task_id) + '">' +
              '<td title="' + escapeHtml(c.description) + '">' + escapeHtml(truncate(c.description, 35)) + '</td>' +
              '<td>' + escapeHtml(c.agent_id || '--') + '</td>' +
              '<td><span class="badge completed">completed</span></td>' +
              '<td data-sort="' + (c.duration_ms || 0) + '">' + formatDuration(c.duration_ms) + '</td>' +
              '<td>' + (c.tokens_used || 0) + '</td>' +
              '<td>---</td>' +
              '<td data-sort="' + (c.completed_at || 0) + '">' + timeAgo(c.completed_at) + '</td>' +
              '</tr>';
          }).join('');
        }

        function sortTable(tableId, colIndex) {
          if (sortCol === colIndex) {
            sortAsc = !sortAsc;
          } else {
            sortCol = colIndex;
            sortAsc = true;
          }

          // Update sort arrows
          for (var i = 0; i <= 6; i++) {
            var arrow = document.getElementById('sort-' + i);
            if (arrow) {
              if (i === colIndex) {
                arrow.innerHTML = sortAsc ? '&#9650;' : '&#9660;';
                arrow.className = 'sort-arrow active';
              } else {
                arrow.innerHTML = '';
                arrow.className = 'sort-arrow';
              }
            }
          }

          doRenderRecent();
        }

        function filterRecentTasks() {
          doRenderRecent();
        }

        // =====================================================================
        // Dead letter
        // =====================================================================
        function renderDeadLetter(tasks) {
          var tbody = document.getElementById('dl-tbody');
          var empty = document.getElementById('dl-empty');
          var count = document.getElementById('dl-count');
          count.textContent = tasks.length;

          if (tasks.length === 0) {
            tbody.innerHTML = '';
            empty.style.display = 'block';
            return;
          }
          empty.style.display = 'none';

          tbody.innerHTML = tasks.map(function(t) {
            return '<tr data-task-id="' + escapeHtml(t.id) + '">' +
              '<td title="' + escapeHtml(t.description) + '">' + escapeHtml(truncate(t.description, 25)) + '</td>' +
              '<td title="' + escapeHtml(t.last_error) + '">' + escapeHtml(truncate(t.last_error, 25)) + '</td>' +
              '<td>' + (t.retry_count || 0) + '</td>' +
              '<td>' + timeAgo(t.created_at) + '</td>' +
              '<td><button class="btn-retry" data-task-id="' + escapeHtml(t.id) + '" onclick="retryTask(this)">Retry</button></td>' +
              '</tr>';
          }).join('');
        }

        // =====================================================================
        // DETS health
        // =====================================================================
        function renderDetsHealth(detsHealth) {
          var panel = document.getElementById('panel-dets');
          var tbody = document.getElementById('dets-tbody');
          var empty = document.getElementById('dets-empty');
          var backupInfo = document.getElementById('dets-backup-info');

          if (!detsHealth || !detsHealth.tables) {
            tbody.innerHTML = '';
            empty.style.display = 'block';
            backupInfo.textContent = 'Last backup: --';
            return;
          }
          empty.style.display = 'none';

          tbody.innerHTML = detsHealth.tables.map(function(t) {
            var tableName = t.table || '--';
            var records = (t.status === 'ok' || t.status === 'available') ? t.record_count : '--';
            var fileSize = (t.status === 'ok' || t.status === 'available') ? formatFileSize(t.file_size_bytes) : '--';
            var frag = (t.status === 'ok' || t.status === 'available') ? (t.fragmentation_ratio * 100).toFixed(1) + '%' : '--';
            var fragClass = '';
            if (t.fragmentation_ratio > 0.5) fragClass = 'color: #ef4444; font-weight: 600;';
            else if (t.fragmentation_ratio > 0.3) fragClass = 'color: #fbbf24;';

            var statusDot = t.status === 'ok' ? 'ok' : 'offline';

            return '<tr>' +
              '<td>' + escapeHtml(tableName) + '</td>' +
              '<td>' + records + '</td>' +
              '<td>' + fileSize + '</td>' +
              '<td style="' + fragClass + '">' + frag + '</td>' +
              '<td><span class="dot ' + statusDot + '"></span>' + escapeHtml(String(t.status)) + '</td>' +
              '</tr>';
          }).join('');

          if (detsHealth.last_backup_at) {
            backupInfo.textContent = 'Last backup: ' + timeAgo(detsHealth.last_backup_at);
          } else {
            backupInfo.textContent = 'Last backup: never';
          }
        }

        function formatFileSize(bytes) {
          if (bytes == null) return '--';
          if (bytes < 1024) return bytes + ' B';
          if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
          return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
        }

        function retryTask(btn) {
          var taskId = btn.getAttribute('data-task-id');
          if (!taskId || !dashConn || !dashConn.ws || dashConn.ws.readyState !== 1) return;
          dashConn.ws.send(JSON.stringify({type: 'retry_task', task_id: taskId}));
          btn.textContent = 'Retrying...';
          btn.disabled = true;
        }

        function handleRetryResult(data) {
          var btn = document.querySelector('.btn-retry[data-task-id="' + data.task_id + '"]');
          if (!btn) return;
          btn.disabled = false;
          if (data.status === 'requeued') {
            btn.textContent = 'Requeued';
            btn.classList.add('success');
            flashElement(btn.closest('tr'));
            setTimeout(function() {
              btn.textContent = 'Retry';
              btn.classList.remove('success');
            }, 2000);
          } else {
            btn.textContent = 'Not Found';
            btn.classList.add('failed');
            setTimeout(function() {
              btn.textContent = 'Retry';
              btn.classList.remove('failed');
            }, 2000);
          }
        }

        // =====================================================================
        // Incremental event handlers
        // =====================================================================
        function handleEvents(events) {
          if (!events || !Array.isArray(events)) return;
          events.forEach(function(ev) {
            switch (ev.type) {
              case 'task_event': handleTaskEvent(ev); break;
              case 'agent_joined': handleAgentJoined(ev); break;
              case 'agent_left': handleAgentLeft(ev); break;
              case 'status_changed': handleStatusChanged(ev); break;
              case 'backup_complete':
                if (dashConn && dashConn.ws && dashConn.ws.readyState === 1) {
                  dashConn.ws.send(JSON.stringify({type: 'request_snapshot'}));
                }
                break;
            }
          });
          updateLastUpdate();
        }

        function handleTaskEvent(ev) {
          // Flash any existing row with this task_id
          var row = document.querySelector('[data-task-id="' + ev.task_id + '"]');
          if (row) flashElement(row);

          // Bump queue counts (re-request snapshot for accurate counts)
          // For efficiency we request a new snapshot on task events
          if (dashConn && dashConn.ws && dashConn.ws.readyState === 1) {
            dashConn.ws.send(JSON.stringify({type: 'request_snapshot'}));
          }
        }

        function handleAgentJoined(ev) {
          // Request fresh snapshot to get full agent data
          if (dashConn && dashConn.ws && dashConn.ws.readyState === 1) {
            dashConn.ws.send(JSON.stringify({type: 'request_snapshot'}));
          }
        }

        function handleAgentLeft(ev) {
          var row = document.querySelector('[data-agent-id="' + ev.agent_id + '"]');
          if (row) {
            flashElement(row);
            // Request snapshot to update
            if (dashConn && dashConn.ws && dashConn.ws.readyState === 1) {
              dashConn.ws.send(JSON.stringify({type: 'request_snapshot'}));
            }
          }
        }

        function handleStatusChanged(ev) {
          var row = document.querySelector('[data-agent-id="' + ev.agent_id + '"]');
          if (row) flashElement(row);
          // Request snapshot for updated state
          if (dashConn && dashConn.ws && dashConn.ws.readyState === 1) {
            dashConn.ws.send(JSON.stringify({type: 'request_snapshot'}));
          }
        }

        // =====================================================================
        // WebSocket connection with exponential backoff
        // =====================================================================
        function DashboardConnection() {
          this.reconnectDelay = 1000;
          this.maxDelay = 30000;
          this.ws = null;
          this.isReconnect = false;
          this.connect();
        }

        DashboardConnection.prototype.connect = function() {
          var self = this;
          var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
          this.ws = new WebSocket(proto + '//' + location.host + '/ws/dashboard');

          this.ws.onopen = function() {
            self.reconnectDelay = 1000;
            reconnectCount = 0;
            setConnectionStatus('connected');
            if (self.isReconnect) {
              self.ws.send(JSON.stringify({type: 'request_snapshot'}));
            }
            self.isReconnect = true;
          };

          this.ws.onclose = function() {
            setConnectionStatus('disconnected');
            reconnectCount++;
            var jitter = Math.random() * 0.3 * self.reconnectDelay;
            var delay = self.reconnectDelay + jitter;
            setTimeout(function() { self.connect(); }, delay);
            self.reconnectDelay = Math.min(self.maxDelay, self.reconnectDelay * 2);
          };

          this.ws.onerror = function() {
            // onclose will fire after onerror
          };

          this.ws.onmessage = function(event) {
            try {
              var msg = JSON.parse(event.data);
              switch (msg.type) {
                case 'snapshot':
                  renderFullState(msg.data);
                  break;
                case 'events':
                  handleEvents(msg.data);
                  break;
                case 'retry_result':
                  handleRetryResult(msg);
                  break;
              }
            } catch (e) {
              console.error('Dashboard: failed to parse message', e);
            }
          };
        };

        // =====================================================================
        // Initialize
        // =====================================================================
        var dashConn = new DashboardConnection();

        // =====================================================================
        // Push Notifications
        // =====================================================================
        function initNotifications() {
          if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
            // Browser doesn't support push notifications -- degrade gracefully
            return;
          }

          if (Notification.permission === 'granted') {
            // Already granted, auto-register
            registerServiceWorker();
            var status = document.getElementById('notif-status');
            status.textContent = 'Notifications active';
            status.className = 'notif-status active';
          } else if (Notification.permission === 'denied') {
            var status = document.getElementById('notif-status');
            status.textContent = 'Notifications blocked';
            status.className = 'notif-status blocked';
          } else {
            // Show enable button
            document.getElementById('notif-btn').style.display = 'inline-block';
          }
        }

        function enableNotifications() {
          var btn = document.getElementById('notif-btn');
          btn.textContent = 'Requesting...';
          btn.disabled = true;

          Notification.requestPermission().then(function(permission) {
            if (permission === 'granted') {
              btn.style.display = 'none';
              registerServiceWorker();
              var status = document.getElementById('notif-status');
              status.textContent = 'Notifications active';
              status.className = 'notif-status active';
            } else {
              btn.style.display = 'none';
              var status = document.getElementById('notif-status');
              status.textContent = 'Notifications blocked';
              status.className = 'notif-status blocked';
            }
          });
        }

        function registerServiceWorker() {
          navigator.serviceWorker.register('/sw.js', {scope: '/'}).then(function(registration) {
            return registration.pushManager.getSubscription().then(function(existing) {
              if (existing) {
                sendSubscriptionToServer(existing);
                return;
              }
              // Fetch VAPID key from server
              fetch('/api/dashboard/vapid-key').then(function(r) { return r.json(); }).then(function(data) {
                var vapidKey = urlBase64ToUint8Array(data.vapid_public_key);
                return registration.pushManager.subscribe({
                  userVisibleOnly: true,
                  applicationServerKey: vapidKey
                });
              }).then(function(subscription) {
                if (subscription) sendSubscriptionToServer(subscription);
              }).catch(function(err) {
                console.warn('Push subscription failed:', err);
              });
            });
          }).catch(function(err) {
            console.warn('Service worker registration failed:', err);
          });
        }

        function sendSubscriptionToServer(subscription) {
          fetch('/api/dashboard/push-subscribe', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(subscription.toJSON())
          }).catch(function(err) {
            console.warn('Failed to send subscription to server:', err);
          });
        }

        function urlBase64ToUint8Array(base64String) {
          var padding = '='.repeat((4 - base64String.length % 4) % 4);
          var base64 = (base64String + padding).replace(/\\-/g, '+').replace(/_/g, '/');
          var rawData = atob(base64);
          var outputArray = new Uint8Array(rawData.length);
          for (var i = 0; i < rawData.length; ++i) {
            outputArray[i] = rawData.charCodeAt(i);
          }
          return outputArray;
        }

        initNotifications();

        // Update relative times every 30 seconds
        setInterval(function() {
          if (dashState) {
            // Re-render agent "last seen" and recent task "completed at" times
            renderAgentTable(dashState.agents || []);
            doRenderRecent();
            renderDeadLetter(dashState.dead_letter_tasks || []);
            renderDetsHealth(dashState.dets_health || null);
            // Update uptime
            if (dashState.uptime_ms) {
              dashState.uptime_ms += 30000;
              document.getElementById('hm-uptime').textContent = formatUptime(dashState.uptime_ms);
            }
          }
        }, 30000);
      </script>
    </body>
    </html>
    """
  end
end
