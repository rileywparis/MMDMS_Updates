USE mdms_prod;

IF COL_LENGTH('dbo.Transactions', 'ADJ') IS NULL
BEGIN
    ALTER TABLE dbo.Transactions
    ADD ADJ bit NOT NULL
        CONSTRAINT DF_Transactions_ADJ DEFAULT (0);
END;