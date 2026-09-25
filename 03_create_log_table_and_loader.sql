/*
====================================================================
 03_create_log_table_and_loader.sql

 Purpose : SQL Server Audit writes raw .sqlaudit binary files, which
           aren't directly queryable or easy to retain/report against.
           This creates:
             1. ClarityDataAuditingFramework.AuditLog_CareInsights — a structured table holding
                the fields we actually care about (who, what table,
                when, from where).
             2. ClarityDataAuditingFramework.usp_LoadAuditLog — a proc that reads new audit
                file records via sys.fn_get_audit_file() and loads
                only new rows (idempotent, safe to run repeatedly /
                on a schedule).

 Scope   : Query Log Retention Build deliverable (SOW A-5.0) —
           30-60 day retention window for Care Insights activity.

 Notes:
   - sys.fn_get_audit_file reads directly from the file target path,
     so this proc needs to agree with the @FilePath used in
     01_create_server_audit.sql.
   - event_time from the audit file is UTC; converting to local for
     readability, adjust @@ServerTZ logic if UPH's server isn't on
     Central time.
   - This is intentionally a *read* of the audit files, not a
     replacement for them — the raw .sqlaudit files remain the
     source of truth; this table is a convenience layer for
     reporting/alerting/retention housekeeping.
   - Retention enforcement (deleting rows/files older than 30-60
     days) is a separate, deliberate script — see 04_retention_purge.sql
     — not bundled here, since purge logic should get its own review.
====================================================================
*/

USE ClarityUtil;
GO

IF OBJECT_ID('ClarityDataAuditingFramework.AuditLog_CareInsights', 'U') IS NULL
BEGIN
    CREATE TABLE ClarityDataAuditingFramework.AuditLog_CareInsights
    (
        AuditLogID          BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        EventTimeUTC         DATETIME2(3)   NOT NULL,
        ServerPrincipalName  NVARCHAR(128)  NOT NULL,   -- the service account login
        DatabaseName         NVARCHAR(128)  NULL,
        SchemaName            NVARCHAR(128)  NULL,
        ObjectName            NVARCHAR(128)  NULL,       -- table queried
        Statement             NVARCHAR(MAX)  NULL,        -- captured statement text
        ClientHostName        NVARCHAR(128)  NULL,
        ClientIP              NVARCHAR(48)   NULL,
        ApplicationName       NVARCHAR(128)  NULL,
        SucceededFlag         BIT            NOT NULL,
        AuditFileOffset       VARCHAR(100)   NOT NULL,   -- from audit file, used to dedupe on reload
        LoadedAtUTC           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_AuditLog_CareInsights_Offset
        ON ClarityDataAuditingFramework.AuditLog_CareInsights (AuditFileOffset);

    CREATE INDEX IX_AuditLog_CareInsights_EventTime
        ON ClarityDataAuditingFramework.AuditLog_CareInsights (EventTimeUTC);

    CREATE INDEX IX_AuditLog_CareInsights_Object
        ON ClarityDataAuditingFramework.AuditLog_CareInsights (SchemaName, ObjectName);

    PRINT 'Created ClarityDataAuditingFramework.AuditLog_CareInsights';
END
GO

CREATE OR ALTER PROCEDURE ClarityDataAuditingFramework.usp_LoadAuditLog
    @FilePath NVARCHAR(260) = N'D:\SQLAudit\CareInsights\*.sqlaudit'  -- TODO: match 01_*.sql path
AS
BEGIN
    SET NOCOUNT ON;

    -- AuditFileOffset uniquely identifies a record within the audit
    -- file set (file_name + audit_file_offset), used to avoid
    -- re-inserting rows we've already loaded on repeated runs.
    INSERT INTO ClarityDataAuditingFramework.AuditLog_CareInsights
        (EventTimeUTC, ServerPrincipalName, DatabaseName, SchemaName,
         ObjectName, Statement, ClientHostName, ClientIP, ApplicationName,
         SucceededFlag, AuditFileOffset)
    SELECT
        af.event_time,
        af.server_principal_name,
        af.database_name,
        af.schema_name,
        af.object_name,
        af.statement,
        af.host_name,            -- client-reported hostname; may be blank/spoofable depending
                                  -- on how the Care Insights connector identifies itself
        af.client_ip,
        af.application_name,
        af.succeeded,
        CONCAT(af.file_name, N'|', af.audit_file_offset)
    FROM sys.fn_get_audit_file(@FilePath, DEFAULT, DEFAULT) af
    WHERE af.action_id = 'SL'  -- SELECT statement completed
      AND NOT EXISTS (
          SELECT 1 FROM ClarityDataAuditingFramework.AuditLog_CareInsights existing
          WHERE existing.AuditFileOffset = CONCAT(af.file_name, N'|', af.audit_file_offset)
      );

    PRINT CONCAT('Loaded ', @@ROWCOUNT, ' new audit record(s).');
END
GO

-- Suggested schedule: run via SQL Agent job every 15-30 min so the
-- log table stays close to real-time for alerting purposes, e.g.:
--   EXEC ClarityDataAuditingFramework.usp_LoadAuditLog;
