/*
Carehosts is a peer-to-peer website platform that connects hosts and elderly residents.
The original search logic for Carehosts.com was slow and inefficient, often taking several minutes to complete.
After refactoring the code and incorporating CTEs, I reduce processing time from several minutes to < 1 sec.
*/

WITH CalendarSummary AS (
  SELECT
        room_id,
        SUM(price) AS calendar_total,
        COUNT(*) AS special_nights,
        SUM(CASE WHEN WEEKDAY(date) IN (4, 5) THEN 1 END) AS special_weekends
    FROM `calendar`
    WHERE FIND_IN_SET(date, "2023-11-15,2023-11-16")
    GROUP BY 1
),

PriceRulesSummary AS (
    SELECT
        room_id,
        MIN(CASE WHEN period >= 2 AND type = 'last_min' THEN period END) AS min_price_rule_period,
        MAX(CASE WHEN period <= 2 AND type = 'early_bird' THEN period END) AS max_price_rule_period,
        MAX(CASE WHEN period <= 2 AND type = 'length_of_stay' THEN period END) AS length_of_stay_period,
        MAX(CASE WHEN period >= 2 AND type = 'last_min' THEN discount END) AS last_min_discount,
        MAX(CASE WHEN period <= 2 AND type = 'early_bird' THEN discount END) AS early_bird_discount,
        MAX(CASE WHEN period <= 2 AND type = 'length_of_stay' THEN discount END) AS length_of_stay_discount,
        MAX(CASE WHEN (period >= 2 AND type = 'last_min' AND period = (CASE WHEN period >= 2 AND type = 'last_min' THEN period END)) OR (period <= 2 AND type = 'early_bird' AND period = (CASE WHEN period <= 2 AND type = 'early_bird' THEN period END)) THEN discount END) AS booked_period_discount
    FROM `rooms_price_rules`
    GROUP BY 1
),

NormalWeekends AS (
SELECT a.id AS room_id
    , (0 - cs.special_weekends) AS normal_weekends
    FROM   `rooms` a
    LEFT JOIN CalendarSummary cs ON cs.room_id = a.id
),

NormalNights AS (
SELECT a.id AS room_id
    , (2 - cs.special_nights - normal_weekends) AS normal_nights
    FROM `rooms` a
       LEFT JOIN CalendarSummary cs ON cs.room_id = a.id
       LEFT JOIN NormalWeekends nw ON nw.room_id = a.id
),

PriceTotal AS (
SELECT a.id AS room_id
    , ((c.night * nn.normal_nights ) + (CASE WHEN c.weekend > 0 THEN c.weekend ELSE c.night END) * nw.normal_weekends) AS price_total
    FROM   `rooms` a
    LEFT JOIN `rooms_price` c ON c.`room_id` = a.`id`
    LEFT JOIN NormalWeekends nw ON nw.room_id = a.id
    LEFT JOIN NormalNights nn ON nn.room_id = a.id
),

BaseTotal AS (
SELECT a.`id` AS `room_id`
    , Ifnull(pt.price_total, 0) + Ifnull(cs.calendar_total, 0) AS base_total
    FROM   `rooms` a
    LEFT JOIN CalendarSummary cs ON cs.room_id = a.id
LEFT JOIN PriceTotal pt ON pt.room_id = a.id
),

BookedPeriodDiscountPrice AS (
SELECT a.id AS room_id
    , Round(bt.base_total * (pr.booked_period_discount / 100)) AS booked_period_discount_price
FROM   `rooms` a
    LEFT JOIN PriceRulesSummary pr ON pr.room_id = a.id
    LEFT JOIN BaseTotal bt ON bt.room_id = a.id  
),

BookedPeriodBaseTotal AS (
  SELECT a.id AS room_id
    , Round(bt.base_total - Ifnull(bp.booked_period_discount_price, 0)) AS booked_period_base_total
    FROM   `rooms` a
    LEFT JOIN BaseTotal bt ON bt.room_id = a.id  
    LEFT JOIN BookedPeriodDiscountPrice bp ON bp.room_id = a.id
),

LengthofStayDiscountPrice AS (
SELECT a.id AS room_id
    , Round(bpt.booked_period_base_total * (pr.length_of_stay_discount / 100)) AS length_of_stay_discount_price
    FROM   `rooms` a
    LEFT JOIN PriceRulesSummary pr ON pr.room_id = a.id
    LEFT JOIN BookedPeriodBaseTotal bpt ON bpt.room_id = a.id
),

DiscountedBaseTotal AS (
SELECT a.id AS room_id
    , Round(booked_period_base_total - Ifnull(length_of_stay_discount_price, 0 )) AS discounted_base_total
    FROM   `rooms` a
    LEFT JOIN BookedPeriodBaseTotal bpt ON bpt.room_id = a.id
    LEFT JOIN LengthofStayDiscountPrice ldp ON ldp.room_id = a.id
),

Total AS (
SELECT a.id AS room_id
    , Round(Ifnull(dbt.discounted_base_total, 0) + c.cleaning) AS total
    FROM   `rooms` a
    LEFT JOIN `rooms_price` c ON c.`room_id` = a.`id`
    LEFT JOIN DiscountedBaseTotal dbt ON dbt.room_id = a.id
),

AvgPrice AS (
SELECT a.id AS room_id
    , Round(t.total / 2) AS avg_price
    FROM   `rooms` a
    LEFT JOIN Total t ON t.room_id = a.id
)


SELECT a.`id` AS `room_id`,
       cs.calendar_total AS calendar_total,
       cs.special_nights AS special_nights,
       cs.special_weekends AS special_weekends,
       nw.normal_weekends AS normal_weekends,
       nn.normal_nights AS normal_nights,
       pt.price_total AS price_total,
       bt.base_total AS base_total,
       pr.min_price_rule_period AS min_price_rule_period,
       pr.max_price_rule_period AS max_price_rule_period,
       pr.booked_period_discount AS booked_period_discount,
       pr.length_of_stay_period AS length_of_stay_period,
       pr.length_of_stay_discount AS length_of_stay_discount,
       bp.booked_period_discount_price AS booked_period_discount_price,
       bpt.booked_period_base_total AS booked_period_base_total,
       ldp.length_of_stay_discount_price AS length_of_stay_discount_price,
       dbt.discounted_base_total AS discounted_base_total,
       (CASE WHEN ( 1 - c.guests ) > 0 THEN ( 1 - c.guests ) ELSE 0 end) AS extra_guests,
       t.total AS total,
       ap.avg_price AS avg_price,
       Round(t.total / 2) AS night,
       Round((ap.avg_price / d.rate) * 1.000) AS session_night
       
FROM   `rooms` a
    LEFT OUTER JOIN `calendar` b ON b.`room_id` = a.`id`
    LEFT JOIN `rooms_price` c ON c.`room_id` = a.`id`
    LEFT JOIN `currency` d ON d.`code` = c.`currency_code`
    LEFT JOIN CalendarSummary cs ON cs.room_id = a.id
    LEFT JOIN PriceRulesSummary pr ON pr.room_id = a.id
    LEFT JOIN NormalWeekends nw ON nw.room_id = a.id
    LEFT JOIN NormalNights nn ON nn.room_id = a.id
    LEFT JOIN PriceTotal pt ON pt.room_id = a.id
    LEFT JOIN BaseTotal bt ON bt.room_id = a.id
    LEFT JOIN BookedPeriodDiscountPrice bp ON bp.room_id = a.id
    LEFT JOIN BookedPeriodBaseTotal bpt ON bpt.room_id = a.id
    LEFT JOIN LengthofStayDiscountPrice ldp ON ldp.room_id = a.id
    LEFT JOIN DiscountedBaseTotal dbt ON dbt.room_id = a.id
    LEFT JOIN Total t ON t.room_id = a.id
    LEFT JOIN AvgPrice ap ON ap.room_id = a.id
GROUP  BY a.`id`
