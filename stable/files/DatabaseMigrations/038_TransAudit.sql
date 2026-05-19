use mdms_prod;

ALTER TABLE dbo.Usages DROP COLUMN TOTAL, PREV_BALANCE, BALANCE;
ALTER TABLE dbo.Usages 
    ADD [SIZE] varchar(50) NULL, 
        NO_OF_MIN int NULL, 
        RATE_CODE varchar(50) NULL;