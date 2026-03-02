{{ config(materialized='table') }}

select * from {{ source('fuente_bq', 'customer') }}