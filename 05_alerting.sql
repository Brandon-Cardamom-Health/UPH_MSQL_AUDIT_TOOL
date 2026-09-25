/*
====================================================================
 05_alerting.sql

 Purpose : Monitoring and Alerting Build deliverable (SOW A-5.0).
           Evaluates ClarityDataAuditingFramework.AuditLog_CareInsights against configurable
           guardrail rules and emails UPH's designated notification
           channel via sp_send_dbmail when activity is flagged.

 IMPORTANT — division of responsibility (per UPH tech spec doc):
   - Database Mail (SMTP server/profile/account) is a ONE-TIME setup
     done by UPH's own DBA using their own credentials. This script
     does NOT configure Database Mail — it assumes a profile named
     by @MailProfileName already exists and is usable.
   - The audit tooling's service account only needs EXECUTE on
     sp_send_dbmail + DatabaseMailUserRole to actually send — it does
     not need sysadmin/CONTROL SERVER to configure mail, matching the
     permission list UPH's team already scoped (CONTROL SERVER was
     struck from that request).

 STATUS: Scaffolding only. Two of UPH's discovery questions are
 still open and directly gate what rules actually fire:
   - "What is the email alert criteria?"
   - "Describe the unusual activity alerting (List of Recipients)"
 Guardrail thresholds and recipients are config data below with
 clearly marked placeholders — swap in real values once guardrail
 definition sessions (Analytics/Security/Internal Audit) conclude.
 Do not enable the SQL Agent job against production before that.
====================================================================
*/

USE ClarityUtil;
GO

-- --------------------------------------------------------------
-- Config: who gets notified
-- --------------------------------------------------------------
IF OBJECT_ID('ClarityDataAuditingFramework.AuditConfig_AlertRecipients', 'U') IS NULL
BEGIN
    CREATE TABLE ClarityDataAuditingFramework.AuditConfig_AlertRecipients
    (
        RecipientEmail   NVARCHAR(320) NOT NULL PRIMARY KEY,
        IsActive         BIT           NOT NULL DEFAULT 1,
        Notes            NVARCHAR(200) NULL
    );
    -- PLACEHOLDER — replace with UPH's actual notification channel/recipient list
    INSERT INTO ClarityDataAuditingFramework.AuditConfig_AlertRecipients (RecipientEmail, Notes)
    VALUES (N'placeholder-security-team@example.org', N'PLACEHOLDER — confirm real recipient list with UPH');
    PRINT 'Created ClarityDataAuditingFramework.AuditConfig_AlertRecipients (placeholder recipient — replace before enabling)';
END
GO

-- --------------------------------------------------------------
-- Config: guardrail rules
-- Kept generic/data-driven since exact thresholds are still TBD
-- from guardrail definition sessions.
-- --------------------------------------------------------------
IF OBJECT_ID('ClarityDataAuditingFramework.AuditConfig_GuardrailRules', 'U') IS NULL
BEGIN
    CREATE TABLE ClarityDataAuditingFramework.AuditConfig_GuardrailRules
    (
        RuleID              INT IDENTITY(1,1) PRIMARY KEY,
        RuleName             NVARCHAR(100)  NOT NULL,
        RuleDescription      NVARCHAR(400)  NULL,
        RuleType             NVARCHAR(30)   NOT NULL,  -- 'OffHoursQuery' | 'VolumeThreshold' | 'UnapprovedTable'
        ThresholdValue       INT            NULL,      -- meaning depends on RuleType
        ActiveWindowStartUTC TIME           NULL,       -- for OffHoursQuery-style rules
        ActiveWindowEndUTC   TIME           NULL,
        IsEnabled            BIT            NOT NULL DEFAULT 0  -- OFF by default until confirmed
    );

    -- PLACEHOLDER rules — illustrative only, disabled by default.
    INSERT INTO ClarityDataAuditingFramework.AuditConfig_GuardrailRules
        (RuleName, RuleDescription, RuleType, ThresholdValue, IsEnabled)
    VALUES
        (N'HighVolumeQuery',
         N'PLACEHOLDER: flag if a single query returns more rows than expected. Confirm threshold with UPH.',
         N'VolumeThreshold', NULL, 0),
        (N'OffScheduleActivity',
         N'PLACEHOLDER: flag activity outside Care Insights'' expected extract schedule. Confirm schedule with UPH.',
         N'OffHoursQuery', NULL, 0);

    PRINT 'Created ClarityDataAuditingFramework.AuditConfig_GuardrailRules (rules disabled — thresholds not yet confirmed)';
END
GO

-- --------------------------------------------------------------
-- Flagged activity log — every evaluation run's findings land here,
-- independent of whether email actually went out. Gives Internal
-- Audit a queryable history even if mail delivery has issues.
-- --------------------------------------------------------------
IF OBJECT_ID('ClarityDataAuditingFramework.AuditFlaggedActivity', 'U') IS NULL
BEGIN
    CREATE TABLE ClarityDataAuditingFramework.AuditFlaggedActivity
    (
        FlaggedActivityID  BIGINT IDENTITY(1,1) PRIMARY KEY,
        AuditLogID          BIGINT        NOT NULL,
        RuleID               INT           NOT NULL,
        FlaggedAtUTC         DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        EmailSent            BIT           NOT NULL DEFAULT 0,
        EmailSentAtUTC       DATETIME2(3)  NULL,
        FOREIGN KEY (AuditLogID) REFERENCES ClarityDataAuditingFramework.AuditLog_CareInsights(AuditLogID),
        FOREIGN KEY (RuleID) REFERENCES ClarityDataAuditingFramework.AuditConfig_GuardrailRules(RuleID)
    );
    PRINT 'Created ClarityDataAuditingFramework.AuditFlaggedActivity';
END
GO

-- --------------------------------------------------------------
-- Evaluation + alert proc
-- --------------------------------------------------------------
CREATE OR ALTER PROCEDURE ClarityDataAuditingFramework.usp_EvaluateGuardrailsAndAlert
    @MailProfileName SYSNAME = N'CardamomAudit_MailProfile',  -- TODO: confirm actual profile name with UPH DBA (their setup)
    @LookbackMinutes INT = 30,                                  -- matches suggested loader schedule
    @DryRun BIT = 1                                             -- default: evaluate + log, but don't send mail
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SinceUTC DATETIME2(3) = DATEADD(MINUTE, -@LookbackMinutes, SYSUTCDATETIME());

    -- Rule: OffScheduleActivity — flag SELECTs outside the configured window.
    -- (No-op while rule is disabled / window columns are NULL.)
    INSERT INTO ClarityDataAuditingFramework.AuditFlaggedActivity (AuditLogID, RuleID)
    SELECT al.AuditLogID, r.RuleID
    FROM ClarityDataAuditingFramework.AuditLog_CareInsights al
    CROSS JOIN ClarityDataAuditingFramework.AuditConfig_GuardrailRules r
    WHERE r.RuleType = N'OffHoursQuery'
      AND r.IsEnabled = 1
      AND al.EventTimeUTC >= @SinceUTC
      AND r.ActiveWindowStartUTC IS NOT NULL
      AND r.ActiveWindowEndUTC IS NOT NULL
      AND CAST(al.EventTimeUTC AS TIME) NOT BETWEEN r.ActiveWindowStartUTC AND r.ActiveWindowEndUTC
      AND NOT EXISTS (
          SELECT 1 FROM ClarityDataAuditingFramework.AuditFlaggedActivity existing
          WHERE existing.AuditLogID = al.AuditLogID AND existing.RuleID = r.RuleID
      );

    -- Rule: VolumeThreshold — placeholder structure; real evaluation needs
    -- affected/response row counts, which requires extending the loader
    -- (03_*.sql) to also capture af.affected_rows / af.response_rows from
    -- fn_get_audit_file. Not wired up yet — left as a stub so the shape
    -- of the framework is visible without guessing at a threshold.
    -- TODO: extend AuditLog_CareInsights with a RowCount column once
    -- guardrail sessions confirm this is a rule UPH wants.

    DECLARE @FlaggedCount INT = @@ROWCOUNT;

    IF @DryRun = 1
    BEGIN
        PRINT CONCAT('[DRY RUN] Evaluation complete. New flags this run logged to ',
                      'ClarityDataAuditingFramework.AuditFlaggedActivity. No email sent (@DryRun = 1).');
        RETURN;
    END

    -- Send one consolidated email per run for anything newly flagged and
    -- not yet emailed, rather than one email per row (avoids flooding
    -- the recipient list if many rows trip a rule at once).
    DECLARE @Body NVARCHAR(MAX);
    DECLARE @RecipientList NVARCHAR(MAX);

    SELECT @RecipientList = STRING_AGG(RecipientEmail, N';')
    FROM ClarityDataAuditingFramework.AuditConfig_AlertRecipients
    WHERE IsActive = 1;

    IF @RecipientList IS NULL
    BEGIN
        PRINT 'No active recipients configured in ClarityDataAuditingFramework.AuditConfig_AlertRecipients — skipping send.';
        RETURN;
    END

    SELECT @Body = (
        SELECT
            fa.FlaggedAtUTC AS [Flagged At (UTC)],
            r.RuleName      AS [Rule],
            al.SchemaName   AS [Schema],
            al.ObjectName   AS [Table],
            al.EventTimeUTC AS [Query Time (UTC)]
        FROM ClarityDataAuditingFramework.AuditFlaggedActivity fa
        JOIN ClarityDataAuditingFramework.AuditConfig_GuardrailRules r ON r.RuleID = fa.RuleID
        JOIN ClarityDataAuditingFramework.AuditLog_CareInsights al ON al.AuditLogID = fa.AuditLogID
        WHERE fa.EmailSent = 0
        FOR XML PATH('Row'), ELEMENTS
    );

    IF @Body IS NULL
    BEGIN
        PRINT 'No unsent flagged activity — nothing to email.';
        RETURN;
    END

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = @MailProfileName,
        @recipients   = @RecipientList,
        @subject      = N'[Care Insights Audit] Flagged activity detected',
        @body         = @Body,
        @body_format  = N'HTML';

    UPDATE ClarityDataAuditingFramework.AuditFlaggedActivity
    SET EmailSent = 1, EmailSentAtUTC = SYSUTCDATETIME()
    WHERE EmailSent = 0;

    PRINT 'Alert email sent and flagged rows marked as notified.';
END
GO

-- Usage (schedule via SQL Agent, after usp_LoadAuditLog in the same job or
-- a follow-on step, e.g. every 15-30 min):
--   EXEC ClarityDataAuditingFramework.usp_EvaluateGuardrailsAndAlert @DryRun = 1;  -- while rules/recipients are placeholders
--   EXEC ClarityDataAuditingFramework.usp_EvaluateGuardrailsAndAlert @DryRun = 0;  -- once confirmed and enabled
