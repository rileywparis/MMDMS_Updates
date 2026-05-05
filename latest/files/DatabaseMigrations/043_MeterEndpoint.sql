USE mdms_prod;

IF COL_LENGTH('dbo.Utilities', 'ENDPOINT') IS NULL
BEGIN
    ALTER TABLE dbo.Utilities
    ADD [ENDPOINT] varchar(50) NULL;
END;

IF COL_LENGTH('dbo.Utilities', 'DEV_TYPE') IS NULL
BEGIN
    ALTER TABLE dbo.Utilities
    ADD DEV_TYPE int NULL;
END;

IF COL_LENGTH('dbo.ArchivedUtilities', 'ENDPOINT') IS NULL
BEGIN
    ALTER TABLE dbo.ArchivedUtilities
    ADD [ENDPOINT] varchar(50) NULL;
END;

IF COL_LENGTH('dbo.ArchivedUtilities', 'DEV_TYPE') IS NULL
BEGIN
    ALTER TABLE dbo.ArchivedUtilities
    ADD DEV_TYPE int NULL;
END;