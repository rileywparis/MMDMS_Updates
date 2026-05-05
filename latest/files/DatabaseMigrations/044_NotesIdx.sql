use mdms_prod;

-- 1) Key lookup index for CREATE_FOR (main one needed)
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Notes_CREATE_FOR'
      AND object_id = OBJECT_ID(N'dbo.Notes')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Notes_CREATE_FOR
        ON dbo.Notes (CREATE_FOR);
END
GO