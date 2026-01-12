use mdms_prod;

IF NOT EXISTS (
    SELECT 1
    FROM StaticFlags
    WHERE Flag = 'NEW CYCLE'
)
BEGIN
    INSERT INTO StaticFlags (Flag)
    VALUES ('NEW CYCLE');
END