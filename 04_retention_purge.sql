/*
====================================================================
 04_retention_purge.sql

 Purpose : Enforces the 30-60 day query log retention window from
           SOW A-5.0. Kept separate from the loader (03_*.sql) so
           deletion logic is reviewed/approved on its own — this is
           the one script in the framework that permanently discards
           data, so it deserves extra scrutiny from Jesse/UPH before
           it ever runs against prd-copy or production.

 Two things get purged on a schedule:
   1. Rows in ClarityDataAuditingFramework.AuditLog_CareInsights older than @RetentionDays.
   2. The underlying .sqlaudit files themselves, once no longer
      needed — SQL Server's MAX_ROLLOVER_FILES (01_*.sql) caps
      total file count/size, but doesn't purge on a calendar basis,
      so this script's file cleanup enforces the actual day-based
      window the SOW commits to.

 @RetentionDays defaults to 45 (middle of the 30-60 day range) —
 confirm the exact number with UPH stakeholders during guardrail
 definition; this should be a config value, not a guess.
====================================================================
*/

USE ClarityUtil;
GO

CREATE OR ALTER PROCEDURE ClarityDataAuditingFramework.usp_PurgeAuditLog
    @RetentionDays INT = 45,   -- TODO: confirm exact retention value with UPH (30-60 day range per SOW)
    @DryRun BIT = 1             -- default to dry run; caller must explicitly pass 0 to actually delete
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CutoffUTC DATETIME2(3) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DECLARE @RowsToDelete INT;

    SELECT @RowsToDelete = COUNT(*)
    FROM ClarityDataAuditingFramework.AuditLog_CareInsights
    WHERE EventTimeUTC < @CutoffUTC;

    IF @DryRun = 1
    BEGIN
        PRINT CONCAT('[DRY RUN] Would delete ', @RowsToDelete,
                      ' row(s) older than ', CONVERT(VARCHAR(23), @CutoffUTC, 126), ' UTC.');
        PRINT '[DRY RUN] No rows deleted. Re-run with @DryRun = 0 to actually purge.';
        RETURN;
    END

    DELETE FROM ClarityDataAuditingFramework.AuditLog_CareInsights
    WHERE EventTimeUTC < @CutoffUTC;

    PRINT CONCAT('Deleted ', @@ROWCOUNT, ' row(s) older than ', CONVERT(VARCHAR(23), @CutoffUTC, 126), ' UTC.');

    -- Raw .sqlaudit file cleanup is NOT automated here. Deleting the
    -- wrong file on a production audit path is high-risk to do from
    -- inside T-SQL with no undo. Recommend handling file-level purge
    -- as a reviewed, manual/scheduled OS-level task (e.g. a scheduled
    -- task or Agent job step running forfiles/PowerShell) that Jesse's
    -- team owns, rather than folding it into this proc.
END
GO

-- Usage:
--   EXEC ClarityDataAuditingFramework.usp_PurgeAuditLog @RetentionDays = 45, @DryRun = 1;  -- review counts first
--   EXEC ClarityDataAuditingFramework.usp_PurgeAuditLog @RetentionDays = 45, @DryRun = 0;  -- then actually purge
