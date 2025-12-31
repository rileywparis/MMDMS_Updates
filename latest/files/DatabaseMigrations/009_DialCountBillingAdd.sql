ALTER VIEW [dbo].[vBillingData] AS
WITH RankedRows AS (
    SELECT 
        u.SERV_ID, u.ACCT_NO, u.UTILITY, u.RATE_CODE, u.ROUTE_NO, u.READ_SEQ, u.METER_NO, u.NO_OF_DIAL,
        lu.CUR_READ, lu.CUR_DATE,
        a.REV_FNAME, a.FNAME, a.FIRST, a.MIDDLE, a.LAST, a.BILL_ADDR, CUSTNOTE,
        s.STREET, s.NUMBER, s.SUFFIX,
        ROW_NUMBER() OVER (PARTITION BY u.SERV_ID ORDER BY u.UTILITY) AS RowNum
    FROM Utilities u
    JOIN Accounts a ON u.ACCT_NO = a.ACCT_NO
    JOIN ServiceLocs s ON s.SERV_ID = u.SERV_ID
    LEFT JOIN vLatestUsage lu 
        ON u.SERV_ID = lu.SERV_ID 
       AND u.UTILITY = lu.UTILITY
    WHERE u.SERV_STAT = 'ACTIVE'
)
SELECT *
FROM RankedRows;