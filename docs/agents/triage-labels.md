# Triage labels

| Role | Label |
| --- | --- |
| Needs evaluation | needs-triage |
| Needs information | needs-info |
| Ready for independent implementation | ready-for-agent |
| Ready for human-assisted work | ready-for-human |
| Will not implement | wontfix |

Use mvp for the initial release scope, type:afk and type:hitl for execution type, and blocked for an issue with unresolved dependencies. P0 is an integration feasibility gate; P1 is MVP delivery. A blocked issue has no ready label. Before starting it, confirm dependencies are closed and their results support its scope, then replace blocked with the appropriate ready label.

## Labels for contributors

| Label | Meaning |
| --- | --- |
| good first issue | Small, well-scoped work suited to a first contribution. |
| help wanted | The maintainer would welcome an outside contribution. |
| bug | Something isn't working as agreed in [product.md](../product.md). |
| enhancement | A new feature or a change to agreed behavior; it needs agreement before code. |

The older planning labels explain past issues: `mvp` marks work that was required for the initial macOS MVP, `P0` marks an integration feasibility gate (a question that had to be answered before building on that integration), and `P1` marks MVP feature delivery.
