use mdms_prod;

IF COL_LENGTH('dbo.Usages', 'RATE_CODE') IS NOT NULL
BEGIN
    ALTER TABLE dbo.Usages DROP COLUMN RATE_CODE;
END
