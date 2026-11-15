#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const { execSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const MANIFEST_PATH = path.join(REPO_ROOT, 'manifest.json');

const PRIMARY_INDEX_URL = 'https://lazer.naominet.dev/plugin/plugins.json';
const BACKUP_INDEX_URL = 'https://raw.githubusercontent.com/chuxuehaocai/lazer-web/main/public/plugin/plugins.json';

function fetchUrl(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return fetchUrl(res.headers.location).then(resolve).catch(reject);
      }
      if (res.statusCode !== 200) {
        return reject(new Error(`Failed to fetch ${url}: HTTP ${res.statusCode}`));
      }
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
}

async function fetchPluginIndex() {
  try {
    const buf = await fetchUrl(PRIMARY_INDEX_URL);
    return JSON.parse(buf.toString('utf8'));
  } catch (err) {
    console.warn(`Primary index failed (${err.message}), trying backup source...`);
    const buf = await fetchUrl(BACKUP_INDEX_URL);
    return JSON.parse(buf.toString('utf8'));
  }
}

function setGithubOutput(key, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    fs.appendFileSync(outputFile, `${key}=${value}\n`, 'utf8');
  }
  console.log(`[Action Output] ${key}=${value}`);
}

async function main() {
  console.log('=== Checking for Upstream NetEase Plugin Updates ===');

  if (!fs.existsSync(MANIFEST_PATH)) {
    throw new Error(`manifest.json not found at ${MANIFEST_PATH}`);
  }

  const currentManifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  const currentVersion = currentManifest.version || '0.0.0';
  console.log(`Current local version: ${currentVersion}`);

  const index = await fetchPluginIndex();
  const plugins = index.plugins || index;
  const netease = plugins.find(p => p.id === 'lazer.netease');

  if (!netease) {
    throw new Error('lazer.netease not found in upstream plugins.json');
  }

  const upstreamVersion = netease.version;
  const downloadUrl = netease.download;
  const expectedSha256 = netease.sha256;

  console.log(`Upstream version: ${upstreamVersion}`);
  console.log(`Download URL: ${downloadUrl}`);

  setGithubOutput('current_version', currentVersion);
  setGithubOutput('upstream_version', upstreamVersion);

  if (currentVersion === upstreamVersion) {
    console.log(`✓ Up to date! Local version (${currentVersion}) matches upstream version (${upstreamVersion}).`);
    setGithubOutput('has_update', 'false');
    return;
  }

  console.log(`🚀 New version available: ${currentVersion} -> ${upstreamVersion}`);
  setGithubOutput('has_update', 'true');
  setGithubOutput('download_url', downloadUrl);
  setGithubOutput('sha256', expectedSha256);

  // If running in sync mode (default when updates exist)
  console.log(`Downloading ${downloadUrl}...`);
  const zipBuf = await fetchUrl(downloadUrl);

  if (expectedSha256) {
    const actualSha256 = crypto.createHash('sha256').update(zipBuf).digest('hex');
    if (actualSha256.toLowerCase() !== expectedSha256.toLowerCase()) {
      throw new Error(`SHA256 mismatch! Expected ${expectedSha256}, got ${actualSha256}`);
    }
    console.log(`✓ SHA256 verified: ${actualSha256}`);
  }

  // Create isolated temp directory
  const tempExtractDir = path.join(REPO_ROOT, '.tmp_upstream_extract');
  if (fs.existsSync(tempExtractDir)) {
    fs.rmSync(tempExtractDir, { recursive: true, force: true });
  }
  fs.mkdirSync(tempExtractDir, { recursive: true });

  const tempZipPath = path.join(tempExtractDir, 'upstream.zip');
  fs.writeFileSync(tempZipPath, zipBuf);

  console.log('Unpacking upstream zip...');
  execSync(`tar -xf "${tempZipPath}" -C "${tempExtractDir}"`, { stdio: 'inherit' });
  fs.rmSync(tempZipPath);

  // Protected paths that MUST NEVER be overwritten or deleted
  const PROTECTED_ENTRIES = new Set([
    '.git',
    '.github',
    'scripts',
    '.gitignore',
    'LICENSE'
  ]);

  console.log('Synchronizing plugin files to repository root...');
  const extractedEntries = fs.readdirSync(tempExtractDir);

  for (const entry of extractedEntries) {
    if (PROTECTED_ENTRIES.has(entry)) {
      console.log(`[PROTECTED] Skipping entry ${entry}`);
      continue;
    }

    const srcPath = path.join(tempExtractDir, entry);
    const destPath = path.join(REPO_ROOT, entry);

    // If entry is README.md, preserve our custom header and merge
    if (entry === 'README.md' && fs.existsSync(destPath)) {
      console.log('Updating upstream section in README.md while preserving disclaimer and scripts guide...');
      const upstreamReadme = fs.readFileSync(srcPath, 'utf8');
      const currentReadme = fs.readFileSync(destPath, 'utf8');
      // If our current readme has header, keep the header
      const headerMarker = '<!-- UPSTREAM_README_START -->';
      if (currentReadme.includes(headerMarker)) {
        const header = currentReadme.split(headerMarker)[0];
        fs.writeFileSync(destPath, `${header}${headerMarker}\n\n${upstreamReadme}`, 'utf8');
      } else {
        fs.writeFileSync(destPath, upstreamReadme, 'utf8');
      }
      continue;
    }

    if (fs.existsSync(destPath)) {
      fs.rmSync(destPath, { recursive: true, force: true });
    }
    fs.cpSync(srcPath, destPath, { recursive: true });
    console.log(`Updated: ${entry}`);
  }

  // Clean up temp extract directory
  fs.rmSync(tempExtractDir, { recursive: true, force: true });
  console.log('✓ Successfully synchronized upstream files.');
}

main().catch(err => {
  console.error('Fatal error during upstream sync:', err);
  process.exit(1);
});
