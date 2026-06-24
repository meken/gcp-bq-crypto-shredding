resource "google_bigquery_dataset" "dataset" {
  dataset_id                  = var.dataset_id
  friendly_name               = "Crypto Shredding Demo"
  description                 = "Dataset illustrating crypto-shredding on BigQuery using raw keys"
  location                    = var.location
  default_table_expiration_ms = null # Tables persist indefinitely for the demo
}

# 1. Key Registry Table
resource "google_bigquery_table" "user_keys" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "user_keys"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "user_key",
    "type": "BYTES",
    "mode": "REQUIRED",
    "description": "The cryptographically secure raw keyset for the user"
  }
]
EOF
}

# 2. Encrypted Target Table
resource "google_bigquery_table" "user_transactions" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "user_transactions"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "transaction_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "The unique ID of the transaction"
  },
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "transaction_timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Timestamp of the transaction"
  },
  {
    "name": "amount",
    "type": "NUMERIC",
    "mode": "NULLABLE",
    "description": "Transaction amount"
  },
  {
    "name": "currency",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Currency code"
  },
  {
    "name": "user_email",
    "type": "BYTES",
    "mode": "NULLABLE",
    "description": "Deterministic AEAD encrypted user email address"
  }
]
EOF
}

# 3. Unencrypted Staging Table
resource "google_bigquery_table" "staging_transactions" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "staging_transactions"
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "transaction_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "The unique ID of the transaction"
  },
  {
    "name": "user_id",
    "type": "INTEGER",
    "mode": "REQUIRED",
    "description": "The unique ID of the user"
  },
  {
    "name": "transaction_timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Timestamp of the transaction"
  },
  {
    "name": "amount",
    "type": "NUMERIC",
    "mode": "NULLABLE",
    "description": "Transaction amount"
  },
  {
    "name": "currency",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Currency code"
  },
  {
    "name": "user_email",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Unencrypted raw user email address (PII)"
  }
]
EOF
}

# --- BigQuery Routines (Stored Procedures) ---

# Routine A: Create keysets for any user who doesn't have one
resource "google_bigquery_routine" "create_keys" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "create_keys"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      MERGE `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS target
      USING (SELECT DISTINCT user_id FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions`) AS source
      ON target.user_id = source.user_id
      WHEN NOT MATCHED THEN
        INSERT (user_id, user_key)
        VALUES (
          source.user_id, 
          KEYS.NEW_KEYSET('DETERMINISTIC_AEAD_AES_SIV_CMAC_256')
        );
    END
  EOS

  depends_on = [
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions
  ]
}

# Routine B: Encrypt and insert from staging to target
resource "google_bigquery_routine" "encrypt_and_insert" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "encrypt_and_insert"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      INSERT INTO `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` (
        transaction_id,
        user_id,
        transaction_timestamp,
        amount,
        currency,
        user_email
      )
      SELECT
        s.transaction_id,
        s.user_id,
        s.transaction_timestamp,
        s.amount,
        s.currency,
        DETERMINISTIC_ENCRYPT(k.user_key, s.user_email, CAST(s.user_id AS STRING)) AS user_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.staging_transactions` AS s
      JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON s.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys,
    google_bigquery_table.staging_transactions
  ]
}

# Routine C: Delete a user's keyset (Crypto-shredding)
resource "google_bigquery_routine" "delete_user_key" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "delete_user_key"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      DELETE FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys`
      WHERE user_id = target_user_id;
    END
  EOS

  arguments {
    name          = "target_user_id"
    argument_kind = "FIXED_TYPE"
    mode          = "IN"
    data_type     = jsonencode({ "typeKind" : "INT64" })
  }

  depends_on = [
    google_bigquery_table.user_keys
  ]
}

# Routine D: Look up user details, decrypt them and show DELETED if the key doesn't exist
resource "google_bigquery_routine" "lookup_user_transactions" {
  dataset_id      = google_bigquery_dataset.dataset.dataset_id
  routine_id      = "lookup_user_transactions"
  routine_type    = "PROCEDURE"
  language        = "SQL"
  definition_body = <<-EOS
    BEGIN
      SELECT
        t.transaction_id,
        t.user_id,
        t.transaction_timestamp,
        t.amount,
        t.currency,
        CASE
          WHEN t.user_email IS NULL THEN NULL
          WHEN k.user_key IS NULL THEN 'DELETED'
          ELSE DETERMINISTIC_DECRYPT_STRING(k.user_key, t.user_email, CAST(t.user_id AS STRING))
        END AS decrypted_email
      FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_transactions` AS t
      LEFT JOIN `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.user_keys` AS k
      ON t.user_id = k.user_id;
    END
  EOS

  depends_on = [
    google_bigquery_table.user_transactions,
    google_bigquery_table.user_keys
  ]
}


# Populate staging table with random but deterministic demo records
resource "google_bigquery_job" "populate_staging" {
  job_id   = "job_populate_staging"
  location = var.location

  query {
    query = templatefile("${path.module}/populate_staging.sql", {
      project_id = var.project_id
      dataset_id = google_bigquery_dataset.dataset.dataset_id
    })
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_bigquery_table.staging_transactions
  ]
}
