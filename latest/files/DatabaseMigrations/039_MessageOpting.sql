use mdms_prod;

ALTER TABLE dbo.Accounts 
    ADD MSG_OPT bit NOT NULL DEFAULT 0;
ALTER TABLE dbo.ArchivedAccounts 
    ADD MSG_OPT bit NOT NULL DEFAULT 0;