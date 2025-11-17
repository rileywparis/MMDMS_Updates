CREATE PROCEDURE usp_GetEstimatedUsage
(
    @TargetYear         INT,
    @TargetMonth        INT,
    @Utility            INT,
    @SeasonalYearsBack  INT,
    @RecentMonthsBack   INT,
    @SeasonalWeight     DECIMAL(5,2),
    @RecentWeight       DECIMAL(5,2),
    @CycleShiftDays     INT
)
AS
BEGIN
    SET NOCOUNT ON;

    ------------------------------------------------------------
    -- DERIVED VALUES
    ------------------------------------------------------------
    DECLARE @PrevMonth INT = CASE WHEN @TargetMonth = 1  THEN 12 ELSE @TargetMonth - 1 END;
    DECLARE @NextMonth INT = CASE WHEN @TargetMonth = 12 THEN 1  ELSE @TargetMonth + 1 END;

    DECLARE @TargetAnchorDate DATE = EOMONTH(DATEFROMPARTS(@TargetYear, @TargetMonth, 1));

    ------------------------------------------------------------
    -- PHYSICAL READS PREP
    ------------------------------------------------------------
    WITH PhysicalReads AS (
        SELECT
            ACCT_NO,
            CUR_DATE,
            ACT_USAGE,
            BILL_USAGE,
            YEAR(CUR_DATE) AS ReadYear,
            MONTH(DATEADD(DAY, -@CycleShiftDays, CUR_DATE)) AS CycleMonth,
            FLAG
        FROM Usages
        WHERE UTILITY = @Utility
          AND REF_NO NOT IN ('CHANGEOUT', 'ROLLOVER')
    ),

    ------------------------------------------------------------
    -- 1. SEASONAL WINDOW
    ------------------------------------------------------------
    SeasonalWindow AS (
        SELECT
            ACCT_NO,
            ACT_USAGE,
            ReadYear,
            CASE (@TargetYear - ReadYear)
                WHEN 1 THEN 10
                WHEN 2 THEN 6
                WHEN 3 THEN 3
                WHEN 4 THEN 2
                ELSE 1
            END AS Weight
        FROM PhysicalReads
        WHERE FLAG = 'PHYSICAL'
          AND CycleMonth IN (@PrevMonth, @TargetMonth, @NextMonth)
          AND ReadYear BETWEEN (@TargetYear - @SeasonalYearsBack) AND (@TargetYear - 1)
    ),

    SeasonalFinal AS (
        SELECT
            ACCT_NO,
            SUM(ACT_USAGE * Weight) * 1.0 / NULLIF(SUM(Weight), 0) AS SeasonalAvg
        FROM SeasonalWindow
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- 2. RECENT 12-MONTH AVERAGE (PHYSICAL ONLY)
    ------------------------------------------------------------
    Recent AS (
        SELECT
            ACCT_NO,
            AVG(ACT_USAGE * 1.0) AS RecentAvg
        FROM PhysicalReads
        WHERE FLAG = 'PHYSICAL'
          AND CUR_DATE >= DATEADD(MONTH, -@RecentMonthsBack, @TargetAnchorDate)
          AND CUR_DATE <= @TargetAnchorDate
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- 3. FIND LAST PHYSICAL READ PER ACCOUNT
    ------------------------------------------------------------
    LastPhysical AS (
        SELECT
            ACCT_NO,
            MAX(CUR_DATE) AS LastPhysicalDate
        FROM PhysicalReads
        WHERE FLAG = 'PHYSICAL'
          AND CUR_DATE < @TargetAnchorDate
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- 4. CALCULATE MONTHS SINCE PHYSICAL + TOTAL ESTIMATED USAGE
    ------------------------------------------------------------
    EstStats AS (
        SELECT
            u.ACCT_NO,
            COUNT(*) AS MonthsSincePhysical,
            SUM(u.BILL_USAGE) AS EstimatedTotalSincePhysical
        FROM Usages u
        INNER JOIN LastPhysical lp
            ON lp.ACCT_NO = u.ACCT_NO
        WHERE u.CUR_DATE > lp.LastPhysicalDate
          AND u.CUR_DATE <= @TargetAnchorDate
          AND u.FLAG <> 'PHYSICAL'
          AND u.UTILITY = @Utility
        GROUP BY u.ACCT_NO
    )

    ------------------------------------------------------------
    -- 5. FINAL OUTPUT
    ------------------------------------------------------------
    SELECT
        COALESCE(s.ACCT_NO, r.ACCT_NO, e.ACCT_NO) AS ACCT_NO,

        -- FINAL ESTIMATE BLENDED
        CAST(
            ROUND(
                (
                    COALESCE(s.SeasonalAvg, r.RecentAvg, 0) * @SeasonalWeight +
                    COALESCE(r.RecentAvg, s.SeasonalAvg, 0) * @RecentWeight
                ) / 100.0, 0
            ) * 100
        AS INT) AS AvgUsage,

        -- MONTHS SINCE LAST PHYSICAL (0 if none)
        COALESCE(e.MonthsSincePhysical, 0) AS MonthsSincePhysical,

        -- TOTAL BILLED ESTIMATES SINCE LAST PHYSICAL
        COALESCE(e.EstimatedTotalSincePhysical, 0) AS EstimatedTotalSincePhysical

    FROM SeasonalFinal s
    FULL OUTER JOIN Recent r ON s.ACCT_NO = r.ACCT_NO
    FULL OUTER JOIN EstStats e ON COALESCE(s.ACCT_NO, r.ACCT_NO) = e.ACCT_NO
    ORDER BY ACCT_NO;

END;
GO
