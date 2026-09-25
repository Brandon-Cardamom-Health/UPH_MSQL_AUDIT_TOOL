# SQL Server Auditor — Care Insights Monitoring (SOW A-5.0)

Native SQL Server Audit-based framework to monitor Care Insights' shared
service account querying Epic Clarity. Built as reviewable scripts, not
requiring elevated/sysadmin access — fits the "Cardamom provides scripts,
Jesse's team reviews and executes" working model.

## Why SQL Server Audit (vs. Extended Events / triggers / custom logging)

- Native object-level `SELECT` auditing tied directly to schema.table +
  principal — no need to parse query text to figure out what was touched.
- Setup requires `ALTER ANY SERVER AUDIT` / `ALTER ANY DATABASE AUDIT`,
  not sysadmin.
- Output (`.sqlaudit` files) is a standard, well-understood format with
  a built-in reader (`sys.fn_get_audit_file`) — no custom capture agent.

## Run order

1. `audit/01_create_server_audit.sql` — server audit + file target (disabled)
2. `audit/02_create_database_audit_specification.sql` — empty audit spec (disabled)
3. `config/approved_tables.sql` — loads approved table list, **prints**
   (doesn't auto-run) the batched `ALTER ... ADD` statements to attach
   each table. Review printed output, then execute.
4. Enable both objects deliberately:
   ```sql
   ALTER DATABASE AUDIT SPECIFICATION [DBAuditSpec_CareInsights_SelectActivity] WITH (STATE = ON);
   ALTER SERVER AUDIT [Audit_CareInsights_ClarityAccess] WITH (STATE = ON);
   ```
5. `logging/03_create_log_table_and_loader.sql` — log table + loader proc,
   schedule `dbo.usp_LoadAuditLog` via SQL Agent (suggest every 15-30 min).
6. `logging/04_retention_purge.sql` — retention purge proc, defaults to
   `@DryRun = 1`. Schedule daily once retention days are confirmed.
7. `logging/05_alerting.sql` — guardrail evaluation + `sp_send_dbmail` alert
   proc, defaults to `@DryRun = 1`. Schedule after the loader in the same
   job cadence once rules/recipients are confirmed (see below).

## Service account permissions (per UPH's Technical Specifications doc)

UPH scoped the following for the audit tooling's service account — `CONTROL
SERVER` was explicitly struck from the list, consistent with the no-elevated-
access approach these scripts assume:

- `ALTER SERVER AUDIT`, `ALTER SERVER AUDIT SPECIFICATION`, `ALTER DATABASE AUDIT SPECIFICATION`
- `VIEW SERVER STATE`, `VIEW SERVER PERFORMANCE STATE`, `VIEW DATABASE STATE`, `VIEW ANY DEFINITION`
- `db_datareader`
- msdb access: `SQLAgentReaderRole`, `SQLAgentOperatorRole`
- `EXECUTE` on `sp_send_dbmail`

**Database Mail (SMTP/profile) is configured once by UPH's own DBA using
their own credentials** — not part of these scripts. `05_alerting.sql` only
calls `sp_send_dbmail` against an existing profile name you'll need to
confirm with Jesse's team.

## Before this touches TST (let alone prd-copy/production)

- [ ] Confirm real database name (placeholder: `Clarity`)
- [ ] Confirm Care Insights service account login name (placeholder: `svc_careinsights_clarity`)
- [ ] Confirm audit file path / disk with UPH DBA team (placeholder: `D:\SQLAudit\CareInsights\`)
- [x] Replace placeholder rows in `dbo.AuditConfig_ApprovedTables` with the real
      table list — **done**: 1,020 tables loaded from
      `EvidenceCare_Hospital_Queryset_Unique_Tables.xlsx`, assumed `dbo` schema
      (flag to Jesse if any table actually lives elsewhere)
- [ ] Confirm exact retention value within the 30–60 day SOW range (currently defaults to 45)
- [ ] Decide who owns raw `.sqlaudit` file-level cleanup (see note in `04_*.sql`) — flagged as
      a manual/OS-level task for UPH's team rather than automated in T-SQL
- [ ] Confirm Database Mail profile name with UPH DBA (their one-time setup)
- [ ] Answer remaining discovery questions before enabling alerting for real: alert
      criteria/thresholds, recipient list, extract strategy (incremental vs. full),
      resource governor presence, downtime hours, target environment (Tst/Dev) details

## Not yet built

- Guardrail rule for query/result-set volume — needs the loader (`03_*.sql`)
  extended to capture row counts from `fn_get_audit_file`, plus a confirmed
  threshold. Stubbed out in `05_alerting.sql` with a TODO.
- DMV-based real-time monitoring layer (`sys.dm_exec_*`, Query Store views) —
  UPH's tech spec lists these as needed access; not yet clear whether this
  supplements or is an alternative signal to the Audit-file-based approach
  in `03_*.sql`. Worth clarifying with Jesse's team before building against it.
