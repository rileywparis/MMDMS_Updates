USE [mdms_prod]

UPDATE u
SET u.FLAG = sf.Flag
FROM Usages u
INNER JOIN StaticFlags sf
    ON u.REF_NO = sf.Flag;

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_GetEstimatedUsage]
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
    DECLARE @PrevMonth INT = CASE WHEN @TargetMonth = 1 THEN 12 ELSE @TargetMonth - 1 END;
    DECLARE @NextMonth INT = CASE WHEN @TargetMonth = 12 THEN 1 ELSE @TargetMonth + 1 END;

    DECLARE @TargetAnchorDate DATE = EOMONTH(DATEFROMPARTS(@TargetYear, @TargetMonth, 1));

    DECLARE @MinSeasonalMonth DATE = DATEFROMPARTS(@TargetYear - @SeasonalYearsBack, 1, 1);
    DECLARE @MinRecentMonth   DATE = DATEADD(MONTH, -@RecentMonthsBack, @TargetAnchorDate);

    DECLARE @MinNeededMonth   DATE = CASE WHEN @MinSeasonalMonth < @MinRecentMonth THEN @MinSeasonalMonth ELSE @MinRecentMonth END;
    DECLARE @MaxNeededMonth   DATE = @TargetAnchorDate;

    ------------------------------------------------------------
    -- STEP 1: Ordered PHYSICAL reads (Filtered) → #Paired
    -- OPTIMIZATION: only include reads that can affect the estimate window
    -- (window reads + one prior read per account)
    ------------------------------------------------------------
    ;WITH PhysicalAll AS
    (
        SELECT
            ACCT_NO,
            CUR_DATE,
            ACT_USAGE
        FROM Usages
        WHERE UTILITY = @Utility
          AND FLAG = 'PHYSICAL'
          AND CUR_DATE <= @TargetAnchorDate
    ),
    PhysicalInWindow AS
    (
        SELECT
            ACCT_NO,
            CUR_DATE,
            ACT_USAGE
        FROM PhysicalAll
        WHERE CUR_DATE >= @MinNeededMonth
    ),
    PriorPhysicalDate AS
    (
        SELECT
            ACCT_NO,
            MAX(CUR_DATE) AS CUR_DATE
        FROM PhysicalAll
        WHERE CUR_DATE < @MinNeededMonth
        GROUP BY ACCT_NO
    ),
    PriorPhysical AS
    (
        SELECT
            p.ACCT_NO,
            p.CUR_DATE,
            p.ACT_USAGE
        FROM PhysicalAll p
        INNER JOIN PriorPhysicalDate d
            ON d.ACCT_NO = p.ACCT_NO
           AND d.CUR_DATE = p.CUR_DATE
    ),
    PhysicalFiltered AS
    (
        SELECT * FROM PhysicalInWindow
        UNION ALL
        SELECT * FROM PriorPhysical
    ),
    OrderedPhysical AS
    (
        SELECT
            ACCT_NO,
            CUR_DATE,
            ACT_USAGE,
            ROW_NUMBER() OVER (PARTITION BY ACCT_NO ORDER BY CUR_DATE) AS rn
        FROM PhysicalFiltered
    )
    SELECT
        p1.ACCT_NO,
        p1.CUR_DATE AS CurrentPhysicalDate,
        p1.ACT_USAGE AS CurrentActUsage,
        p2.CUR_DATE AS PrevPhysicalDate,
        DATEDIFF(MONTH, p2.CUR_DATE, p1.CUR_DATE) AS SpanMonths
    INTO #Paired
    FROM OrderedPhysical p1
    LEFT JOIN OrderedPhysical p2
        ON p1.ACCT_NO = p2.ACCT_NO
       AND p1.rn = p2.rn + 1;

    CREATE CLUSTERED INDEX IX_Paired_AcctDate
        ON #Paired (ACCT_NO, CurrentPhysicalDate);

    ------------------------------------------------------------
    -- STEP 2: Spread ACT_USAGE only for spans 1–12 months → #Spread
    ------------------------------------------------------------
    SELECT
        ACCT_NO,
        PrevPhysicalDate,
        CurrentPhysicalDate,
        SpanMonths,
        (CurrentActUsage * 1.0) / NULLIF(SpanMonths, 0) AS PerMonthUsage
    INTO #Spread
    FROM #Paired
    WHERE SpanMonths BETWEEN 1 AND 12;   -- 12-month cap

    CREATE CLUSTERED INDEX IX_Spread_AcctPrevDate
        ON #Spread (ACCT_NO, PrevPhysicalDate);

    ------------------------------------------------------------
    -- STEP 3: Virtual month rows using dbo.Numbers → #VirtualMonths
    ------------------------------------------------------------

     -- Materialize bounds once (prevents repeated recomputation + helps optimizer)
    SELECT
        s.ACCT_NO,
        s.PrevPhysicalDate,
        s.SpanMonths,
        s.PerMonthUsage,
        CASE
            WHEN DATEDIFF(MONTH, s.PrevPhysicalDate, @MinNeededMonth) < 0 THEN 0
            ELSE DATEDIFF(MONTH, s.PrevPhysicalDate, @MinNeededMonth)
        END AS StartN,
        DATEDIFF(MONTH, s.PrevPhysicalDate, @MaxNeededMonth) AS EndN
    INTO #SpreadBounds
    FROM #Spread s;

    CREATE CLUSTERED INDEX IX_SpreadBounds
        ON #SpreadBounds (StartN, EndN);

    -- Expand months (Numbers should now be scanned once)
    SELECT
        sb.ACCT_NO,
        DATEADD(MONTH, n.n, sb.PrevPhysicalDate) AS UsageMonth,
        sb.PerMonthUsage
    INTO #VirtualMonths
    FROM dbo.Numbers n
    JOIN #SpreadBounds sb
        ON n.n BETWEEN sb.StartN AND sb.EndN
       AND n.n <= sb.SpanMonths
    OPTION (RECOMPILE);;

    ------------------------------------------------------------
    -- STEP 4+: Use #VirtualMonths in CTEs for seasonal/recent/etc
    ------------------------------------------------------------
    ;WITH
    ------------------------------------------------------------
    -- Outlier suppression (recurring-friendly)
    -- Idea: cap per-month usage to (per-account P90 * 1.5).
    -- Recurring pool fills raise P90 naturally; one-off line breaks get clipped.
    ------------------------------------------------------------
    OutlierStats AS (
        SELECT DISTINCT
            ACCT_NO,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY PerMonthUsage)
                OVER (PARTITION BY ACCT_NO) AS P50,
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY PerMonthUsage)
                OVER (PARTITION BY ACCT_NO) AS P90
        FROM #VirtualMonths
        WHERE PerMonthUsage IS NOT NULL
          AND PerMonthUsage >= 0
    ),
    CleanVirtualMonths AS (
        SELECT
            v.ACCT_NO,
            v.UsageMonth,
            CASE
                WHEN v.PerMonthUsage < 0 THEN 0
                WHEN os.P90 IS NOT NULL AND v.PerMonthUsage > (os.P90 * 1.5) THEN (os.P90 * 1.5)
                ELSE v.PerMonthUsage
            END AS CleanUsage
        FROM #VirtualMonths v
        LEFT JOIN OutlierStats os
            ON os.ACCT_NO = v.ACCT_NO
    ),

    ------------------------------------------------------------
    -- Seasonal Window
    ------------------------------------------------------------
    SeasonalWindow AS (
        SELECT
            ACCT_NO,
            CleanUsage AS NormalizedUsage,
            YEAR(UsageMonth) AS ReadYear,
            MONTH(DATEADD(DAY, -@CycleShiftDays, UsageMonth)) AS CycleMonth
        FROM CleanVirtualMonths
    ),
    SeasonalFinal AS (
        SELECT
            ACCT_NO,
            SUM(NormalizedUsage *
                CASE (@TargetYear - ReadYear)
                    WHEN 1 THEN 10
                    WHEN 2 THEN 6
                    WHEN 3 THEN 3
                    WHEN 4 THEN 2
                    ELSE 1
                END
            ) / NULLIF(SUM(
                CASE (@TargetYear - ReadYear)
                    WHEN 1 THEN 10
                    WHEN 2 THEN 6
                    WHEN 3 THEN 3
                    WHEN 4 THEN 2
                    ELSE 1
                END
            ), 0) AS SeasonalAvg
        FROM SeasonalWindow
        WHERE CycleMonth IN (@PrevMonth, @TargetMonth, @NextMonth)
          AND ReadYear BETWEEN @TargetYear - @SeasonalYearsBack AND @TargetYear - 1
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- Recent Average (last X months)
    ------------------------------------------------------------
    RecentWindow AS (
        SELECT
            ACCT_NO,
            CleanUsage AS PerMonthUsage
        FROM CleanVirtualMonths
        WHERE UsageMonth >= DATEADD(MONTH, -@RecentMonthsBack, @TargetAnchorDate)
          AND UsageMonth <= @TargetAnchorDate
    ),
    RecentFinal AS (
        SELECT
            ACCT_NO,
            SUM(PerMonthUsage) / @RecentMonthsBack AS RecentAvg
        FROM RecentWindow
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- Last Physical Read
    ------------------------------------------------------------
    LastPhysical AS (
        SELECT
            ACCT_NO,
            MAX(CUR_DATE) AS LastPhysicalDate
        FROM Usages
        WHERE UTILITY = @Utility
          AND FLAG = 'PHYSICAL'
          AND CUR_DATE < @TargetAnchorDate
        GROUP BY ACCT_NO
    ),

    ------------------------------------------------------------
    -- Estimation streak + accumulated BILL_USAGE
    -- (DO NOT CHANGE: user confirmed this behavior is correct)
    ------------------------------------------------------------
    EstStats AS (
        SELECT
            u.ACCT_NO,
            COUNT(*) AS MonthsSincePhysical,
            SUM(u.BILL_USAGE) AS EstimatedTotalSincePhysical
        FROM Usages u
        INNER JOIN LastPhysical lp ON u.ACCT_NO = lp.ACCT_NO
        WHERE u.CUR_DATE > lp.LastPhysicalDate
          AND u.CUR_DATE <= @TargetAnchorDate
          AND u.UTILITY = @Utility
          AND u.FLAG IN ('ESTIMATE')   -- ONLY COUNT REAL ESTIMATES
        GROUP BY u.ACCT_NO
    )

    ------------------------------------------------------------
    -- FINAL OUTPUT USING SANITY GUARDS + ROUNDING
    ------------------------------------------------------------
    SELECT
        x.ACCT_NO,

        CAST(
            ROUND(
                CASE 
                    WHEN Blended > 999999 THEN 999999
                    WHEN Blended < 300 THEN 300
                    WHEN RecentAvg IS NOT NULL AND Blended > RecentAvg * 2.5 
                        THEN CAST(RecentAvg * 2.5 AS INT)
                    WHEN SeasonalAvg IS NOT NULL AND RecentAvg IS NOT NULL
                         AND (SeasonalAvg > RecentAvg * 3 
                              OR SeasonalAvg < RecentAvg * 0.25)
                        THEN CAST(RecentAvg AS INT)
                    ELSE Blended
                END
            / 100.0, 0
            ) * 100
        AS INT) AS AvgUsage,

        COALESCE(x.MonthsSincePhysical, 0) AS MonthsSincePhysical,
        COALESCE(x.EstimatedTotalSincePhysical, 0) AS EstimatedTotalSincePhysical

    FROM (
        SELECT
            COALESCE(s.ACCT_NO, r.ACCT_NO, e.ACCT_NO) AS ACCT_NO,
            s.SeasonalAvg,
            r.RecentAvg,
            e.MonthsSincePhysical,
            e.EstimatedTotalSincePhysical,

            CAST(
                ROUND(
                    (
                        COALESCE(s.SeasonalAvg, r.RecentAvg, 0) * @SeasonalWeight +
                        COALESCE(r.RecentAvg, s.SeasonalAvg, 0) * @RecentWeight
                    ) / 100.0, 0
                ) * 100
            AS INT) AS Blended

        FROM SeasonalFinal s
        FULL OUTER JOIN RecentFinal r ON s.ACCT_NO = r.ACCT_NO
        FULL OUTER JOIN EstStats e  ON COALESCE(s.ACCT_NO, r.ACCT_NO) = e.ACCT_NO
    ) x
    ORDER BY x.ACCT_NO;

END;
GO
