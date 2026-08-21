# VerseGuard worktree server

A local Herdr 0.8 plugin for one workflow. Herdr's native **New worktree** action remains unchanged. `worktree.created` is the primary hook and `workspace.created` is a one-time compatibility fallback for alternate creation paths. It deliberately does **not** subscribe to `workspace.focused`, so ordinary workspace navigation never runs setup or shows plugin notifications. Dotted and underscore event payload names are accepted.

Every hook acts only on an explicitly linked worktree whose primary checkout is `/home/compean/development/VerseGuard`. It creates the Expo tab in that worktree's own workspace, not a shared `servers` space. Duplicate detection looks for a pane already running `npx expo start --clear --port 8082`; the coding pane at the same checkout is ignored. Repeated creation events exit quietly. Only a worktree without that Expo tab proceeds to `npm ci`, background (`--no-focus`) tab creation with a branch/worktree label, and:

```sh
npx expo start --clear --port 8082
```

The Expo command is sent to the new tab's shell, so the event hook exits while Expo continues in that tab. Real failures are written to the plugin log/stderr and shown as Herdr notifications; duplicate events are logged without a toast.

## Manual retry

Right-click the selected linked VerseGuard worktree workspace and choose **VerseGuard: retry worktree server**. The same project filter, `npm ci`, duplicate check, and no-focus behavior apply. A primary checkout or non-VerseGuard workspace is ignored.

## Test

Tests replace both Herdr and npm with temporary fakes; they do not touch the live Herdr session:

```sh
python3 -m unittest discover -s herdr/plugins/verseguard-worktree-server/tests -v
```

## Link / unlink

From this repository:

```sh
herdr plugin link "$PWD/herdr/plugins/verseguard-worktree-server" --enabled
herdr plugin unlink verseguard-worktree-server
```

Relink after changing the manifest. Source/script edits are immediately visible through the local link.

## Fixed-port caveat

Port **8082** is intentional for v1. Duplicate prevention is per checkout, not per port: starting more than one distinct VerseGuard worktree can still cause an Expo port conflict, which remains visible in that worktree's server tab.