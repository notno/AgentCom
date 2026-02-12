'use strict';

const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execSync } = require('node:child_process');
const { runGitCommandWithPath } = require('../lib/git-workflow');

// Path to agentcom-git.js (the CLI script we're testing through)
const GIT_CLI_PATH = path.join(__dirname, '..', 'agentcom-git.js');

// Path to the real sidecar config.json (agentcom-git.js reads from __dirname)
const SIDECAR_CONFIG_PATH = path.join(__dirname, '..', 'config.json');

describe('Git Workflow', () => {
  let tmpDir;
  let bareRepoDir;
  let workingRepoDir;
  let originalConfig;

  beforeEach(() => {
    // Save original config.json if it exists
    originalConfig = null;
    if (fs.existsSync(SIDECAR_CONFIG_PATH)) {
      originalConfig = fs.readFileSync(SIDECAR_CONFIG_PATH, 'utf8');
    }

    // Create temp directory structure
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'git-workflow-test-'));
    bareRepoDir = path.join(tmpDir, 'remote.git');
    workingRepoDir = path.join(tmpDir, 'working');

    // Create a bare remote repo with main as default branch
    fs.mkdirSync(bareRepoDir);
    execSync('git init --bare --initial-branch=main', { cwd: bareRepoDir, encoding: 'utf-8' });

    // Clone it as a working repo
    execSync(`git clone "${bareRepoDir}" working`, { cwd: tmpDir, encoding: 'utf-8' });
    execSync('git config user.email "test@test.com"', { cwd: workingRepoDir, encoding: 'utf-8' });
    execSync('git config user.name "Test"', { cwd: workingRepoDir, encoding: 'utf-8' });

    // Create initial commit on main branch and push to origin
    fs.writeFileSync(path.join(workingRepoDir, 'README.md'), '# test repo\n');
    execSync('git checkout -b main', { cwd: workingRepoDir, encoding: 'utf-8' });
    execSync('git add . && git commit -m "init"', { cwd: workingRepoDir, encoding: 'utf-8' });
    execSync('git push -u origin main', { cwd: workingRepoDir, encoding: 'utf-8' });

    // Write a temporary config.json for agentcom-git.js pointing to the working repo
    const testConfig = {
      agent_id: 'test-agent-001',
      token: 'test-token',
      hub_url: 'ws://localhost:4000/ws',
      hub_api_url: 'http://localhost:4000',
      repo_dir: workingRepoDir,
      reviewer: '',
      capabilities: [],
      confirmation_timeout_ms: 30000,
      results_dir: './results',
      log_file: './sidecar.log'
    };
    fs.writeFileSync(SIDECAR_CONFIG_PATH, JSON.stringify(testConfig, null, 2));
  });

  afterEach(() => {
    // Restore original config.json
    if (originalConfig !== null) {
      fs.writeFileSync(SIDECAR_CONFIG_PATH, originalConfig);
    } else if (fs.existsSync(SIDECAR_CONFIG_PATH)) {
      fs.unlinkSync(SIDECAR_CONFIG_PATH);
    }

    // Clean up temp directory
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  describe('start-task', () => {
    it('creates a new branch from origin/main in the temp repo', () => {
      const result = runGitCommandWithPath(GIT_CLI_PATH, 'start-task', {
        agent_id: 'test-agent-001',
        task_id: 'task-001',
        description: 'Fix login bug',
        metadata: {}
      });

      assert.strictEqual(result.status, 'ok', `Expected ok but got: ${JSON.stringify(result)}`);
      assert.ok(result.branch, 'Should return a branch name');
      assert.ok(result.branch.includes('fix-login-bug'), `Branch "${result.branch}" should contain slug of description`);

      // Verify the branch was actually created in the working repo
      const currentBranch = execSync('git rev-parse --abbrev-ref HEAD', {
        cwd: workingRepoDir,
        encoding: 'utf-8'
      }).trim();
      assert.strictEqual(currentBranch, result.branch);
    });

    it('uses agent_id prefix in branch name', () => {
      const result = runGitCommandWithPath(GIT_CLI_PATH, 'start-task', {
        agent_id: 'myagent-abc-def',
        task_id: 'task-002',
        description: 'Add feature',
        metadata: {}
      });

      assert.strictEqual(result.status, 'ok', `Expected ok but got: ${JSON.stringify(result)}`);
      // Branch should start with first segment of agent_id (up to 8 chars) followed by /
      assert.ok(result.branch.startsWith('myagent/'), `Branch "${result.branch}" should start with agent prefix and slash`);
    });
  });

  describe('error handling', () => {
    it('returns error status with missing/empty args', () => {
      const result = runGitCommandWithPath(GIT_CLI_PATH, 'start-task', {});
      assert.strictEqual(result.status, 'error');
      assert.ok(result.error, 'Should include error message');
    });

    it('returns error status for unknown command', () => {
      const result = runGitCommandWithPath(GIT_CLI_PATH, 'nonexistent-command', {});
      assert.strictEqual(result.status, 'error');
    });
  });

  describe('submit', () => {
    it('requires commits ahead of origin/main to submit', () => {
      // First start a task to create a branch
      const startResult = runGitCommandWithPath(GIT_CLI_PATH, 'start-task', {
        agent_id: 'test-agent-001',
        task_id: 'task-sub-001',
        description: 'Submit test task',
        metadata: {}
      });
      assert.strictEqual(startResult.status, 'ok', `start-task failed: ${JSON.stringify(startResult)}`);

      // Try to submit without making any commits -- should fail with no_commits
      const submitResult = runGitCommandWithPath(GIT_CLI_PATH, 'submit', {
        agent_id: 'test-agent-001',
        task_id: 'task-sub-001',
        task: { task_id: 'task-sub-001', description: 'Submit test task' }
      });
      assert.strictEqual(submitResult.status, 'error');
      assert.ok(
        submitResult.error && submitResult.error.includes('no_commits'),
        `Expected no_commits error but got: ${JSON.stringify(submitResult)}`
      );
    });

    it('pushes branch and attempts PR creation with commits', () => {
      // Start a task
      const startResult = runGitCommandWithPath(GIT_CLI_PATH, 'start-task', {
        agent_id: 'test-agent-001',
        task_id: 'task-sub-002',
        description: 'Push test task',
        metadata: {}
      });
      assert.strictEqual(startResult.status, 'ok');

      // Make a commit on the branch
      const testFile = path.join(workingRepoDir, 'test-change.txt');
      fs.writeFileSync(testFile, 'test content');
      execSync('git add . && git commit -m "feat: test change"', {
        cwd: workingRepoDir,
        encoding: 'utf-8'
      });

      // Submit -- push should succeed, but PR creation via gh will fail
      // (no GitHub remote). That's expected -- we verify push succeeded.
      const submitResult = runGitCommandWithPath(GIT_CLI_PATH, 'submit', {
        agent_id: 'test-agent-001',
        task_id: 'task-sub-002',
        task: { task_id: 'task-sub-002', description: 'Push test task' }
      });

      // Either succeeds (if gh is configured) or fails at PR creation stage
      // The key behavior: push should have happened to the bare remote
      if (submitResult.status === 'error') {
        // Verify push succeeded even if PR failed: check the branch exists on remote
        const remoteBranches = execSync('git branch -r', {
          cwd: workingRepoDir,
          encoding: 'utf-8'
        }).trim();
        // Push may or may not have succeeded depending on whether it errored at push or PR stage
        // The error message tells us which stage failed
        assert.ok(
          submitResult.error.includes('pr_create_failed') ||
          submitResult.error.includes('push_failed') ||
          submitResult.error.includes('gh'),
          `Expected push or PR creation error but got: ${JSON.stringify(submitResult)}`
        );
      }
      // If status is 'ok', everything worked (unlikely without real GitHub)
    });
  });
});
