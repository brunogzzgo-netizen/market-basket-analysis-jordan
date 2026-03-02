# Ejecutar dbt con BigQuery

Antes de ejecutar dbt run, define en PowerShell:

  $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\Users\brugz\Downloads\Consulting\Reto\materialesjordan-9803da3e0936.json"

Luego, desde la carpeta del proyecto:

  dbt clean
  dbt run --profiles-dir .

Los modelos stg_customer y stg_sale se materializarán en jordan.duckdb leyendo desde BigQuery.
