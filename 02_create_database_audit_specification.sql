/*
====================================================================
 02_create_database_audit_specification.sql

 Purpose : Scopes the server audit (01_*.sql) down to exactly what
           SOW A-5.0 calls for: SELECT activity by the Care Insights
           shared service account, against the approved table set,
           in the Clarity database.

 Scope   : Care Insights vendor monitoring (SOW A-5.0)
           In scope    -> table/query-level SELECT auditing
           Out of scope-> column/row-level auditing, per-user
                           attribution (shared account, so N/A),
                           any table not in the approved list

 Permissions required to run this script:
   ALTER ANY DATABASE AUDIT  (in the Clarity database)

 Before running:
   1. Confirm @ServiceAccountLogin with UPH DBA team (Ryan/Wade) —
      must match the actual SQL login used by the Care Insights
      connector, not a display name.
   2. Populate config/approved_tables.sql with the real ~1,000-1,100
      table list once confirmed by Analytics Engineering / IT
      Security / Internal Audit (guardrail definition deliverable).
      This script reads that list to build the FOR clause.
   3. This targets SELECT only. If guardrail sessions surface a need
      to watch for INSERT/UPDATE/DELETE (shouldn't happen against a
      read-only extract account, but worth confirming), extend the
      audit_action_id list below.
====================================================================
*/

/*
====================================================================
 02_create_database_audit_specification.sql

 Purpose : Scopes the server audit (01_*.sql) down to exactly what
           SOW A-5.0 calls for: SELECT activity by the Care Insights
           shared service account, against the approved table set,
           in the Clarity database.

 Scope   : Care Insights vendor monitoring (SOW A-5.0)
           In scope    -> table/query-level SELECT auditing
           Out of scope-> column/row-level auditing, per-user
                           attribution (shared account, so N/A),
                           any table not in the approved list

 Permissions required to run this script:
   ALTER ANY DATABASE AUDIT  (in the Clarity database)

 TESTING MODE: set @UseCurrentLoginForTesting = 1 below to audit
 activity by whoever is currently connected (you) instead of the real
 Care Insights service account — useful for validating the mechanics
 work in TST before the real login name is confirmed. Set back to 0
 (and fill in the real login) before this goes anywhere near
 prd-copy/production — auditing your own login isn't the deliverable.

 Before running for real (not just testing):
   1. Confirm @ServiceAccountLogin with UPH DBA team (Ryan/Wade) —
      must match the actual SQL login used by the Care Insights
      connector, not a display name.
   2. Confirm the database name below (currently a placeholder).
   3. This targets SELECT only. If guardrail sessions surface a need
      to watch for INSERT/UPDATE/DELETE (shouldn't happen against a
      read-only extract account, but worth confirming), extend the
      audit_action_id list below.
====================================================================
*/

USE Clarity;  -- TODO: confirm actual TST database name (SELECT name FROM sys.databases WHERE name LIKE '%Clarity%')
GO

DECLARE @UseCurrentLoginForTesting BIT = 1;  -- TODO: set to 0 once real service account is confirmed
DECLARE @ServiceAccountLogin SYSNAME = N'svc_careinsights_clarity';  -- real login, once confirmed

IF @UseCurrentLoginForTesting = 1
BEGIN
    SET @ServiceAccountLogin = SUSER_SNAME();  -- whoever is running this script
    PRINT 'TEST MODE: auditing current login (' + @ServiceAccountLogin + '), not the real Care Insights service account.';
END

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @ServiceAccountLogin)
BEGIN
    RAISERROR('Login %s not found. Confirm the login name before proceeding.', 16, 1, @ServiceAccountLogin);
    RETURN;
END

IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'DBAuditSpec_CareInsights_SelectActivity')
BEGIN
    PRINT 'Database audit specification already exists — skipping create.';
END
ELSE
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [DBAuditSpec_CareInsights_SelectActivity]
    FOR SERVER AUDIT [Audit_CareInsights_ClarityAccess]
    WITH (STATE = OFF);  -- left OFF until table-level actions are attached (see config/approved_tables.sql)

    PRINT 'Created database audit specification. Table-level audit actions are added by';
    PRINT 'config/approved_tables.sql — run that script next.';
END
GO