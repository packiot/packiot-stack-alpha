# W3 Intake Checklist — copy per migration run

> Run this the day PowerBI/Azure access lands. Inputs are **user-provided**.
> Companion to `../w3-powerbi-migration-readiness.md` §2.

Run date: __________  Operator: __________

## A. Report inventory (cross-check two sources)
- [ ] From code: distinct `{dataset, reportId}` pairs front4 embeds (route params + back4
      access logs `path:/getEmbedToken body:{reportId...}`).
- [ ] From PowerBI: all reports in workspace `635f5c34-4183-4211-831b-241fbf1ec3dc` (+ any others).
- [ ] Reconcile (drop dead reports; flag broken embeds).
- [ ] Rank by usage.

## B. Inventory table (fill)
| Rank | reportId | dataset id | workspace | .pbix path (private!) | data source (host/db or `report_*`) | import/DirectQuery | refresh cadence | owner (biz/tech) | key measures | test tenant+window |
|------|----------|-----------|-----------|-----------------------|--------------------------------------|--------------------|-----------------|------------------|--------------|--------------------|
|  |  |  |  |  |  |  |  |  |  |  |

## C. Azure / service principal
- [ ] Workspace id(s) + name(s): __________
- [ ] SP `clientId`: __________  `tenantId`: __________
- [ ] SP client secret **rotated + moved to Secrets Manager** (currently hardcoded in back4 `PowerBIController/index.js`): [ ]
- [ ] SP has workspace admin (needed for `.pbix` export + dataset metadata): [ ]
- [ ] PowerBI dataset **RLS roles** documented (these encode per-tenant isolation → reproduce in Metabase): __________

## D. Sign-off inputs
- [ ] Owner named per report.
- [ ] Owner-trusted key measures captured per report.
- [ ] Two test windows per report (owner window + one independent).

## Gates before any rebuild
- [ ] W2 Metabase instance exists + connected to a Postgres read-replica.
- [ ] back4 dual verifier (§5) shipped so PowerBI survives the Cognito flip.
- [ ] Toolchain installed (`pbi-tools`, DAX Studio, Tabular Editor, or the ZIP+REST fallback).
