# pm — ProjectTools reference

`pm` (alias of `Manage-Project`) manages a folder of project directories. Each project is a git repository with its own restic backup settings. It has four commands:

| Command      | What it does |
|--------------|--------------|
| `pm clone`   | Clone a GitHub repo and set up its backup. |
| `pm init`    | Create a new local project, or adopt an existing folder, and set up its backup. |
| `pm save`    | Commit and push, then back up the working folder with restic. |
| `pm restore` | Restore a project from its restic snapshots. |

`clone`, `init` and `save` also accept `--all`, which runs the command across every project folder under the root.

- [Concepts](#concepts)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Commands](#commands)
- [Files](#files)
- [Troubleshooting](#troubleshooting)

---

## Concepts

**Root.** Every command works in a single root folder. By default that is the current directory; `-Root <path>` overrides it. Projects are the root's direct subfolders.

**A project** is a subfolder of the root that:

- is a git repository (`.git`), and
- has a `.backup.json` file. `pm` only treats folders with this file as set-up projects.

**Backup config.** `pm clone` and `pm init` write `.backup.json` with two values:

```json
{
  "repository": "rclone:restic:backups/restic",
  "tag": "my-project"
}
```

- `repository` is copied from `$env:RESTIC_REPOSITORY` at setup time. After that, `pm save` uses the value in this file, not the environment variable.
- `tag` is the folder or repo name. restic tags every snapshot with it, so each project's snapshots can be told apart inside one shared repository.

`.backup.json` is added to the repo's `.git/info/exclude`. That keeps it out of git without touching the committed `.gitignore`.

**Include/exclude files.** Setup also creates a `.restic/` folder in the project:

- `.restic/include.restic.txt` starts empty. An empty file backs up the whole project. Add paths (relative to the project) to back up only those.
- `.restic/exclude.restic.txt` starts with `.restic` and `.git`. Patterns use restic's `--exclude-file` syntax.

In both files, blank lines and lines starting with `#` are ignored. Existing files are never overwritten. Unlike `.backup.json`, the `.restic/` folder is **not** git-excluded, so `pm save` commits it.

**restic repository.** Before `clone` and `init` do anything, `pm` checks that the restic repository opens. If restic reports that the repository does not exist (exit code 10), `pm` runs `restic init` to create it.

## Prerequisites

- PowerShell 7+. The manifest sets `PowerShellVersion = '7.0'`.
- On `PATH`:
  - `git`
  - `restic`, version 0.17 or later for the "repository missing" detection
  - `gh`, authenticated (`gh auth login`). Needed for `pm clone`.
  - `rclone`, configured, when the restic repository is `rclone:...`.

Environment variables:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `RESTIC_REPOSITORY` | `clone`, `init` | Required. Repository written into each new `.backup.json`, e.g. `rclone:restic:backups/restic`. |
| `RESTIC_PASSWORD_FILE` | all | Repository password file. Must exist and be non-empty. |
| `RESTIC_PASSWORD` | all | Alternative to `RESTIC_PASSWORD_FILE`. One of the two must be set. |
| `RESTIC_EXCLUDE_FILE` | `save` | Optional global exclude file, applied to every project in addition to its own `.restic/exclude.restic.txt`. |

## Installation

Run this in `pwsh`. It doesn't need `gh`:

```powershell
irm https://raw.githubusercontent.com/keenedge/ProjectTools/main/Install.ps1 | iex
```

The installer:

1. Downloads `ProjectTools.psm1` and `ProjectTools.psd1` from the given ref.
2. Puts them in `~\Documents\PowerShell\Modules\ProjectTools`. It replaces that folder on every run.
3. Adds `Import-Module ProjectTools -DisableNameChecking` to `$PROFILE.CurrentUserAllHosts`, creating the profile if needed. Any older `Import-Module ProjectTools` line is replaced, not duplicated.
4. Imports the module into the current session.

Run the same one-liner again to update.

To install from another branch, tag or commit, use the scriptblock form so you can pass `-Ref`:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/keenedge/ProjectTools/main/Install.ps1))) -Ref feat/my-branch
```

## Commands

### Syntax

```text
pm clone [<repo>]   [-Root <path>] [-Owner <owner>] [-Folder <folder>] [--all]
pm init  [<name>]   [-Root <path>]                  [--all]
pm save  [<project>] [-Root <path>] [-Message <msg>] [-NoPush] [--all]
pm restore [<project>] [-Root <path>] [-Snapshot <id>] [-Target <path>] [-Force] [-DryRun]
pm forget  [<project>] [-Snapshot <id>] [-Keep <n>] [-Force] [-DryRun] [--prune]
```

- `--all` and `-All` are equivalent. With `--all`, any name you pass is ignored.
- Passing a parameter that doesn't belong to the command is an error. For example, `-Message` with `clone` fails.
- `Get-Help pm` shows the built-in summary.

### pm clone

Clone a GitHub repo into `<root>\<folder>` and set up its backup. The folder is the repo name unless a folder mapping says otherwise (see below).

- **No name:** lists your repos (or `-Owner`'s), newest first.
  - Each line shows public/private, the description, and `*` if the repo is already cloned in the root.
  - Enter a number to pick a repo, or text to filter by `owner/name`. A filter with one match picks it; a filter with several shows a shorter list. Leave it blank to cancel.
- **With a name:** matches `name` or `owner/name` exactly.
- **`--all`:** clones every listed repo into the root, after a y/N confirmation.
- Archived repos are never listed. At most 200 repos are fetched.
- If a repo is already cloned, the clone is skipped. Backup setup still runs if `.backup.json` is missing.
- If the target folder exists, is not a git repo, and is not empty, the command fails.

**Folder names.** `-Folder <folder>` clones into `<root>\<folder>` instead of the repo name. It also saves the choice in `~\.config\pm\config.json`:

```json
{
  "folders": {
    "keenedge/homelab": "_homelab"
  }
}
```

- Mappings are keyed by `owner/repo`, matched in any case.
- Later `pm clone` runs, including `--all`, use the mapped folder automatically. The `*` marker in the pick list also checks it.
- Running `-Folder` again for the same repo replaces its mapping. You can also edit the file by hand. A missing or empty file means no mappings.
- `-Folder` is for one repo, so it can't be combined with `--all`.
- An existing folder is never overwritten. The same skip and fail rules as above apply.
- The restic tag stays the **repo name**, whatever the folder is called, so snapshots stay grouped by repo.

```powershell
pm clone                  # pick from a list
pm clone flario           # by name
pm clone homelab -Folder _homelab   # clone into _homelab and remember it
pm clone someorg/tool -Owner someorg
pm clone --all -Root D:\src
```

### pm init

Create a new project folder, or adopt an existing one.

- Creates `<root>\<name>` if it doesn't exist.
- Runs `git init` if there is no `.git`.
- Writes `.backup.json` and the `.restic/` files. If the folder was already set up, its config is rewritten from the current `RESTIC_REPOSITORY`.
- With no name, asks for one. The name must be a valid folder name.
- `--all` sets up every subfolder of the root that has no `.backup.json`, after a y/N confirmation.

Nothing is pushed anywhere and no GitHub repo is created. Add a remote yourself if you want `pm save` to push.

```powershell
pm init my-tool
pm init --all
```

### pm save

Commit, push, and back up one project, or every project with `--all`.

1. **Find the project.** Uses `<root>\<project>`, or the root itself if no project is given, then walks up to the git top level. So running `pm save` anywhere inside a project works. That folder must have a `.backup.json`. A folder that isn't in a git repo skips steps 2 and 3 and is only backed up.
2. **Commit.** Runs `git add -A` (everything, including untracked files that aren't ignored).
   - If there are changes, it shows them and commits with `-Message`. Without `-Message` it asks; blank means `WIP yyyy-MM-dd HH:mm`.
   - A failed commit is a warning; the backup still runs.
3. **Push.** Pushes unless `-NoPush` is given or the branch has no upstream. A failed push is a warning; the backup still runs.
4. **Back up.** Runs `restic backup --tag <tag>` against the repository in `.backup.json`:
   - It backs up the whole project, or only the paths in `include.restic.txt`.
   - It applies `exclude.restic.txt` if present (otherwise excludes `.git`), plus `RESTIC_EXCLUDE_FILE` if set.
   - Exit code 3 (some files unreadable) is a warning; any other non-zero exit is an error.

With `--all`, every project under the root is saved. Failures are collected and listed at the end instead of stopping the run. A `-Message` given with `--all` is used for every project.

```powershell
pm save                         # current project
pm save -Message "fix stuff"
pm save my-tool -NoPush
pm save --all -NoPush -Root D:\src
```

### pm restore

Restore a project's files from restic.

**Choosing what to restore**

- **No project given:** lists every snapshot tag in `RESTIC_REPOSITORY`, newest first. Each line shows the latest snapshot time, the number of snapshots, and the original folder. Pick it the same way as in `pm clone`: a number, a text filter, or blank to cancel.
- **With a project:** uses the latest snapshot with that tag.
- **`-Snapshot <id>`:** uses that snapshot instead. A short ID prefix is enough. Without a project name, the snapshot's own tag is used.

**Where it restores**

- **Default target:** `<root>\<folder>`.
  - The folder comes from the `config.json` mapping whose repo name matches the tag, e.g. `keenedge/homelab` → `_homelab` for tag `homelab`. Otherwise it's the tag itself.
  - `-Target <path>` overrides it.
- **How:** the snapshot's original folder (e.g. `D:\projects\x`) is restored with `<snapshot>:/D/projects/x`, so files land directly in the target rather than under `D\projects\x\...`.
- **Repository:** if the target already has a `.backup.json`, its `repository` is used; otherwise `RESTIC_REPOSITORY`.

**Clone first.** If the target is missing or empty and a GitHub repo matches the tag (a `config.json` mapping, else your own repo of that name), `pm` clones it before restoring. Each cloned file's time is set to its last commit, so the snapshot only wins where its copy is newer than the committed one.

**Safety**

- Snapshot files replace local files only when the snapshot copy is newer (`--overwrite if-newer`). `-Force` replaces every file that differs.
- Files that aren't in the snapshot are never deleted.
- `-DryRun` shows what would be restored (`restic restore --dry-run -v`) and writes nothing; it also says whether it would clone.

**What you get back**

- `.git` and `.restic` are excluded from backups by default. A cloned project has its git history; otherwise the restored folder has none.
- If `.backup.json` came back, `pm` recreates the default `.restic` files.
- With no matching GitHub repo, to reattach git history, run this in the folder:

  ```powershell
  git init; git remote add origin <url>; git fetch; git reset origin/<branch>
  ```

  `git reset` without `--hard` keeps the restored files.
- For a project backed up with an include list, the snapshot holds several paths, and their common parent folder is restored.

```powershell
pm restore                                 # pick a project from the snapshot tags
pm restore holdclick -DryRun               # preview
pm restore holdclick -Target D:\restore\holdclick
pm restore holdclick -Snapshot b12f6fd9 -Force
```

To browse snapshots directly: `restic snapshots --tag <project>`.

### pm forget

Forget a project's snapshots.

- **No project given:** pick a tag from the same list as `pm restore`.
- **With a project:** forgets every snapshot with that tag, or all but the newest `-Keep <n>`.
- **`-Snapshot <id>`:** forgets just that snapshot. With a project too, the snapshot must carry that tag.
- Lists the snapshots and asks y/N first. `-Force` skips the question; `-DryRun` only lists them.
- Forgetting only drops the snapshot records. `--prune` (or `-Prune`) also deletes the unused data. Otherwise run `restic prune` later.
- If restic reports a lock left by a crashed run, `restic unlock` clears it.

```powershell
pm forget holdclick -Keep 5 -DryRun
pm forget holdclick -Keep 5 --prune
pm forget -Snapshot b12f6fd9
```

## Files

| Path | Created by | In git? | Purpose |
|------|------------|---------|---------|
| `<project>\.backup.json` | clone, init | No (`.git/info/exclude`) | restic repository and tag for this project. |
| `<project>\.restic\include.restic.txt` | clone, init | Yes | Paths to back up. Empty = whole project. |
| `<project>\.restic\exclude.restic.txt` | clone, init | Yes | Exclude patterns. Default `.restic`, `.git`. |
| `~\.config\pm\config.json` | clone `-Folder` | — | Folder mappings: `owner/repo` → folder name. |
| `~\Documents\PowerShell\Modules\ProjectTools\` | Install.ps1 | — | Installed module. |
| `$PROFILE.CurrentUserAllHosts` | Install.ps1 | — | Gets `Import-Module ProjectTools -DisableNameChecking`. |

## Troubleshooting

**`WARNING: ... unapproved verbs ...` when the module loads.** PowerShell doesn't list `Manage` as an approved verb, so it warns about `Manage-Project`. The warning is harmless. The installer's profile line already silences it; if you import the module yourself, use:

```powershell
Import-Module ProjectTools -DisableNameChecking
```

**`Neither RESTIC_PASSWORD nor RESTIC_PASSWORD_FILE is set.` / `Password file not found` / `Password file is empty`.** Set one of the two variables, for example as Windows user environment variables, and open a new shell.

**`RESTIC_REPOSITORY is not set.`** `clone` and `init` need it. `save` uses `.backup.json` instead.

**`Cannot open restic repository ... (exit N)`.** restic failed for a reason other than "repository missing", such as a wrong password, a broken rclone remote, or no network. Run `restic cat config` and `rclone listremotes` to diagnose. On restic older than 0.17 a missing repository also lands here; create it with `restic init`.

**`No .backup.json in <dir>. Run pm init or pm clone first.`** The folder isn't set up. Run `pm init <name>` from its parent, or `pm init` inside an existing repo's parent with the folder name.

**`<dir> exists and is not empty.`** `pm clone` won't clone over a non-git folder. Move it, or adopt it with `pm init <name>`.

**`No upstream branch - skipping push.`** The repo has no tracking branch. Run `git push -u origin <branch>` once.

**`Push failed (try git pull --rebase)`.** The remote has commits you don't have. Pull, then run `pm save` again.

**Changed `RESTIC_REPOSITORY` but backups still go to the old one.** Each project stores its repository in `.backup.json`. Edit that file, or rerun `pm init <name>` to rewrite it.

**Module won't import in Windows PowerShell 5.1.** The module requires PowerShell 7. Run `pwsh`.
