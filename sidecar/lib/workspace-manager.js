'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { log } = require('./log');

/**
 * Manages per-repo workspace directories for multi-repo task execution.
 * Each unique repo URL gets its own cloned workspace under the base directory.
 */
class WorkspaceManager {
  /**
   * @param {string} baseDir - Root directory for all workspaces (e.g. ~/.agentcom/<agent>/workspaces/)
   */
  constructor(baseDir) {
    this.baseDir = baseDir;
    fs.mkdirSync(baseDir, { recursive: true });
    log('info', 'workspace_manager_init', { base_dir: baseDir }, 'sidecar/workspace-manager');
  }

  /**
   * Ensure a workspace exists for the given repo URL.
   * Clones on first use, fetches + resets on subsequent use.
   *
   * @param {string} repoUrl - Git repository URL (HTTPS or SSH)
   * @returns {string} Absolute path to the workspace directory
   */
  ensureWorkspace(repoUrl) {
    const slug = this._urlToSlug(repoUrl);
    const wsDir = path.join(this.baseDir, slug);
    const gitDir = path.join(wsDir, '.git');

    if (fs.existsSync(gitDir)) {
      // Workspace exists -- update via fetch + reset
      try {
        execSync('git fetch origin && git reset --hard origin/main', {
          cwd: wsDir,
          encoding: 'utf-8',
          timeout: 120000,
          windowsHide: true,
          shell: true
        });
        log('info', 'workspace_updated', { repo: repoUrl, workspace: wsDir }, 'sidecar/workspace-manager');
      } catch (err) {
        // Log warning but continue with stale workspace (don't fail the task)
        log('warning', 'workspace_update_failed', {
          repo: repoUrl,
          workspace: wsDir,
          error: err.message
        }, 'sidecar/workspace-manager');
      }
    } else {
      // New workspace -- clone the repo
      log('info', 'workspace_cloning', { repo: repoUrl, workspace: wsDir }, 'sidecar/workspace-manager');
      fs.mkdirSync(wsDir, { recursive: true });
      execSync(`git clone "${repoUrl}" "${wsDir}"`, {
        encoding: 'utf-8',
        timeout: 300000,
        windowsHide: true,
        shell: true
      });
      log('info', 'workspace_cloned', { repo: repoUrl, workspace: wsDir }, 'sidecar/workspace-manager');
    }

    return path.resolve(wsDir);
  }

  /**
   * Convert a repo URL to a filesystem-safe slug.
   *
   * @param {string} url - Repository URL
   * @returns {string} Filesystem-safe slug
   * @private
   */
  _urlToSlug(url) {
    return url
      .replace(/^https?:\/\//, '')     // Strip https?:// protocol prefix
      .replace(/^git@[^:]+:/, '')      // Strip git@host: SSH prefix
      .replace(/\.git$/, '')           // Strip .git suffix
      .replace(/\//g, '-')            // Replace / with -
      .replace(/[^a-zA-Z0-9._-]/g, '-'); // Replace non-alphanumeric (except ., -, and _) with -
  }
}

module.exports = { WorkspaceManager };
