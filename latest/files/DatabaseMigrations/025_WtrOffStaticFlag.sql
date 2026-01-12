use mdms_prod;

IF NOT EXISTS (
    SELECT 1
    FROM StaticFlags
    WHERE Flag = 'WTR OFF'
)
BEGIN
    INSERT INTO StaticFlags (Flag)
    VALUES ('WTR OFF');
END