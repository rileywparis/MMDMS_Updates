use mdms_prod;

IF NOT EXISTS (
    SELECT 1
    FROM sys.tables
    WHERE name = 'BillCycles'
)
BEGIN
    CREATE TABLE BillCycles
    (
        CYCLE   INT NOT NULL,
        STATUS  VARCHAR(20) NOT NULL,
        [DATE]  DATETIME NOT NULL
            CONSTRAINT DF_BillCycles_Date DEFAULT CAST(GETDATE() AS DATE)
    );
END
