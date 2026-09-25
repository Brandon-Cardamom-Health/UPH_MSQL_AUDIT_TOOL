/*
====================================================================
 01_create_server_audit.sql

 Purpose : Creates the SERVER AUDIT object and file target that the
           Data Auditing Framework writes to. This is the top-level
           container; the actual "what to capture" logic lives in
           the DATABASE AUDIT SPECIFICATION (see 02_*.sql).

 Scope   : Care Insights vendor monitoring (SOW A-5.0)
 Env     : Run first in TST, promote to prd-copy, then production
           once Jesse/UPH DBA team has reviewed.

 Permissions required to run this script:
   ALTER ANY SERVER AUDIT  (server-level)
   -- NOT sysadmin. This is intentionally the minimum grant.

 Notes:
   - @FilePath must point to a directory the SQL Server service
     account can write to. Update before running.
   - MAX_ROLLOVER_FILES / MAX_FILE_SIZE sized generously for a
     30-60 day retention window; tune after observing real volume
     from Care Insights' actual query pattern.
   - QUEUE_DELAY of 1000ms trades a small durability window for
     lower overhead against production. ON_FAILURE = CONTINUE so a
     full disk / audit failure does NOT block vendor queries
     (avoid accidentally becoming an availability risk to prod).
====================================================================
*/

USE master;
GO

-- Path confirmed working by Jesse (UPH DBA team) — using the LOCAL path
-- rather than the UNC/network equivalent. Jesse successfully created and
-- enabled a test audit using this local path with a login matching
-- Brandon's permission level; the UNC path was never confirmed working
-- and network paths can hit auth issues (Kerberos/SMB) distinct from
-- plain folder permissions, even when NTFS permissions are correct.

IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'Audit_CareInsights_ClarityAccess')
BEGIN
    PRINT 'Server audit already exists — skipping create. Review manually if changes are needed.';
END
ELSE
BEGIN
    CREATE SERVER AUDIT [Audit_CareInsights_ClarityAccess]
    TO FILE
    (
        FILEPATH = N'D:\ClarityDataAuditingFramework\',
        MAXSIZE = 256 MB,
        MAX_ROLLOVER_FILES = 500,
        RESERVE_DISK_SPACE = OFF
    )
    WITH
    (
        QUEUE_DELAY = 1000,
        ON_FAILURE = CONTINUE
    );

    PRINT 'Created SERVER AUDIT [Audit_CareInsights_ClarityAccess]';
END
GO

-- Audit object is created DISABLED by default. Enable explicitly once
-- the database audit specification (02_*.sql) is also in place, so we
-- don't have an active audit with nothing scoped to it.
-- ALTER SERVER AUDIT [Audit_CareInsights_ClarityAccess] WITH (STATE = ON);
-- (left commented intentionally — enable as a deliberate, separate step)
