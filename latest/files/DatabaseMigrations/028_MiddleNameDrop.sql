use mdms_prod;

BEGIN TRY

BEGIN TRAN;

-- 1) Drop indexes on computed columns
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Accounts_FNAME' AND object_id = OBJECT_ID('dbo.Accounts'))
    DROP INDEX IDX_Accounts_FNAME ON dbo.Accounts;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Accounts_REV_FNAME' AND object_id = OBJECT_ID('dbo.Accounts'))
    DROP INDEX IDX_Accounts_REV_FNAME ON dbo.Accounts;

-- 2) Drop computed columns
IF COL_LENGTH('dbo.Accounts', 'FNAME') IS NOT NULL
    ALTER TABLE dbo.Accounts DROP COLUMN FNAME;

IF COL_LENGTH('dbo.Accounts', 'REV_FNAME') IS NOT NULL
    ALTER TABLE dbo.Accounts DROP COLUMN REV_FNAME;

-- 3) Trim FIRST and MIDDLE (keep as '' if empty; NEVER NULL)
UPDATE dbo.Accounts
SET
    FIRST  = LTRIM(RTRIM(ISNULL(FIRST,  ''))),
    MIDDLE = LTRIM(RTRIM(ISNULL(MIDDLE, '')));

-- 4) Collapse double spaces in FIRST and MIDDLE
WHILE EXISTS (SELECT 1 FROM dbo.Accounts WHERE FIRST LIKE '%  %' OR MIDDLE LIKE '%  %')
BEGIN
    UPDATE dbo.Accounts
    SET
        FIRST  = REPLACE(FIRST,  '  ', ' '),
        MIDDLE = REPLACE(MIDDLE, '  ', ' ')
    WHERE FIRST LIKE '%  %' OR MIDDLE LIKE '%  %';
END

-- 5) FIRST = FIRST + ' ' + MIDDLE (only if MIDDLE has content)
UPDATE dbo.Accounts
SET FIRST =
    CASE
        WHEN MIDDLE = '' THEN FIRST
        WHEN FIRST  = '' THEN MIDDLE
        ELSE FIRST + ' ' + MIDDLE
    END;

-- Normalize FIRST again after concat
UPDATE dbo.Accounts
SET FIRST = LTRIM(RTRIM(ISNULL(FIRST, '')));

WHILE EXISTS (SELECT 1 FROM dbo.Accounts WHERE FIRST LIKE '%  %')
BEGIN
    UPDATE dbo.Accounts
    SET FIRST = REPLACE(FIRST, '  ', ' ')
    WHERE FIRST LIKE '%  %';
END

-- 6) Drop DEFAULT constraint on MIDDLE (required before dropping the column)
DECLARE @dfName sysname;
DECLARE @sql nvarchar(4000);

SELECT @dfName = dc.name
FROM sys.default_constraints dc
JOIN sys.columns c
    ON c.object_id = dc.parent_object_id
   AND c.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('dbo.Accounts')
  AND c.name = 'MIDDLE';

IF @dfName IS NOT NULL
BEGIN
    SET @sql = 'ALTER TABLE dbo.Accounts DROP CONSTRAINT ' + @dfName;
    EXEC (@sql);
END

-- 7) Drop MIDDLE column
IF COL_LENGTH('dbo.Accounts', 'MIDDLE') IS NOT NULL
    ALTER TABLE dbo.Accounts DROP COLUMN MIDDLE;

-- 8) Re-add computed columns (still NOT NULL-safe output; avoids weird double spaces)
-- NOTE: If your computed columns were indexed before, keep PERSISTED.
ALTER TABLE dbo.Accounts ADD
FNAME AS
(
    CAST(
        LTRIM(RTRIM(
            CASE
                WHEN FIRST = '' AND LAST = '' THEN ''
                WHEN FIRST = '' THEN LAST
                WHEN LAST  = '' THEN FIRST
                ELSE FIRST + ' ' + LAST
            END
        )) AS varchar(152)
    )
) PERSISTED,
REV_FNAME AS
(
    CAST(
        LTRIM(RTRIM(
            CASE
                WHEN FIRST = '' AND LAST = '' THEN ''
                WHEN FIRST = '' THEN LAST
                WHEN LAST  = '' THEN FIRST
                ELSE LAST + ' ' + FIRST
            END
        )) AS varchar(152)
    )
) PERSISTED;

-- 9) Recreate indexes
CREATE NONCLUSTERED INDEX IDX_Accounts_FNAME
ON dbo.Accounts (FNAME);

CREATE NONCLUSTERED INDEX IDX_Accounts_REV_FNAME
ON dbo.Accounts (REV_FNAME);

-- 10) Drop middle from ArchivedAccounts
IF COL_LENGTH('dbo.ArchivedAccounts', 'MIDDLE') IS NOT NULL
BEGIN
    ALTER TABLE dbo.ArchivedAccounts DROP COLUMN MIDDLE;
END

-- 11) Drop middle from vRuuteSheetData
EXEC('
ALTER VIEW dbo.vRouteSheetData AS
SELECT 
    s.SERV_ID, s.ADDR,
    a.ACCT_NO, a.LAST, a.FIRST, a.REV_FNAME,
    u.UTILITY, u.ROUTE_NO, u.READ_SEQ, u.METER_NO, u.MET_MESS, u.NOTES, u.NO_OF_DIAL,
    lu.CUR_READ, lu.CUR_DATE
FROM dbo.ServiceLocs s
JOIN dbo.Accounts a
    ON s.ACCT_NO = a.ACCT_NO
CROSS APPLY
(
    SELECT TOP (1)
        u.UTILITY, u.SERV_ID, u.ROUTE_NO, u.READ_SEQ, u.METER_NO, u.MET_MESS, u.NOTES, u.NO_OF_DIAL, u.SERV_STAT
    FROM dbo.Utilities u
    WHERE u.SERV_ID = s.SERV_ID
      AND u.SERV_STAT = ''ACTIVE''
    ORDER BY u.UTILITY
) AS u
LEFT JOIN dbo.vLatestUsage lu
    ON lu.SERV_ID = u.SERV_ID;
');

COMMIT TRAN;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH