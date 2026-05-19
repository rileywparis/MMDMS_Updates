USE [mdms_prod]
GO

/****** Object:  View [dbo].[vLatestUsage]    Script Date: 5/3/2026 11:47:15 PM ******/
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
    WHERE UTILITY = 1 AND FLAG != 'ESTIMATE'
) s
CROSS APPLY
(
    SELECT TOP 1 *
    FROM dbo.Usages u
    WHERE u.SERV_ID = s.SERV_ID
      AND u.UTILITY = 1 AND FLAG != 'ESTIMATE'
    ORDER BY u.CUR_DATE DESC, u.USAGE_PK DESC
) u;
GO


