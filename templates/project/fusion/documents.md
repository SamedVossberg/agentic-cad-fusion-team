# Fusion documents

## Location
| Item | Value |
|---|---|
| Hub | `<hub name>` (id `<hub id>`) |
| Project | `<project name>` (id `<project id>`) |
| MAIN folder | `<folder>` — `<folder urn>` |
| WIP folder | `<project> / WIP` — `<folder urn>` |
| Archive folder | `<project> / WIP / _archive` — `<folder urn>` |

## MCP endpoints
| Server | Endpoint | Used by |
|---|---|---|
| `fusion-cloud` (project `.mcp.json`) | Fusion Compute MCP, `https://developer.api.autodesk.com/da/v3/mcp/fusion` | the agent team (role files allow only `mcp__fusion-cloud__*`) |
| desktop Fusion MCP (optional, user scope, other name) | local Fusion app | the user's own work; never used by the team |

The user may keep working in desktop Fusion at any time. Saving a new MAIN version outside a [MERGE] task is allowed
(CLAUDE.md standing default) but tell the lead: the snapshot goes stale and open tickets' base versions move. The rebase
dry-run catches it. Never save MAIN while a ticket is MERGING.

## MAIN documents (the joint version)
| Doc key | Document name | Lineage URN | Notes |
|---|---|---|---|
| `<key>` | `<document name>` | `<lineage urn>` | MAIN. Written only by [MERGE] tasks. |

`<Doc>` in the naming rules = the MAIN document name above.

## Naming rules (CLAUDE.md "Branch / merge model")
| Copy | Name | Folder |
|---|---|---|
| Submission round N | `<Doc>__T###_r<N>` | WIP |
| Scratch (never submitted) | `<Doc>__T###_scratch` | WIP |
| Rebase dry-run | `<Doc>__T###_rebase` | WIP |
| Reviewer reproducibility check | `<Doc>__T###_r<N>_verify` | WIP |

Version descriptions always start with `[T### r<N>][<name>]`, `[MERGE T###]` or `[ROLLBACK T###]`.

## Retention policy
- Never delete anything from the hub.
- After a ticket is MERGED, move all its WIP copies to `WIP/_archive` (move only). See `fusion/capabilities.md` S10.

## Other documents in the project (reference only — never modified by the team)
<earlier variants, purchased-part models, reference designs>

## MAIN version history (updated by [MERGE] tasks)
| Version | Description | Ticket | Date |
|---|---|---|---|
