USE [mdms_prod]
GO

/****** Object:  StoredProcedure [dbo].[usp_GetEstimatedUsage]    Script Date: 11/23/2025 6:21:54 PM ******/
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

    DECLARE @TargetAnchorDate DATE =
        EOMONTH(DATEFROMPARTS(@TargetYear, @TargetMonth, 1));

    ------------------------------------------------------------
    -- STEP 1: Ordered PHYSICAL reads (CTE) → #Paired
    ------------------------------------------------------------
    ;WITH OrderedPhysical AS (
        SELECT
            ACCT_NO,
            CUR_DATE,
            ACT_USAGE,
            ROW_NUMBER() OVER (PARTITION BY ACCT_NO ORDER BY CUR_DATE) AS rn
        FROM Usages
        WHERE UTILITY = @Utility
          AND FLAG = 'PHYSICAL'
          AND REF_NO NOT IN ('CHANGEOUT','ROLLOVER','NEW UTILITY') --match DbCfg StaticFlags
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
    SELECT
        s.ACCT_NO,
        DATEADD(MONTH, n.n, s.PrevPhysicalDate) AS UsageMonth,
        s.PerMonthUsage
    INTO #VirtualMonths
    FROM #Spread s
    JOIN dbo.Numbers n
        ON n.n <= s.SpanMonths;

    CREATE CLUSTERED INDEX IX_VirtualMonths_AcctMonth
        ON #VirtualMonths (ACCT_NO, UsageMonth);

    ------------------------------------------------------------
    -- STEP 4+: Use #VirtualMonths in CTEs for seasonal/recent/etc
    ------------------------------------------------------------
    ;WITH
    ------------------------------------------------------------
    -- Seasonal Window
    ------------------------------------------------------------
    SeasonalWindow AS (
        SELECT
            ACCT_NO,
            PerMonthUsage AS NormalizedUsage,
            YEAR(UsageMonth) AS ReadYear,
            MONTH(DATEADD(DAY, -@CycleShiftDays, UsageMonth)) AS CycleMonth
        FROM #VirtualMonths
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
            PerMonthUsage
        FROM #VirtualMonths
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
          AND u.FLAG <> 'PHYSICAL'
          AND u.UTILITY = @Utility
        GROUP BY u.ACCT_NO
    )

    ------------------------------------------------------------
    -- FINAL OUTPUT USING SANITY GUARDS + ROUNDING
    ------------------------------------------------------------
    SELECT
        x.ACCT_NO,

        -- FINAL AVG USAGE WITH SANITY GUARDS + ROUND TO NEAREST 100
        CAST(
            ROUND(
                CASE 
                    ----------------------------------------------------
                    -- 5. Fail-safe absolute max (prevent insane values)
                    ----------------------------------------------------
                    WHEN Blended > 999999 THEN 999999

                    ----------------------------------------------------
                    -- 2. MINIMUM guard (prevent 0/100/200 gallon months)
                    ----------------------------------------------------
                    WHEN Blended < 300 THEN 300

                    ----------------------------------------------------
                    -- 3. MAX CAP based on RecentAvg (outlier guard)
                    ----------------------------------------------------
                    WHEN RecentAvg IS NOT NULL AND Blended > RecentAvg * 2.5 
                        THEN CAST(RecentAvg * 2.5 AS INT)

                    ----------------------------------------------------
                    -- 4. Seasonal sanity fallback
                    ----------------------------------------------------
                    WHEN SeasonalAvg IS NOT NULL AND RecentAvg IS NOT NULL
                         AND (SeasonalAvg > RecentAvg * 3 
                              OR SeasonalAvg < RecentAvg * 0.25)
                        THEN CAST(RecentAvg AS INT)

                    ----------------------------------------------------
                    ELSE Blended
                END
            / 100.0, 0   -- ROUND TO NEAREST 100
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

            ----------------------------------------------------
            -- Raw blended estimate before guards
            ----------------------------------------------------
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


