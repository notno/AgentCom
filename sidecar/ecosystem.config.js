// PM2 ecosystem configuration for AgentCom sidecar
// Usage: pm2 start ecosystem.config.js
// Docs: https://pm2.io/docs/runtime/reference/ecosystem-file/
//
// SETUP:
// 1. Copy config.json.example to config.json and fill in your agent details
// 2. Install pm2 globally: npm install -g pm2
// 3. Install log rotation: pm2 install pm2-logrotate
// 4. Configure log rotation: pm2 set pm2-logrotate:max_size 10M && pm2 set pm2-logrotate:retain 30
// 5. Start sidecar: pm2 start ecosystem.config.js
// 6. Save process list: pm2 save
// 7. Set up startup script: pm2 startup (Linux) or use pm2-installer (Windows)
//
// Windows-specific:
// - Clone https://github.com/jessety/pm2-installer
// - Run `npm run setup` from elevated terminal
// - Then pm2 will run as a Windows service
//
// Verify: pm2 status (should show agentcom-sidecar as online)
// Logs: pm2 logs agentcom-sidecar
// Restart: pm2 restart agentcom-sidecar (triggers auto-update via wrapper script)

module.exports = {
  apps: [{
    name: 'agentcom-sidecar',
    // Use platform-appropriate wrapper script for auto-update
    script: process.platform === 'win32' ? 'start.bat' : 'start.sh',
    cwd: __dirname,
    interpreter: process.platform === 'win32' ? 'cmd' : '/bin/bash',
    interpreter_args: process.platform === 'win32' ? '/c' : '',

    // Auto-restart on crash (SIDE-05)
    autorestart: true,
    max_restarts: 50,       // Max restarts within restart_delay window
    min_uptime: 5000,       // Must run 5s to be considered "started"
    restart_delay: 2000,    // Wait 2s between restarts

    // Memory limit (sidecar should be very lightweight)
    max_memory_restart: '200M',

    // Logging
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file: 'logs/sidecar-error.log',
    out_file: 'logs/sidecar-out.log',
    merge_logs: true,

    // Environment
    env: {
      NODE_ENV: 'production',
      PM2_PROCESS_NAME: 'agentcom-sidecar'
    }
  }]
};
