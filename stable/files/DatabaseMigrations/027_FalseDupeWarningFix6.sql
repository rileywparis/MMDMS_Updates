USE [mdms_prod]
GO

/****** Object:  View [dbo].[vLatestUsage]    Script Date: 1/12/2026 12:54:20 AM ******/
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
FROM dbo.Usages u
JOIN
(
    SELECT
        SERV_ID,
        MAX(USAGE_PK) AS MaxUsagePk
    FROM dbo.Usages
    WHERE UTILITY = 1
    GROUP BY SERV_ID
) m
    ON m.SERV_ID = u.SERV_ID
   AND m.MaxUsagePk = u.USAGE_PK
WHERE u.UTILITY = 1;
GO


