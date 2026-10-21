# ProjectTools (`pm`)

A PowerShell 7 module for managing a folder of git projects. It clones GitHub repos, sets up new local projects, commits, pushes and backs each one up with restic (to OneDrive via rclone), and restores from those backups.

## Install

In PowerShell 7 (`pwsh`):

```powershell
irm https://raw.githubusercontent.com/keenedge/ProjectTools/main/Install.ps1 | iex
```

This installs to your user module folder and adds `Import-Module ProjectTools -DisableNameChecking` to your profile. Rerun it to update. See [docs/pm.md](docs/pm.md#installation) to install from another branch.

To use it you need `git`, `restic` and `gh` (authenticated, for `pm clone`), plus `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE` set in the environment.

## Common commands

Run these from the folder that holds your projects, or pass `-Root <path>`.

```powershell
pm clone                     # pick a GitHub repo from a list, clone it, set up backup
pm clone flario              # clone a repo by name
pm clone homelab -Folder _homelab  # clone into a custom folder (remembered in ~\.config\pm\config.json)
pm init my-tool              # new local project (git init + backup config)
pm save -Message "fix stuff" # commit, push, restic backup of the current project
pm save --all -NoPush        # commit + back up every project, no push
pm init --all                # set up every folder not yet configured
pm restore                   # pick a project from restic snapshot tags and restore it
pm restore holdclick -DryRun # preview restoring the latest holdclick snapshot
```

## Files

| File | Purpose |
|------|---------|
| `ProjectTools.psm1` | The module (`Manage-Project`, alias `pm`). |
| `ProjectTools.psd1` | Module manifest. |
| `Install.ps1` | Installer used by the one-liner above. |
| `docs/pm.md` | Full reference: concepts, every option, config files, troubleshooting. |

See [docs/pm.md](docs/pm.md) for details.
