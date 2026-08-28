---
title: "feat: Install and configure Box CLI for file management"
type: feat
status: completed
date: 2026-03-18
---

# feat: Install and configure Box CLI for file management

Install the [Box CLI](https://github.com/box/boxcli) to read, manage, and automate files on Box from the terminal.

## Critical Discovery: JWT Not Viable

The app "itsmyapp" was created as Server Authentication (JWT), but the Box account is **Personal/Free** (Enterprise ID "0"). JWT authentication requires:

- A Box Business/Enterprise plan
- Admin Console access for app authorization
- A valid Enterprise ID

**Resolution:** Use **OAuth 2.0 authentication** instead. Two options:

1. **`box login -d`** (default Box CLI app) — zero setup, limited scopes, works immediately
2. **Create a new OAuth 2.0 app** in the Developer Console — full scopes, requires creating a new app with "User Authentication (OAuth 2.0)" type

The existing JWT app ("itsmyapp") cannot be converted to OAuth 2.0 — a new app must be created if custom scopes are needed.

## Acceptance Criteria

- [x] Box CLI installed and `box --version` succeeds
- [x] OAuth 2.0 authentication configured and working
- [x] Can list root folder contents: `box folders:items 0`
- [x] Can download a file: `box files:download FILE_ID`
- [x] Can upload a file: `box files:upload PATH --parent-id FOLDER_ID`
- [x] Can search: `box search QUERY`
- [x] Credentials stored securely in macOS Keychain

## MVP

### Step 1: Install Box CLI

Attempt npm install on Node.js 25.8.1. Box CLI officially supports Node 18-22 and depends on `keytar` (deprecated native module). If installation or runtime fails, fall back to the macOS `.pkg` installer.

```bash
# Primary: npm install
npm install --global @box/cli
box --version

# Fallback if npm fails: download .pkg from GitHub releases
# https://github.com/box/boxcli/releases
# The .pkg bundles its own Node.js runtime
```

### Step 2: Authenticate with OAuth 2.0

**Option A: Quick start with default Box CLI app (recommended to start)**

```bash
box login -d
# Opens browser for Box authorization
# Creates "oauth" environment, set as default
# Limited scopes but sufficient for file operations
```

**Option B: Custom OAuth 2.0 app (full control)**

1. Go to [Box Developer Console](https://cloud.app.box.com/developers/console)
2. Create New App > Custom App > User Authentication (OAuth 2.0)
3. Set redirect URI to `http://localhost:3000/callback`
4. Enable scopes: Read/Write all files and folders
5. Note the Client ID and Client Secret

```bash
box login --platform-app --name myboxapp
# Enter Client ID and Client Secret when prompted
# Opens browser for authorization
```

### Step 3: Verify Authentication

```bash
box users:get --json
# Should return your user info (name, login, space_used, etc.)
```

### Step 4: Test File Operations

```bash
# Browse files
box folders:items 0                          # List root folder
box folders:items FOLDER_ID --json           # List specific folder as JSON

# Download
box files:download FILE_ID --destination ./  # Download a file

# Upload
box files:upload ./local-file.txt --parent-id 0  # Upload to root

# Search
box search "quarterly report" --type file    # Search for files
box search "*.pdf" --file-extensions pdf     # Search by extension

# Folder management
box folders:create 0 "New Folder"            # Create folder in root
```

### Step 5: Verify Bulk/Automation Support

```bash
# JSON output for scripting
box folders:items 0 --json | jaq '.[] | .name'

# Bulk operations via CSV (example)
box files:upload --bulk-file-path upload-list.csv
```

## Risks and Fallbacks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| npm install fails on Node 25 (keytar native module) | High | Use macOS `.pkg` installer from GitHub releases |
| Default Box CLI app scopes too limited | Medium | Create custom OAuth 2.0 app (Option B) |
| OAuth token expires (60-day refresh token) | Low | Run `box login -d --reauthorize` to re-auth |

## Sources

- [Box CLI GitHub](https://github.com/box/boxcli)
- [Box CLI Releases](https://github.com/box/boxcli/releases)
- [Box CLI Login Docs](https://github.com/box/boxcli/blob/main/docs/login.md)
- [Box CLI Files Docs](https://github.com/box/boxcli/blob/main/docs/files.md)
- [Box CLI Folders Docs](https://github.com/box/boxcli/blob/main/docs/folders.md)
- [Box CLI Search Docs](https://github.com/box/boxcli/blob/main/docs/search.md)
- Node.js v18-22 required (current system: v25.8.1, may need fallback)
