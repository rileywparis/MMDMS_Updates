USE [mdms_prod]
GO

/****** Object:  View [dbo].[vLatestUsage]    Script Date: 4/10/2026 1:45:22 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER   VIEW [dbo].[vLatestUsage] AS
SELECT
    u.SERV_ID,
    u.UTILITY,
    u.CUR_READ,
    u.PRIOR_READ,
    u.CUR_DATE,
    u.PRIOR_DATE
FROM
(
    SELECT DISTINCT SERV_ID
    FROM dbo.Usages
    WHERE UTILITY = 1
) s
CROSS APPLY
(
    SELECT TOP 1 *
    FROM dbo.Usages u
    WHERE u.SERV_ID = s.SERV_ID
      AND u.UTILITY = 1
    ORDER BY u.CUR_DATE DESC, u.USAGE_PK DESC
) u;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_Usages_LatestWater_ByService'
      AND object_id = OBJECT_ID('dbo.Usages')
)
BEGIN
    CREATE INDEX IX_Usages_LatestWater_ByService
    ON dbo.Usages (SERV_ID, CUR_DATE DESC, USAGE_PK DESC)
    INCLUDE (UTILITY, CUR_READ, PRIOR_READ, PRIOR_DATE)
    WHERE UTILITY = 1;
END

UPDATE STATISTICS dbo.Usages WITH FULLSCAN;


