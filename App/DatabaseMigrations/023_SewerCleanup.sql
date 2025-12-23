USE [mdms_prod]
GO

/****** Object:  View [dbo].[vLatestUsage]    Script Date: 12/22/2025 6:48:11 PM ******/
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
FROM Usages u
JOIN
(
    SELECT
        SERV_ID,
        MAX(TRAN_DATE) AS MaxTranDate
    FROM Usages
    WHERE UTILITY = 1
    GROUP BY SERV_ID
) m
    ON m.SERV_ID = u.SERV_ID
   AND m.MaxTranDate = u.TRAN_DATE
WHERE u.UTILITY = 1
GO

USE [mdms_prod]
GO

/****** Object:  View [dbo].[vRouteSheetData]    Script Date: 12/22/2025 7:14:41 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER VIEW [dbo].[vRouteSheetData] AS
SELECT 
    s.SERV_ID,
    a.ACCT_NO,
    a.LAST, a.FIRST, a.MIDDLE, a.REV_FNAME,
    s.ADDR,
    u.UTILITY, u.ROUTE_NO, u.READ_SEQ, u.METER_NO, u.MET_MESS, u.NOTES, u.NO_OF_DIAL,
    lu.CUR_READ, lu.CUR_DATE
FROM dbo.ServiceLocs s
JOIN dbo.Accounts a
    ON s.ACCT_NO = a.ACCT_NO
CROSS APPLY
(
    SELECT TOP (1)
        u.UTILITY, u.SERV_ID, u.ROUTE_NO, u.READ_SEQ, u.METER_NO, u.MET_MESS, u.NOTES, u.NO_OF_DIAL,
        u.SERV_STAT
    FROM dbo.Utilities u
    WHERE u.SERV_ID = s.SERV_ID
      AND u.SERV_STAT = 'ACTIVE'
    ORDER BY u.UTILITY
) AS u
LEFT JOIN dbo.vLatestUsage lu
    ON lu.SERV_ID = u.SERV_ID;
GO

DROP FUNCTION IF EXISTS fDEPWaterUsage;
