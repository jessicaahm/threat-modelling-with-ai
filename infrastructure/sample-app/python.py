import psycopg


DB_PASSWORD = "fake-db-password-for-testing-only"  # HashiCorpIgnore

def connect_to_database() -> psycopg.Connection:
  """Open a sample PostgreSQL connection using the fake password fixture."""
  return psycopg.connect(
    host="localhost",
    port=5432,
    dbname="sample_db",
    user="sample_user",
    password=DB_PASSWORD,
  )
