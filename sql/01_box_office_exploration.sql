-- ============================================================================
-- Box office exploration: raw table checks before modeling
-- Table: cinema-analytics-511621.cinema_raw.cinema_box_office
-- Source: https://www.kaggle.com/datasets/aditya126/movies-box-office-dataset-2000-2024?resource=download
-- License: https://opendatacommons.org/licenses/odbl/1-0/
-- Downloaded: 2026-10-15
--
-- What the table is:
--   * One row per title per year: the top 200 titles by worldwide gross for each
--     year (25 years x 200 = 5,000 rows). Totals are for the top 200 only, not
--     the whole industry.
--   * (Year, Rank) uniquely identifies every row; ranks run 1-200 in every year.
--   * The title alone is not unique: 43 titles repeat, mostly across years.
--
-- Decisions for staging:
--   * Use (Year, Rank) as the row key.
--   * metadata_status: 'missing' (null or zero votes), 'suspect' (shares exact
--     metadata with a different title and has 15+ votes), otherwise 'ok'.
--   * rating_reliable = true only when Vote_Count >= 15.
--   * Keep _Worldwide as the authoritative total. Add unallocated_gross
--     (worldwide - domestic - foreign) and flag any row where it exceeds 5% of
--     worldwide (currently only the 2021 Lord of the Rings re-release).
--   * Zero foreign gross is a real domestic-only release. Zero domestic gross
--     looks like a real foreign-only release. Do not treat either as missing.
--   * Do not delete rows; flag them.
--
-- Tip: highlight one query and run it on its own, or run the whole file.
-- ============================================================================


-- Query: 1. size and span
-- Purpose: count rows and distinct titles, and find the first and last year
-- Finding: 5,000 rows but only 4,955 distinct titles, so some titles repeat
-- Next step: find which titles repeat and why (queries 4 and 5)
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT `Release Group`) AS distinct_titles,
  MIN(Year) AS first_year,
  MAX(Year) AS last_year
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`;


-- Query: 2. titles and total gross per year
-- Purpose: look for dips, spikes, or years with unusual coverage
-- Finding: clear dip in total worldwide gross in 2020 (COVID)
-- Next step: check whether the 2021-2024 recovery is visible in the dashboard
SELECT
  Year,
  COUNT(*) AS titles,
  ROUND(SUM(_Worldwide) / 1e9, 2) AS worldwide_billions  -- gross in billions
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY Year
ORDER BY Year;


-- Query: 3. years that do not have exactly 200 titles
-- Purpose: test the top-200-per-year pattern
-- Finding: no rows returned, so every year has exactly 200 titles
-- Next step: document the top-200 scope in the README
SELECT Year, COUNT(*) AS titles
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY Year
HAVING COUNT(*) <> 200;


-- Query: 4. titles that appear more than once, with their years
-- Purpose: explain the gap between 5,000 rows and 4,955 distinct titles
-- Finding: 43 titles repeat, nearly all across different years (re-releases or
--   different films with the same name); 45 extra rows in total
-- Next step: check how many repeats share metadata (query 7)
SELECT
  `Release Group`,
  COUNT(*) AS appearances,
  ARRAY_AGG(Year ORDER BY Year) AS years  -- which years each title shows up in
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY `Release Group`
HAVING COUNT(*) > 1
ORDER BY appearances DESC, `Release Group`;


-- Query: 5. same-year duplicates, showing every copy
-- Purpose: compare the copies to see if they are different films or a true duplicate row
-- Finding: one title appears twice in the same year (2022); compare Rank, grosses,
--   and metadata to decide whether it is a different film or a duplicate row
-- Next step: use (Year, Rank) as the key instead of (title, year)
SELECT *
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
WHERE TRUE  -- QUALIFY needs a WHERE, GROUP BY, or HAVING clause alongside it
QUALIFY COUNT(*) OVER (PARTITION BY `Release Group`, Year) > 1
ORDER BY `Release Group`, Year, `Rank`;


-- Query: 6. test year + rank as a unique key
-- Purpose: find out whether (Year, Rank) identifies each row exactly once
-- Finding: no rows returned, so (Year, Rank) uniquely identifies every row
-- Next step: use it as the key in staging and as the unique test in dbt
SELECT Year, `Rank`, COUNT(*) AS n
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY Year, `Rank`
HAVING COUNT(*) > 1;


-- Query: 7. different titles sharing identical metadata
-- Purpose: find likely bad matches between box-office rows and metadata
--   (example: East Is East and East/West share rating, votes, language, countries)
-- Finding: 35 groups of different titles share identical metadata: 170 titles share
--   null metadata (no match found), 8 Japanese titles share 0 votes, and the rest are
--   pairs of different titles with matching data, probably wrong matches
-- Next step: flag these rows in staging rather than delete them
SELECT
  Rating,
  Vote_Count,
  Original_Language,
  Production_Countries,
  COUNT(DISTINCT `Release Group`) AS different_titles,
  ARRAY_AGG(DISTINCT `Release Group` LIMIT 5) AS example_titles  -- a few examples per group
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY Rating, Vote_Count, Original_Language, Production_Countries
HAVING COUNT(DISTINCT `Release Group`) > 1
ORDER BY different_titles DESC;


-- Query: 8. do worldwide, domestic, and foreign grosses add up?
-- Purpose: count rows where worldwide differs from domestic + foreign, and zero-foreign rows
-- Finding: 63 rows do not add up; 43 rows have zero foreign gross
-- Next step: classify the 63 (query 10), then check zero-foreign rows (query 9)
SELECT
  COUNT(*) AS total_rows,
  COUNTIF(ABS(_Worldwide - (_Domestic + _Foreign)) > 1) AS rows_not_adding_up,  -- > $1 ignores float noise
  COUNTIF(_Foreign = 0) AS zero_foreign_rows
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`;


-- Query: 9. are zero-foreign rows real domestic-only releases?
-- Purpose: separate genuine domestic-only films from rows with missing foreign revenue
-- Finding: 43 are domestic-only (worldwide equals domestic); 0 look like missing foreign revenue
-- Next step: treat zero foreign as a real zero in staging
SELECT
  COUNTIF(_Foreign = 0 AND ABS(_Worldwide - _Domestic) <= 1) AS domestic_only,
  COUNTIF(_Foreign = 0 AND _Worldwide - _Domestic > 1) AS foreign_possibly_missing
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`;


-- Query: 10. list and classify the rows that do not add up
-- Purpose: find out what kind of rows fail worldwide = domestic + foreign
--   (rows with no domestic revenue were noticed among the 63)
-- Finding: 63 gap rows = 51 with domestic and foreign both present + 12 with domestic = 0;
--   worldwide is higher in all of them
-- Next step: measure the size of the gaps (query 13)
SELECT
  CASE  -- label each problem row by which column looks off
    WHEN _Worldwide IS NULL OR _Domestic IS NULL OR _Foreign IS NULL THEN 'has_null'
    WHEN _Domestic = 0 THEN 'domestic_is_zero'
    WHEN _Foreign = 0 THEN 'foreign_is_zero'
    ELSE 'both_present'
  END AS pattern,
  COUNT(*) AS rows_with_gap,
  COUNTIF(_Worldwide > _Domestic + _Foreign) AS worldwide_larger,  -- unallocated revenue?
  COUNTIF(_Worldwide < _Domestic + _Foreign) AS worldwide_smaller,  -- parts exceed the total?
  ROUND(MIN(_Worldwide - (_Domestic + _Foreign))) AS smallest_gap,
  ROUND(MAX(_Worldwide - (_Domestic + _Foreign))) AS largest_gap
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
WHERE _Worldwide IS NULL OR _Domestic IS NULL OR _Foreign IS NULL
   OR ABS(_Worldwide - (_Domestic + _Foreign)) > 1  -- ignore sub-dollar float noise
GROUP BY pattern
ORDER BY rows_with_gap DESC;


-- Query: 11. rank profile per year
-- Purpose: confirm ranks run 1-200 within each year, and find any rank of 0
-- Finding: no rows returned, so ranks run 1-200 in every year with no zeros
-- Next step: document rank as a within-year rank in the README
SELECT
  Year,
  MIN(`Rank`) AS min_rank,
  MAX(`Rank`) AS max_rank,
  COUNT(DISTINCT `Rank`) AS distinct_ranks,
  COUNTIF(`Rank` = 0) AS rank_zero_rows
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
GROUP BY Year
HAVING MIN(`Rank`) <> 1 OR MAX(`Rank`) <> 200 OR COUNT(DISTINCT `Rank`) <> 200  -- empty means all years are 1-200
ORDER BY Year;


-- Query: 12. list titles that share metadata with a different title
-- Purpose: review the likely mismatched pairs by eye, excluding rows with no metadata
-- Finding: reviewed by eye; some pairs have similar titles, others show no visible link;
--   pairs with fewer than about 15 votes may be coincidence
-- Next step: flag rows with 15+ votes as suspect in staging
SELECT
  Rating,
  Vote_Count,
  Original_Language,
  Production_Countries,
  `Release Group`,
  Year,
  `Rank`,
  _Worldwide
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
WHERE Vote_Count > 0  -- skips the null-metadata group and the zero-vote group
QUALIFY COUNT(DISTINCT `Release Group`) OVER (
  PARTITION BY Rating, CAST(Vote_Count AS INT64), Original_Language, Production_Countries
  -- the CAST is needed because windows can't partition by a FLOAT64 column
) > 1  -- keep only rows whose metadata is shared with another title
ORDER BY Rating, Vote_Count, Year, `Rank`;


-- Query: 13. size of the gross gaps
-- Purpose: see whether the 63 gaps are small rounding differences or large missing amounts
-- Finding: most gaps are under 1% of worldwide; the largest is the 2021 Lord of the Rings
--   re-release at 6.8%, the second largest only 1.2%
-- Next step: add unallocated_gross and a 5% flag in staging
SELECT
  `Release Group`,
  Year,
  _Worldwide,
  _Domestic,
  _Foreign,
  _Worldwide - (_Domestic + _Foreign) AS gap,
  ROUND(SAFE_DIVIDE(_Worldwide - (_Domestic + _Foreign), _Worldwide) * 100, 1) AS gap_pct_of_worldwide,
  _Domestic = 0 AS domestic_is_zero  -- the 12 rows with zero domestic gross
FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
WHERE ABS(_Worldwide - (_Domestic + _Foreign)) > 1  -- ignore sub-dollar float noise
ORDER BY gap_pct_of_worldwide DESC;


-- Query: 14. shared-metadata rows by vote-count bucket
-- Purpose: see how many suspect rows have low vs high vote counts, to pick a flag threshold
-- Finding: 62 rows share metadata with a different title: 16 with 1-14 votes, 12 with
--   15-99, 18 with 100-999, 16 with 1000+; about 74% have 15+ votes, so small-sample
--   coincidence does not explain most of them; rule: suspect = shared metadata and 15+ votes
-- Next step: build metadata_status and rating_reliable in the dbt staging model
WITH shared AS (
  SELECT `Release Group`, Year, Vote_Count
  FROM `cinema-analytics-511621.cinema_raw.cinema_box_office`
  WHERE Vote_Count > 0  -- skips the null-metadata and zero-vote groups
  QUALIFY COUNT(DISTINCT `Release Group`) OVER (
    PARTITION BY Rating, CAST(Vote_Count AS INT64), Original_Language, Production_Countries
  ) > 1  -- keep rows sharing metadata with a different title
)
SELECT
  CASE
    WHEN Vote_Count < 15 THEN '1-14'
    WHEN Vote_Count < 100 THEN '15-99'
    WHEN Vote_Count < 1000 THEN '100-999'
    ELSE '1000+'
  END AS vote_bucket,
  COUNT(*) AS rows_sharing_metadata
FROM shared
GROUP BY vote_bucket
ORDER BY MIN(Vote_Count);